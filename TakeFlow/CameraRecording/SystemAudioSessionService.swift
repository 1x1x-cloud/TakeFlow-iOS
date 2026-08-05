@preconcurrency import AVFAudio
import Foundation

final class SystemAudioSessionService: AudioSessionServicing, @unchecked Sendable {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func currentInputRoute() async -> AudioInputRoute {
        Self.route(from: session.currentRoute)
    }

    func activateForRecording() async throws {
        try session.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)
    }

    func deactivateAfterRecording() async {
        do {
            try session.setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            AppLogger.error(
                "audio_session_deactivation_failed",
                category: .recording
            )
        }
    }

    func events() async -> AsyncStream<AudioSessionEvent> {
        AsyncStream { continuation in
            let routeToken = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                guard let self else {
                    return
                }
                continuation.yield(
                    .routeChanged(
                        Self.route(from: self.session.currentRoute)
                    )
                )
            }
            let interruptionToken = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: nil
            ) { notification in
                let rawType = (notification.userInfo?[
                    AVAudioSessionInterruptionTypeKey
                ] as? NSNumber)?.uintValue
                let type = rawType.flatMap(
                    AVAudioSession.InterruptionType.init(rawValue:)
                )
                let rawReason = (notification.userInfo?[
                    AVAudioSessionInterruptionReasonKey
                ] as? NSNumber)?.uintValue
                // Raw reason 1 was the legacy suspended reason; raw reason 3
                // identifies a backgrounded scene. Avoid the deprecated
                // was-suspended key while retaining this diagnostic fact.
                // App scene lifecycle remains the authoritative UI source.
                let wasSuspended = rawReason == 1 || rawReason == 3
                let details = AudioInterruptionDetails(
                    rawType: rawType,
                    rawReason: rawReason,
                    wasSuspended: wasSuspended
                )
                #if DEBUG
                let rawOptions = (notification.userInfo?[
                    AVAudioSessionInterruptionOptionKey
                ] as? NSNumber)?.uintValue
                AppLogger.info(
                    "audio_interruption_notification "
                        + "uptime=\(ProcessInfo.processInfo.systemUptime) "
                        + "raw_type=\(rawType.map(String.init) ?? "none") "
                        + "raw_options=\(rawOptions.map(String.init) ?? "none") "
                        + "raw_reason=\(rawReason.map(String.init) ?? "none") "
                        + "was_suspended=\(wasSuspended)",
                    category: .recording
                )
                #endif
                switch type {
                case .began:
                    continuation.yield(.interruptionBegan(details))
                case .ended:
                    continuation.yield(.interruptionEnded(details))
                case nil:
                    AppLogger.error(
                        "audio_interruption_notification_invalid",
                        category: .recording
                    )
                @unknown default:
                    AppLogger.error(
                        "audio_interruption_notification_unknown",
                        category: .recording
                    )
                }
            }
            let mediaServicesLostToken = NotificationCenter.default
                .addObserver(
                    forName:
                        AVAudioSession.mediaServicesWereLostNotification,
                    object: session,
                    queue: nil
                ) { _ in
                    #if DEBUG
                    AppLogger.info(
                        "audio_media_services_lost",
                        category: .recording
                    )
                    #endif
                    continuation.yield(.mediaServicesWereLost)
                }
            let mediaServicesResetToken = NotificationCenter.default
                .addObserver(
                    forName:
                        AVAudioSession.mediaServicesWereResetNotification,
                    object: session,
                    queue: nil
                ) { _ in
                    #if DEBUG
                    AppLogger.info(
                        "audio_media_services_reset",
                        category: .recording
                    )
                    #endif
                    continuation.yield(.mediaServicesWereReset)
                }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(routeToken)
                NotificationCenter.default.removeObserver(
                    interruptionToken
                )
                NotificationCenter.default.removeObserver(
                    mediaServicesLostToken
                )
                NotificationCenter.default.removeObserver(
                    mediaServicesResetToken
                )
            }
        }
    }

    private static func route(
        from route: AVAudioSessionRouteDescription
    ) -> AudioInputRoute {
        guard let input = route.inputs.first else {
            return .unavailable
        }
        let isBluetooth = [
            AVAudioSession.Port.bluetoothHFP,
            .bluetoothLE,
            .bluetoothA2DP
        ].contains(input.portType)
        return AudioInputRoute(
            name: input.portName,
            isBluetooth: isBluetooth,
            isAvailable: true
        )
    }
}

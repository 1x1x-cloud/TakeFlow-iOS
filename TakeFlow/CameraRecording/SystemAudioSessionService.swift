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
                let rawType = notification.userInfo?[
                    AVAudioSessionInterruptionTypeKey
                ] as? UInt
                let type = rawType.flatMap(
                    AVAudioSession.InterruptionType.init(rawValue:)
                )
                #if DEBUG
                let rawOptions = notification.userInfo?[
                    AVAudioSessionInterruptionOptionKey
                ] as? UInt
                AppLogger.info(
                    "audio_interruption_notification "
                        + "uptime=\(ProcessInfo.processInfo.systemUptime) "
                        + "raw_type=\(rawType.map(String.init) ?? "none") "
                        + "raw_options=\(rawOptions.map(String.init) ?? "none")",
                    category: .recording
                )
                #endif
                switch type {
                case .began:
                    continuation.yield(.interruptionBegan)
                case .ended:
                    continuation.yield(.interruptionEnded)
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
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(routeToken)
                NotificationCenter.default.removeObserver(
                    interruptionToken
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

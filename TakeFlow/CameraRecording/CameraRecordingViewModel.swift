import Foundation
import SwiftUI

@MainActor
final class CameraRecordingViewModel: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var previewSource: CapturePreviewSource?
    @Published private(set) var configuration: CaptureConfiguration?
    @Published private(set) var capabilities: CaptureCapabilities = .unavailable
    @Published private(set) var audioRoute: AudioInputRoute = .unavailable
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var completedRecording: CompletedRecording?
    @Published private(set) var recoverableRecording: RecoverableRecording?
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var isFocusAndExposureLocked = false
    @Published private(set) var captureRotationAngle = 0.0
    @Published private(set) var selectedResolution:
        VideoResolution = .fullHD1080p

    private let scriptID: UUID
    private let dependencies: CameraRecordingDependencies
    private var machine = RecordingStateMachine()
    private var pendingRecording: PendingRecording?
    private var eventTask: Task<Void, Never>?
    private var audioRouteTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var storageMonitorTask: Task<Void, Never>?
    private var callbackGeneration: UInt64 = 0
    private var interruptionReason: CaptureInterruptionReason?
    private var isVisible = true

    init(
        scriptID: UUID,
        dependencies: CameraRecordingDependencies
    ) {
        self.scriptID = scriptID
        self.dependencies = dependencies
    }

    deinit {
        eventTask?.cancel()
        audioRouteTask?.cancel()
        countdownTask?.cancel()
        storageMonitorTask?.cancel()
    }

    var canSwitchCamera: Bool {
        machine.permitsCameraSwitch() && state == .ready
    }

    var canStartRecording: Bool {
        state == .ready
    }

#if DEBUG
    var isFakePreview: Bool {
        dependencies.isUITestFake
    }
#endif

    func prepare() async {
        cancelTasksForNewLifecycle()
        errorMessage = nil
        noticeMessage = nil
        completedRecording = nil
        recoverableRecording = nil
        isVisible = true

        do {
            if state != .idle {
                machine.reset()
                synchronize()
            }
            try machine.beginPermissionRequest()
            synchronize()
            try await requirePermission(.camera)
            try await requirePermission(.microphone)

            try machine.beginConfiguration()
            synchronize()
            startEventObservation()
            startAudioRouteObservation()
            try await dependencies.audio.activateForRecording()
            audioRoute = await dependencies.audio.currentInputRoute()
            guard audioRoute.isAvailable else {
                throw CaptureError.microphoneUnavailable
            }
            try await dependencies.capture.configure(
                position: .front,
                preferredResolution: selectedResolution
            )
            try await dependencies.capture.startPreview()
            let recovered =
                await dependencies.files.recoverPendingRecordings()
            if let latest = recovered.last {
                recoverableRecording = latest
                noticeMessage =
                    CameraRecordingStrings.recoveredRecordingFound
            }
        } catch {
            fail(error)
        }
    }

    func startRecording() {
        guard state == .ready else {
            fail(CaptureError.invalidTransition)
            return
        }
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            await self?.performCountdownAndStart()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        do {
            try machine.cancelCountdown()
            synchronize()
        } catch {
            fail(error)
        }
    }

    func stopRecording() {
        guard case .recording(let recordingID) = state else {
            return
        }
        do {
            let shouldStop = try machine.beginStopping(
                recordingID: recordingID
            )
            synchronize()
            guard shouldStop else {
                return
            }
            Task {
                do {
                    try await dependencies.capture.stopRecording(
                        recordingID: recordingID
                    )
                } catch {
                    fail(error)
                }
            }
        } catch {
            fail(error)
        }
    }

    func switchCamera() {
        guard canSwitchCamera else {
            return
        }
        Task {
            do {
                try await dependencies.capture.switchCamera()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? CaptureError.cameraUnavailable.errorDescription
            }
        }
    }

    func selectResolution(_ resolution: VideoResolution) {
        guard
            state == .ready,
            resolution != selectedResolution,
            capabilities.availableFormats.contains(where: {
                $0.resolution == resolution
            })
        else {
            return
        }
        Task {
            do {
                try await dependencies.capture.configure(
                    position: configuration?.position ?? .front,
                    preferredResolution: resolution
                )
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? CaptureError.unsupportedConfiguration.errorDescription
            }
        }
    }

    func setCaptureRotationAngle(_ angle: Double) {
        guard !state.isActivelyRecording else {
            return
        }
        captureRotationAngle = angle
    }

    func focus(
        at point: NormalizedCapturePoint
    ) {
        Task {
            do {
                try await dependencies.capture.setFocusAndExposure(
                    at: point,
                    locked: isFocusAndExposureLocked
                )
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? CaptureError.focusUnsupported.errorDescription
            }
        }
    }

    func toggleFocusAndExposureLock() {
        isFocusAndExposureLocked.toggle()
        noticeMessage = isFocusAndExposureLocked
            ? CameraRecordingStrings.focusLock
            : CameraRecordingStrings.focusUnlocked
    }

    func saveToPhotos() {
        guard let completedRecording else {
            return
        }
        Task {
            let result = await dependencies.photos.saveVideo(
                at: completedRecording.fileURL
            )
            switch result {
            case .saved:
                noticeMessage = CameraRecordingStrings.savedToPhotos
            case .permissionDenied:
                errorMessage = CaptureError.photoPermissionDenied
                    .errorDescription
            case .failed:
                errorMessage = CaptureError.photoSaveFailed.errorDescription
            }
        }
    }

    func sceneDidEnterBackground() {
        if case .starting = state {
            cancelCountdown()
        }
        Task {
            await dependencies.capture.handleApplicationBackgrounded()
        }
    }

    func sceneDidBecomeActive() {
        Task {
            await dependencies.capture.handleApplicationForegrounded()
        }
    }

    func viewDidDisappear() {
        isVisible = false
        countdownTask?.cancel()
        storageMonitorTask?.cancel()
        Task {
            await dependencies.capture.stopPreview()
            await dependencies.audio.deactivateAfterRecording()
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func performCountdownAndStart() async {
        do {
            let capacity =
                try await dependencies.storage
                    .availableCapacityForImportantUsage()
            guard capacity >= dependencies.storagePolicy.minimumStartBytes
            else {
                throw CaptureError.storageSpaceInsufficient
            }

            try machine.beginCountdown(
                seconds: dependencies.countdownSeconds
            )
            synchronize()
            for remaining in stride(
                from: dependencies.countdownSeconds,
                through: 1,
                by: -1
            ) {
                if remaining != dependencies.countdownSeconds {
                    try machine.updateCountdown(remaining: remaining)
                    synchronize()
                }
                try await Task.sleep(
                    for: dependencies.countdownStep
                )
                try Task.checkCancellation()
            }

            let orientation = Self.orientation(
                forRotationAngle: captureRotationAngle
            )
            let pending = try await dependencies.files.createRecording(
                scriptID: scriptID,
                orientation: orientation,
                resolution: selectedResolution
            )
            pendingRecording = pending
            try await dependencies.files.markRecordingStarted(pending)
            callbackGeneration = machine.generation
            try await dependencies.capture.startRecording(
                recordingID: pending.recordingID,
                outputURL: pending.temporaryURL,
                rotationAngle: captureRotationAngle
            )
            try machine.markRecording(recordingID: pending.recordingID)
            recordingDuration = 0
            interruptionReason = nil
            synchronize()
            startStorageMonitor(recordingID: pending.recordingID)
        } catch is CancellationError {
            return
        } catch {
            if let pendingRecording {
                try? await dependencies.files.deleteProject(
                    projectID: pendingRecording.projectID
                )
                self.pendingRecording = nil
            }
            fail(error)
        }
    }

    private func startEventObservation() {
        eventTask?.cancel()
        eventTask = Task { [weak self, capture = dependencies.capture] in
            let events = await capture.events()
            for await event in events {
                guard let self, !Task.isCancelled else {
                    return
                }
                await self.handle(event)
            }
        }
    }

    private func startAudioRouteObservation() {
        audioRouteTask?.cancel()
        audioRouteTask = Task { [weak self, audio = dependencies.audio] in
            let events = await audio.events()
            for await event in events {
                guard let self, !Task.isCancelled else {
                    return
                }
                switch event {
                case .routeChanged(let route):
                    self.audioRoute = route
                    if !route.isAvailable,
                       self.state.isActivelyRecording {
                        await self.handleAudioRouteLoss()
                    }
                case .interruptionBegan:
                    await self.handleAudioRouteLoss()
                case .interruptionEnded:
                    break
                }
            }
        }
    }

    private func handle(_ event: CaptureSessionEvent) async {
        guard isVisible else {
            return
        }
        switch event {
        case .sessionReady(
            let source,
            let configuration,
            let capabilities
        ):
            previewSource = source
            self.configuration = configuration
            self.capabilities = capabilities
            selectedResolution = configuration.format.resolution
            if state == .configuring {
                do {
                    try machine.markReady()
                    synchronize()
                } catch {
                    fail(error)
                }
            }
        case .duration(let recordingID, let seconds):
            guard case .recording(let activeID) = state,
                  activeID == recordingID
            else {
                return
            }
            recordingDuration = seconds
        case .recordingFinished(
            let recordingID,
            _,
            let duration
        ):
            await handleRecordingFinished(
                recordingID: recordingID,
                duration: duration
            )
        case .recordingFailed(
            let recordingID,
            _,
            let error
        ):
            await preserveAfterFailure(
                recordingID: recordingID,
                reason: interruptionReason ?? .unknown
            )
            fail(error)
        case .interrupted(
            let recordingID,
            let reason,
            _
        ):
            interruptionReason = reason
            if machine.interrupt(recordingID: recordingID, reason: reason) {
                synchronize()
                noticeMessage = reason == .storageSpaceLow
                    ? CameraRecordingStrings.storageLow
                    : CameraRecordingStrings.interrupted
            }
        case .audioRouteChanged(let route):
            audioRoute = route
        case .mediaServicesReset:
            interruptionReason = .mediaServicesReset
            _ = machine.interrupt(
                recordingID: pendingRecording?.recordingID,
                reason: .mediaServicesReset
            )
            synchronize()
        }
    }

    private func handleRecordingFinished(
        recordingID: UUID,
        duration: TimeInterval
    ) async {
        guard
            let pending = pendingRecording,
            pending.recordingID == recordingID
        else {
            return
        }
        storageMonitorTask?.cancel()

        if let interruptionReason {
            await preserveAfterFailure(
                recordingID: recordingID,
                reason: interruptionReason
            )
            return
        }

        do {
            let completed = try await dependencies.files.completeRecording(
                pending,
                duration: duration
            )
            try machine.finish(
                recordingID: recordingID,
                fileURL: completed.fileURL,
                generation: callbackGeneration
            )
            completedRecording = completed
            pendingRecording = nil
            recordingDuration = duration
            synchronize()
        } catch {
            await preserveAfterFailure(
                recordingID: recordingID,
                reason: .unknown
            )
            fail(error)
        }
    }

    private func preserveAfterFailure(
        recordingID: UUID,
        reason: CaptureInterruptionReason
    ) async {
        guard
            let pending = pendingRecording,
            pending.recordingID == recordingID
        else {
            return
        }
        do {
            recoverableRecording =
                try await dependencies.files.preserveRecoverableRecording(
                    pending,
                    reason: reason
                )
            pendingRecording = nil
        } catch {
            AppLogger.error(
                "recording_recovery_metadata_failed",
                category: .persistence
            )
        }
    }

    private func startStorageMonitor(recordingID: UUID) {
        storageMonitorTask?.cancel()
        storageMonitorTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: dependencies.storagePolicy.checkInterval
                    )
                    let capacity =
                        try await dependencies.storage
                            .availableCapacityForImportantUsage()
                    guard
                        capacity
                            < dependencies.storagePolicy.safeStopBytes
                    else {
                        continue
                    }
                    interruptionReason = .storageSpaceLow
                    _ = machine.interrupt(
                        recordingID: recordingID,
                        reason: .storageSpaceLow
                    )
                    synchronize()
                    noticeMessage = CameraRecordingStrings.storageLow
                    try? await dependencies.capture.stopRecording(
                        recordingID: recordingID
                    )
                    return
                } catch is CancellationError {
                    return
                } catch {
                    fail(error)
                    return
                }
            }
        }
    }

    private func handleAudioRouteLoss() async {
        guard case .recording(let recordingID) = state else {
            return
        }
        interruptionReason = .audioSessionInterrupted
        _ = machine.interrupt(
            recordingID: recordingID,
            reason: .audioSessionInterrupted
        )
        synchronize()
        try? await dependencies.capture.stopRecording(
            recordingID: recordingID
        )
    }

    private func requirePermission(
        _ permission: PermissionKind
    ) async throws {
        var status = dependencies.permissions.status(for: permission)
        if status == .notDetermined {
            status = await dependencies.permissions.request(permission)
        }
        switch status {
        case .authorized:
            return
        case .denied:
            throw CaptureError.permissionDenied(permission)
        case .restricted:
            throw CaptureError.permissionRestricted(permission)
        case .unavailable:
            throw CaptureError.permissionUnavailable(permission)
        case .notDetermined:
            throw CaptureError.permissionDenied(permission)
        }
    }

    private func fail(_ error: Error) {
        let captureError = error as? CaptureError ?? .recordingFailed
        machine.fail(captureError)
        synchronize()
        errorMessage = captureError.errorDescription
    }

    private func synchronize() {
        state = machine.state
    }

    private func cancelTasksForNewLifecycle() {
        countdownTask?.cancel()
        storageMonitorTask?.cancel()
        eventTask?.cancel()
        audioRouteTask?.cancel()
    }

    private static func orientation(
        forRotationAngle angle: Double
    ) -> CaptureOrientation {
        let normalized = angle.truncatingRemainder(dividingBy: 360)
        switch normalized {
        case 45..<135:
            return .landscapeRight
        case 225..<315, -135 ..< -45:
            return .landscapeLeft
        default:
            return .portrait
        }
    }
}

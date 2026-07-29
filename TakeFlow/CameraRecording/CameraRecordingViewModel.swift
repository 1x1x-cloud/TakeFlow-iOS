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
    private var preparationTimeoutTask: Task<Void, Never>?
    private var recordingFinalizationTimeoutTask: Task<Void, Never>?
    private var recordingFinalizationWaiter:
        CheckedContinuation<Void, Never>?
    private var callbackGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var activeSessionID: UUID?
    private var interruptionReason: CaptureInterruptionReason?
    private var isVisible = false
    private var isShuttingDown = false

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
        preparationTimeoutTask?.cancel()
        recordingFinalizationTimeoutTask?.cancel()
    }

    var canSwitchCamera: Bool {
        machine.permitsCameraSwitch() && state == .ready
    }

    var canStartRecording: Bool {
        state == .ready
    }

    var canRetryPreparation: Bool {
        if case .failed = state {
            return true
        }
        return false
    }

#if DEBUG
    var isFakePreview: Bool {
        dependencies.isUITestFake
    }
#endif

    func prepare() async {
        if isVisible,
           activeSessionID != nil,
           (
               state == .requestingPermissions
                   || state == .configuring
                   || state == .ready
           ) {
            return
        }

        cancelTasksForNewLifecycle()
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let sessionID = UUID()
        activeSessionID = sessionID
        errorMessage = nil
        noticeMessage = nil
        completedRecording = nil
        recoverableRecording = nil
        previewSource = nil
        configuration = nil
        capabilities = .unavailable
        isVisible = true
        isShuttingDown = false
        schedulePreparationTimeout(
            sessionID: sessionID,
            generation: generation
        )

        do {
            if state != .idle {
                machine.reset()
                synchronize()
            }
            try machine.beginPermissionRequest()
            synchronize()
            try await requirePermission(.camera)
            try ensureCurrentLifecycle(sessionID, generation: generation)
            try await requirePermission(.microphone)
            try ensureCurrentLifecycle(sessionID, generation: generation)

            try machine.beginConfiguration()
            synchronize()
            await startEventObservation(
                sessionID: sessionID,
                generation: generation
            )
            startAudioRouteObservation()
            try await dependencies.audio.activateForRecording()
            try ensureCurrentLifecycle(sessionID, generation: generation)
            audioRoute = await dependencies.audio.currentInputRoute()
            try ensureCurrentLifecycle(sessionID, generation: generation)
            guard audioRoute.isAvailable else {
                throw CaptureError.microphoneUnavailable
            }
            try await dependencies.capture.configure(
                sessionID: sessionID,
                position: .front,
                preferredResolution: selectedResolution
            )
            try ensureCurrentLifecycle(sessionID, generation: generation)
            try await dependencies.capture.startPreview(
                sessionID: sessionID
            )
            try ensureCurrentLifecycle(sessionID, generation: generation)
            let recovered =
                await dependencies.files.recoverPendingRecordings()
            try ensureCurrentLifecycle(sessionID, generation: generation)
            if let latest = recovered.last {
                recoverableRecording = latest
                noticeMessage =
                    CameraRecordingStrings.recoveredRecordingFound
            }
        } catch is CancellationError {
            await cleanUpLifecycleIfCurrent(
                sessionID: sessionID,
                generation: generation,
                keepFailureState: false
            )
        } catch {
            guard isCurrentLifecycle(sessionID, generation: generation) else {
                return
            }
            fail(error)
            await cleanUpLifecycleIfCurrent(
                sessionID: sessionID,
                generation: generation,
                keepFailureState: true
            )
        }
    }

    func retryPreparation() async {
        await viewDidDisappear()
        await prepare()
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
        guard canSwitchCamera, let sessionID = activeSessionID else {
            return
        }
        Task {
            do {
                try await dependencies.capture.switchCamera(
                    sessionID: sessionID
                )
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
        guard let sessionID = activeSessionID else {
            return
        }
        Task {
            do {
                try await dependencies.capture.configure(
                    sessionID: sessionID,
                    position: configuration?.position ?? .front,
                    preferredResolution: resolution
                )
                try await dependencies.capture.startPreview(
                    sessionID: sessionID
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
        guard let sessionID = activeSessionID else {
            return
        }
        Task {
            do {
                try await dependencies.capture.setFocusAndExposure(
                    sessionID: sessionID,
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
        guard let sessionID = activeSessionID else {
            return
        }
        Task {
            await dependencies.capture.handleApplicationBackgrounded(
                sessionID: sessionID
            )
        }
    }

    func sceneDidBecomeActive() {
        guard let sessionID = activeSessionID else {
            return
        }
        Task {
            await dependencies.capture.handleApplicationForegrounded(
                sessionID: sessionID
            )
        }
    }

    func viewDidDisappear() async {
        guard isVisible || activeSessionID != nil else {
            return
        }
        guard !isShuttingDown else {
            return
        }
        isShuttingDown = true
        isVisible = false
        lifecycleGeneration &+= 1
        preparationTimeoutTask?.cancel()
        countdownTask?.cancel()
        storageMonitorTask?.cancel()
        audioRouteTask?.cancel()

        if case .starting = state {
            try? machine.cancelCountdown()
            synchronize()
        }
        if case .recording(let recordingID) = state {
            do {
                let shouldStop = try machine.beginStopping(
                    recordingID: recordingID
                )
                synchronize()
                if shouldStop {
                    try await dependencies.capture.stopRecording(
                        recordingID: recordingID
                    )
                }
            } catch {
                AppLogger.error(
                    "recording_stop_on_camera_exit_failed",
                    category: .recording
                )
            }
        }

        if let sessionID = activeSessionID {
            await dependencies.capture.stopPreview(sessionID: sessionID)
        }
        if pendingRecording != nil {
            await waitForRecordingFinalization()
        }
        eventTask?.cancel()
        eventTask = nil
        await dependencies.audio.deactivateAfterRecording()
        activeSessionID = nil
        previewSource = nil
        configuration = nil
        capabilities = .unavailable
        isShuttingDown = false
    }

    func dismissError() {
        errorMessage = nil
    }

    private func performCountdownAndStart() async {
        do {
            guard let sessionID = activeSessionID else {
                throw CaptureError.cameraUnavailable
            }
            let capacity =
                try await dependencies.storage
                    .availableCapacityForImportantUsage()
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            guard activeSessionID == sessionID else {
                throw CancellationError()
            }
            callbackGeneration = machine.generation
            try await dependencies.capture.startRecording(
                sessionID: sessionID,
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
            if let pendingRecording,
               !state.isActivelyRecording {
                try? await dependencies.files.deleteProject(
                    projectID: pendingRecording.projectID
                )
                self.pendingRecording = nil
            }
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

    private func startEventObservation(
        sessionID: UUID,
        generation: UInt64
    ) async {
        eventTask?.cancel()
        let events = await dependencies.capture.events(for: sessionID)
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else {
                    return
                }
                await self.handle(
                    event,
                    sessionID: sessionID,
                    generation: generation
                )
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

    private func handle(
        _ event: CaptureSessionEvent,
        sessionID: UUID,
        generation: UInt64
    ) async {
        switch event {
        case .recordingFinished(
            let recordingID,
            _,
            let duration
        ):
            await handleRecordingFinished(
                recordingID: recordingID,
                duration: duration
            )
            return
        case .recordingFailed(
            let recordingID,
            _,
            let error
        ):
            await preserveAfterFailure(
                recordingID: recordingID,
                reason: interruptionReason ?? .unknown
            )
            resumeRecordingFinalizationWaiter()
            if isCurrentLifecycle(sessionID, generation: generation) {
                fail(error)
            }
            return
        default:
            break
        }
        guard isCurrentLifecycle(sessionID, generation: generation) else {
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
            preparationTimeoutTask?.cancel()
            preparationTimeoutTask = nil
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
        case .recordingFinished, .recordingFailed:
            break
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
        defer {
            resumeRecordingFinalizationWaiter()
        }
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

    private func waitForRecordingFinalization() async {
        guard pendingRecording != nil else {
            return
        }
        recordingFinalizationTimeoutTask?.cancel()
        await withCheckedContinuation { continuation in
            recordingFinalizationWaiter = continuation
            recordingFinalizationTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(8))
                } catch {
                    return
                }
                await self?.recordingFinalizationDidTimeOut()
            }
        }
    }

    private func recordingFinalizationDidTimeOut() async {
        if let recordingID = pendingRecording?.recordingID {
            await preserveAfterFailure(
                recordingID: recordingID,
                reason: .unknown
            )
        }
        resumeRecordingFinalizationWaiter()
    }

    private func resumeRecordingFinalizationWaiter() {
        recordingFinalizationTimeoutTask?.cancel()
        recordingFinalizationTimeoutTask = nil
        let waiter = recordingFinalizationWaiter
        recordingFinalizationWaiter = nil
        waiter?.resume()
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
        preparationTimeoutTask?.cancel()
    }

    private func schedulePreparationTimeout(
        sessionID: UUID,
        generation: UInt64
    ) {
        preparationTimeoutTask?.cancel()
        preparationTimeoutTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await Task.sleep(
                    for: dependencies.preparationTimeout
                )
            } catch {
                return
            }
            await self.handlePreparationTimeout(
                sessionID: sessionID,
                generation: generation
            )
        }
    }

    private func handlePreparationTimeout(
        sessionID: UUID,
        generation: UInt64
    ) async {
        guard
            isCurrentLifecycle(sessionID, generation: generation),
            state == .requestingPermissions || state == .configuring
        else {
            return
        }
        fail(CaptureError.preparationTimedOut)
        await cleanUpLifecycleIfCurrent(
            sessionID: sessionID,
            generation: generation,
            keepFailureState: true
        )
    }

    private func cleanUpLifecycleIfCurrent(
        sessionID: UUID,
        generation: UInt64,
        keepFailureState: Bool
    ) async {
        guard isCurrentLifecycle(sessionID, generation: generation) else {
            return
        }
        isVisible = false
        preparationTimeoutTask?.cancel()
        preparationTimeoutTask = nil
        audioRouteTask?.cancel()
        await dependencies.capture.stopPreview(sessionID: sessionID)
        eventTask?.cancel()
        await dependencies.audio.deactivateAfterRecording()
        activeSessionID = nil
        previewSource = nil
        configuration = nil
        capabilities = .unavailable
        if !keepFailureState {
            machine.reset()
            synchronize()
        }
    }

    private func ensureCurrentLifecycle(
        _ sessionID: UUID,
        generation: UInt64
    ) throws {
        guard isCurrentLifecycle(sessionID, generation: generation) else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func isCurrentLifecycle(
        _ sessionID: UUID,
        generation: UInt64
    ) -> Bool {
        isVisible
            && activeSessionID == sessionID
            && lifecycleGeneration == generation
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

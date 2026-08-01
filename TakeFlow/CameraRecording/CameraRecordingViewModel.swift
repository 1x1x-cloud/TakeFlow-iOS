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
    @Published private(set) var focusAndExposureNoticeMessage: String?
    @Published private(set) var isFocusAndExposureLocked = false
    @Published private(set)
    var isFocusAndExposureOperationInProgress = false
    @Published private(set)
    var focusAndExposureFeedbackGeneration: UInt64 = 0
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
    private var cameraSwitchTask: Task<Void, Never>?
    private var preparationTimeoutTask: Task<Void, Never>?
    private var recordingStartTimeoutTask: Task<Void, Never>?
    private var recordingFinalizationTimeoutTask: Task<Void, Never>?
    private var recordingFinalizationWaiter:
        CheckedContinuation<Void, Never>?
    private var callbackGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var activeSessionID: UUID?
    private var interruptionReason: CaptureInterruptionReason?
    private var recordingStartConfirmed = false
    private var applicationInterruptionPending = false
    private var isVisible = false
    private var isShuttingDown = false
    private var focusAndExposureOperationGeneration: UInt64 = 0

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
        cameraSwitchTask?.cancel()
        preparationTimeoutTask?.cancel()
        recordingStartTimeoutTask?.cancel()
        recordingFinalizationTimeoutTask?.cancel()
    }

    var canSwitchCamera: Bool {
        machine.permitsCameraSwitch()
    }

    var canStartRecording: Bool {
        state == .ready
    }

    var canRetryPreparation: Bool {
        machine.permitsRecovery()
    }

    var canAdjustFocusAndExposure: Bool {
        guard
            isVisible,
            !isShuttingDown,
            activeSessionID != nil,
            !isFocusAndExposureOperationInProgress,
            capabilities.supportsFocusPoint
                || capabilities.supportsExposurePoint
        else {
            return false
        }
        switch state {
        case .ready, .recording:
            return true
        default:
            return false
        }
    }

    var canToggleFocusAndExposureLock: Bool {
        canAdjustFocusAndExposure
            && capabilities.supportsFocusLock
            && capabilities.supportsExposureLock
            && capabilities.supportsContinuousFocus
            && capabilities.supportsContinuousExposure
    }

#if DEBUG
    var isFakePreview: Bool {
        dependencies.isUITestFake
    }
#endif

    func prepare() async {
        if isVisible, activeSessionID != nil {
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
        resetFocusAndExposureUIState()
        interruptionReason = nil
        recordingStartConfirmed = false
        applicationInterruptionPending = false
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
            startAudioRouteObservation(
                sessionID: sessionID,
                generation: generation
            )
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
        guard canRetryPreparation else {
            return
        }
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
        resetFocusAndExposureUIState()
        let generation = lifecycleGeneration
        do {
            try machine.beginCameraSwitch()
            synchronize()
            schedulePreparationTimeout(
                sessionID: sessionID,
                generation: generation
            )
        } catch {
            fail(error)
            return
        }
        cameraSwitchTask?.cancel()
        cameraSwitchTask = Task { [weak self, capture = dependencies.capture] in
            do {
                try await capture.switchCamera(
                    sessionID: sessionID
                )
                guard let self else {
                    return
                }
                try self.ensureCurrentLifecycle(
                    sessionID,
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrentLifecycle(
                        sessionID,
                        generation: generation
                      )
                else {
                    return
                }
                self.preparationTimeoutTask?.cancel()
                self.preparationTimeoutTask = nil
                self.fail(error)
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
        resetFocusAndExposureUIState()
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
    ) async -> Bool {
        guard
            isVisible,
            !isShuttingDown,
            activeSessionID != nil,
            !isFocusAndExposureOperationInProgress,
            stateAllowsFocusAndExposure
        else {
            return false
        }
        guard
            capabilities.supportsFocusPoint
                || capabilities.supportsExposurePoint
        else {
            errorMessage = CaptureError.focusUnsupported.errorDescription
            return false
        }
        guard let sessionID = activeSessionID else {
            return false
        }
        let lifecycle = lifecycleGeneration
        let operation = beginFocusAndExposureOperation()
        defer {
            finishFocusAndExposureOperation(operation)
        }
        do {
            let result =
                try await dependencies.capture.setFocusAndExposurePoint(
                    sessionID: sessionID,
                    at: point
                )
            guard
                isCurrentLifecycle(sessionID, generation: lifecycle),
                stateAllowsFocusAndExposure,
                operation == focusAndExposureOperationGeneration
            else {
                return false
            }
            isFocusAndExposureLocked = false
            focusAndExposureNoticeMessage = focusNotice(for: result)
            return result.didApplyAnyAdjustment
        } catch {
            guard operation == focusAndExposureOperationGeneration else {
                return false
            }
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? CaptureError.focusUnsupported.errorDescription
            return false
        }
    }

    func toggleFocusAndExposureLock() async {
        guard canToggleFocusAndExposureLock else {
            if canAdjustFocusAndExposure {
                errorMessage =
                    CaptureError.focusUnsupported.errorDescription
            }
            return
        }
        guard let sessionID = activeSessionID else {
            return
        }
        let targetLocked = !isFocusAndExposureLocked
        let lifecycle = lifecycleGeneration
        let operation = beginFocusAndExposureOperation()
        defer {
            finishFocusAndExposureOperation(operation)
        }
        do {
            let applied =
                try await dependencies.capture.setFocusAndExposureLocked(
                    sessionID: sessionID,
                    locked: targetLocked
                )
            guard
                isCurrentLifecycle(sessionID, generation: lifecycle),
                stateAllowsFocusAndExposure,
                operation == focusAndExposureOperationGeneration
            else {
                return
            }
            guard
                targetLocked
                    ? applied.isFullyLocked
                    : !applied.focusLocked && !applied.exposureLocked
            else {
                throw targetLocked
                    ? CaptureError.focusUnsupported
                    : CaptureError.exposureUnsupported
            }
            isFocusAndExposureLocked = targetLocked
            focusAndExposureNoticeMessage = targetLocked
                ? CameraRecordingStrings.focusAndExposureLocked
                : CameraRecordingStrings.focusUnlocked
        } catch {
            guard operation == focusAndExposureOperationGeneration else {
                return
            }
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? CaptureError.focusUnsupported.errorDescription
        }
    }

    func sceneDidEnterBackground() {
        applicationInterruptionPending = true
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
        guard
            applicationInterruptionPending,
            let sessionID = activeSessionID
        else {
            return
        }
        applicationInterruptionPending = false
        Task {
            await dependencies.capture.handleApplicationForegrounded(
                sessionID: sessionID
            )
            handleInterruptionEnded(source: .applicationLifecycle)
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
        recordingStartTimeoutTask?.cancel()
        countdownTask?.cancel()
        storageMonitorTask?.cancel()
        cameraSwitchTask?.cancel()
        audioRouteTask?.cancel()

        if case .starting = state {
            try? machine.cancelCountdown()
            synchronize()
        }
        let recordingIDToStop: UUID?
        switch state {
        case .awaitingRecordingStart(let recordingID),
             .recording(let recordingID):
            recordingIDToStop = recordingID
        default:
            recordingIDToStop = nil
        }
        if let recordingID = recordingIDToStop {
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
        resetFocusAndExposureUIState()
        machine.reset()
        synchronize()
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
            guard activeSessionID == sessionID else {
                throw CancellationError()
            }
            callbackGeneration = machine.generation
            recordingStartConfirmed = false
            try machine.markRecordingStartRequested(
                recordingID: pending.recordingID
            )
            synchronize()
            scheduleRecordingStartTimeout(
                sessionID: sessionID,
                lifecycleGeneration: lifecycleGeneration,
                recordingID: pending.recordingID
            )
            try await dependencies.capture.startRecording(
                sessionID: sessionID,
                recordingID: pending.recordingID,
                outputURL: pending.temporaryURL,
                rotationAngle: captureRotationAngle
            )
        } catch is CancellationError {
            if let pendingRecording,
               !state.hasPendingOrActiveRecording {
                try? await dependencies.files.deleteProject(
                    projectID: pendingRecording.projectID
                )
                self.pendingRecording = nil
            }
            return
        } catch {
            recordingStartTimeoutTask?.cancel()
            recordingStartTimeoutTask = nil
            if let pendingRecording {
                try? await dependencies.files.deleteProject(
                    projectID: pendingRecording.projectID
                )
                self.pendingRecording = nil
                recordingStartConfirmed = false
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

    private func startAudioRouteObservation(
        sessionID: UUID,
        generation: UInt64
    ) {
        audioRouteTask?.cancel()
        audioRouteTask = Task { [weak self, audio = dependencies.audio] in
            let events = await audio.events()
            for await event in events {
                guard
                    let self,
                    !Task.isCancelled,
                    self.isCurrentLifecycle(
                        sessionID,
                        generation: generation
                    )
                else {
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
                    CaptureDiagnostics.record(
                        "audio_interruption_began",
                        state: self.state,
                        lifecycleGeneration: generation,
                        sessionID: sessionID,
                        cameraPosition: self.configuration?.position,
                        isRecording: self.state.isActivelyRecording,
                        isFinalizing: self.pendingRecording != nil,
                        isReconfiguring: self.state == .configuring,
                        interruptionReason: .audioSessionInterrupted,
                        interruptionEnded: false
                    )
                    await self.handleAudioInterruptionBegan()
                case .interruptionEnded:
                    CaptureDiagnostics.record(
                        "audio_interruption_ended",
                        state: self.state,
                        lifecycleGeneration: generation,
                        sessionID: sessionID,
                        cameraPosition: self.configuration?.position,
                        isRecording: self.state.isActivelyRecording,
                        isFinalizing: self.pendingRecording != nil,
                        isReconfiguring: self.state == .configuring,
                        interruptionReason: .audioSessionInterrupted,
                        interruptionEnded: true
                    )
                    self.handleInterruptionEnded(source: .audioSession)
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
        case .recordingStarted(let recordingID):
            await handleRecordingStarted(
                recordingID: recordingID,
                sessionID: sessionID,
                lifecycleGeneration: generation
            )
            return
        case .recordingFinished(
            let recordingID,
            _,
            let duration
        ):
            await handleRecordingFinished(
                recordingID: recordingID,
                duration: duration,
                sessionID: sessionID,
                lifecycleGeneration: generation
            )
            return
        case .recordingFailed(
            let recordingID,
            _,
            let error
        ):
            if !recordingStartConfirmed {
                await discardUnstartedRecording(recordingID: recordingID)
                finalizeUnstartedInterruptionIfNeeded(
                    recordingID: recordingID
                )
                resumeRecordingFinalizationWaiter()
                if isCurrentLifecycle(sessionID, generation: generation) {
                    fail(error)
                }
                return
            }
            let didPreserve = await preserveAfterFailure(
                recordingID: recordingID,
                reason: interruptionReason ?? .unknown
            )
            if didPreserve {
                try? machine.markInterruptedRecordingFinalized(
                    recordingID: recordingID
                )
                synchronize()
            }
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
            resetFocusAndExposureUIState()
            selectedResolution = configuration.format.resolution
            preparationTimeoutTask?.cancel()
            preparationTimeoutTask = nil
            cameraSwitchTask = nil
            if state == .configuring {
                do {
                    try machine.markReady()
                    synchronize()
                } catch {
                    fail(error)
                }
            }
        case .recordingStarted:
            break
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
            if
                let recordingID,
                case .awaitingRecordingStart(let requestedID) = state,
                requestedID == recordingID
            {
                recordingStartTimeoutTask?.cancel()
                recordingStartTimeoutTask = nil
            }
            interruptionReason = reason
            if machine.interrupt(
                recordingID: recordingID,
                reason: reason,
                source: interruptionSource(for: reason)
            ) {
                synchronize()
                noticeMessage = machine.permitsRecovery()
                    ? CameraRecordingStrings.interruptionEnded
                    : CameraRecordingStrings.interruptionMessage(
                        for: reason,
                        recordingWasActive: recordingID != nil
                    )
            }
        case .interruptionEnded:
            handleInterruptionEnded(source: .captureSession)
        case .audioRouteChanged(let route):
            audioRoute = route
        case .mediaServicesReset:
            interruptionReason = .mediaServicesReset
            _ = machine.interrupt(
                recordingID: pendingRecording?.recordingID,
                reason: .mediaServicesReset,
                source: .captureSession
            )
            synchronize()
        }
    }

    private func handleRecordingFinished(
        recordingID: UUID,
        duration: TimeInterval,
        sessionID: UUID,
        lifecycleGeneration: UInt64
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
        recordingStartTimeoutTask?.cancel()
        recordingStartTimeoutTask = nil
        storageMonitorTask?.cancel()

        guard recordingStartConfirmed else {
            await discardUnstartedRecording(recordingID: recordingID)
            finalizeUnstartedInterruptionIfNeeded(
                recordingID: recordingID
            )
            return
        }

        if let interruptionReason {
            let didPreserve = await preserveAfterFailure(
                recordingID: recordingID,
                reason: interruptionReason
            )
            if didPreserve {
                try? machine.markInterruptedRecordingFinalized(
                    recordingID: recordingID
                )
                synchronize()
            }
            return
        }

        do {
            let completed = try await dependencies.files.completeRecording(
                pending,
                duration: duration.isFinite ? max(duration, 0) : 0
            )
            pendingRecording = nil
            recordingStartConfirmed = false
            do {
                try machine.finish(
                    recordingID: recordingID,
                    fileURL: completed.fileURL,
                    generation: callbackGeneration
                )
            } catch CaptureError.staleCallback {
                return
            }
            completedRecording = completed
            recordingDuration = completed.duration
            synchronize()
            guard
                isCurrentLifecycle(
                    sessionID,
                    generation: lifecycleGeneration
                ),
                !isShuttingDown
            else {
                return
            }
            try machine.prepareForNextRecording(
                recordingID: recordingID,
                generation: callbackGeneration
            )
            synchronize()
        } catch {
            _ = await preserveAfterFailure(
                recordingID: recordingID,
                reason: .unknown
            )
            if isCurrentLifecycle(
                sessionID,
                generation: lifecycleGeneration
            ) {
                fail(error)
            }
        }
    }

    private func handleRecordingStarted(
        recordingID: UUID,
        sessionID: UUID,
        lifecycleGeneration: UInt64
    ) async {
        guard
            isCurrentLifecycle(
                sessionID,
                generation: lifecycleGeneration
            ),
            let pending = pendingRecording,
            pending.recordingID == recordingID,
            case .awaitingRecordingStart(let requestedID) = state,
            requestedID == recordingID
        else {
            return
        }

        recordingStartTimeoutTask?.cancel()
        recordingStartTimeoutTask = nil
        do {
            try machine.confirmRecordingStarted(
                recordingID: recordingID
            )
            recordingStartConfirmed = true
            recordingDuration = 0
            interruptionReason = nil
            synchronize()
            try await dependencies.files.markRecordingStarted(pending)
            guard
                isCurrentLifecycle(
                    sessionID,
                    generation: lifecycleGeneration
                ),
                case .recording(let activeID) = state,
                activeID == recordingID
            else {
                return
            }
            startStorageMonitor(recordingID: recordingID)
        } catch {
            interruptionReason = .unknown
            _ = machine.interrupt(
                recordingID: recordingID,
                reason: .unknown
            )
            synchronize()
            try? await dependencies.capture.stopRecording(
                recordingID: recordingID
            )
            errorMessage =
                CaptureError.filePreparationFailed.errorDescription
        }
    }

    private func discardUnstartedRecording(recordingID: UUID) async {
        guard
            let pending = pendingRecording,
            pending.recordingID == recordingID
        else {
            return
        }
        try? await dependencies.files.deleteProject(
            projectID: pending.projectID
        )
        pendingRecording = nil
        recordingStartConfirmed = false
        storageMonitorTask?.cancel()
    }

    private func finalizeUnstartedInterruptionIfNeeded(
        recordingID: UUID
    ) {
        guard
            case .interrupted(let interruptedID, _) = state,
            interruptedID == recordingID
        else {
            return
        }
        try? machine.markInterruptedRecordingFinalized(
            recordingID: recordingID
        )
        synchronize()
    }

    private func preserveAfterFailure(
        recordingID: UUID,
        reason: CaptureInterruptionReason
    ) async -> Bool {
        guard
            let pending = pendingRecording,
            pending.recordingID == recordingID
        else {
            return false
        }
        do {
            recoverableRecording =
                try await dependencies.files.preserveRecoverableRecording(
                    pending,
                    reason: reason
            )
            pendingRecording = nil
            recordingStartConfirmed = false
            return true
        } catch {
            AppLogger.error(
                "recording_recovery_metadata_failed",
                category: .persistence
            )
            return false
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
            if recordingStartConfirmed {
                _ = await preserveAfterFailure(
                    recordingID: recordingID,
                    reason: .unknown
                )
            } else {
                await discardUnstartedRecording(
                    recordingID: recordingID
                )
            }
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
                        reason: .storageSpaceLow,
                        source: .storageMonitor
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

    private func handleAudioInterruptionBegan() async {
        let recordingID: UUID?
        if case .awaitingRecordingStart(let activeID) = state {
            recordingID = activeID
        } else if case .recording(let activeID) = state {
            recordingID = activeID
        } else if case .stopping(let activeID) = state {
            recordingID = activeID
        } else {
            recordingID = nil
        }
        interruptionReason = .audioSessionInterrupted
        let didInterrupt = machine.interrupt(
            recordingID: recordingID,
            reason: .audioSessionInterrupted,
            source: .audioSession
        )
        if didInterrupt {
            synchronize()
            noticeMessage = machine.permitsRecovery()
                ? CameraRecordingStrings.interruptionEnded
                : CameraRecordingStrings.interruptionMessage(
                    for: .audioSessionInterrupted,
                    recordingWasActive: recordingID != nil
                )
        }
        if let recordingID {
            try? await dependencies.capture.stopRecording(
                recordingID: recordingID
            )
        }
    }

    private func handleAudioRouteLoss() async {
        guard case .recording = state else {
            return
        }
        await handleAudioInterruptionBegan()
    }

    private func handleInterruptionEnded(
        source: CaptureInterruptionSource
    ) {
        guard machine.endInterruption(source: source) else {
            return
        }
        synchronize()
        noticeMessage = CameraRecordingStrings.interruptionEnded
    }

    private func interruptionSource(
        for reason: CaptureInterruptionReason
    ) -> CaptureInterruptionSource {
        switch reason {
        case .applicationBackgrounded:
            .applicationLifecycle
        case .storageSpaceLow:
            .storageMonitor
        default:
            .captureSession
        }
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
        switch state {
        case .idle, .requestingPermissions, .configuring, .interrupted,
             .recoveryRequired, .failed:
            resetFocusAndExposureUIState()
        case .ready, .starting, .awaitingRecordingStart, .recording,
             .stopping, .finished:
            break
        }
        CaptureDiagnostics.record(
            "view_model_state",
            state: state,
            lifecycleGeneration: lifecycleGeneration,
            sessionID: activeSessionID,
            cameraPosition: configuration?.position,
            isRecording: {
                if case .recording = state {
                    return true
                }
                return false
            }(),
            isFinalizing: pendingRecording != nil
                && {
                    switch state {
                    case .awaitingRecordingStart, .stopping, .interrupted:
                        true
                    default:
                        false
                    }
                }(),
            isReconfiguring: state == .configuring,
            interruptionReason: interruptionReason,
            interruptionEnded: {
                if case .recoveryRequired = state {
                    return true
                }
                return nil
            }()
        )
    }

    private func cancelTasksForNewLifecycle() {
        countdownTask?.cancel()
        storageMonitorTask?.cancel()
        eventTask?.cancel()
        audioRouteTask?.cancel()
        cameraSwitchTask?.cancel()
        preparationTimeoutTask?.cancel()
        recordingStartTimeoutTask?.cancel()
        resetFocusAndExposureUIState()
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

    private func scheduleRecordingStartTimeout(
        sessionID: UUID,
        lifecycleGeneration: UInt64,
        recordingID: UUID
    ) {
        recordingStartTimeoutTask?.cancel()
        recordingStartTimeoutTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await Task.sleep(
                    for: dependencies.recordingStartTimeout
                )
            } catch {
                return
            }
            await self.handleRecordingStartTimeout(
                sessionID: sessionID,
                lifecycleGeneration: lifecycleGeneration,
                recordingID: recordingID
            )
        }
    }

    private func handleRecordingStartTimeout(
        sessionID: UUID,
        lifecycleGeneration: UInt64,
        recordingID: UUID
    ) async {
        guard
            isCurrentLifecycle(
                sessionID,
                generation: lifecycleGeneration
            ),
            case .awaitingRecordingStart(let requestedID) = state,
            requestedID == recordingID
        else {
            return
        }
        recordingStartTimeoutTask = nil
        machine.fail(.recordingStartTimedOut)
        synchronize()
        errorMessage = CaptureError.recordingStartTimedOut.errorDescription
        try? await dependencies.capture.stopRecording(
            recordingID: recordingID
        )
        await waitForRecordingFinalization()
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
        recordingStartTimeoutTask?.cancel()
        recordingStartTimeoutTask = nil
        audioRouteTask?.cancel()
        cameraSwitchTask?.cancel()
        await dependencies.capture.stopPreview(sessionID: sessionID)
        eventTask?.cancel()
        await dependencies.audio.deactivateAfterRecording()
        activeSessionID = nil
        previewSource = nil
        configuration = nil
        capabilities = .unavailable
        resetFocusAndExposureUIState()
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

    private var stateAllowsFocusAndExposure: Bool {
        switch state {
        case .ready, .recording:
            true
        default:
            false
        }
    }

    private func beginFocusAndExposureOperation() -> UInt64 {
        focusAndExposureOperationGeneration &+= 1
        isFocusAndExposureOperationInProgress = true
        return focusAndExposureOperationGeneration
    }

    private func finishFocusAndExposureOperation(_ operation: UInt64) {
        guard operation == focusAndExposureOperationGeneration else {
            return
        }
        isFocusAndExposureOperationInProgress = false
    }

    private func resetFocusAndExposureUIState() {
        focusAndExposureOperationGeneration &+= 1
        isFocusAndExposureOperationInProgress = false
        isFocusAndExposureLocked = false
        focusAndExposureNoticeMessage = nil
        focusAndExposureFeedbackGeneration &+= 1
    }

    private func focusNotice(
        for result: CapturePointAdjustmentResult
    ) -> String {
        switch (result.focusApplied, result.exposureApplied) {
        case (true, true):
            CameraRecordingStrings.focusAndExposureSet
        case (true, false):
            CameraRecordingStrings.focusSet
        case (false, true):
            CameraRecordingStrings.exposureSet
        case (false, false):
            CaptureError.focusUnsupported.errorDescription
                ?? CameraRecordingStrings.focusUnavailable
        }
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

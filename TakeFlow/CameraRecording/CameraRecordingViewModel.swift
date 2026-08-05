import Foundation
import SwiftUI

private enum CameraLifecycleDebugStage: Sendable {
    case idle
    case prepareStarted
    case drainingPreviousObservers
    case previousObserversDrained
    case captureEventStreamSubscribing
    case captureEventStreamActive
    case audioEventStreamSubscribing
    case audioEventStreamActive
    case captureConfiguring
    case captureConfigured
    case previewStarting
    case previewStartReturned
    case sessionReady
    case prepareFinished
    case disappearStarted
    case previewStopping
    case previewStopped
    case observersDraining
    case observersDrained
    case audioDeactivating
    case disappeared
    case cleanupStarted
    case cleanupFinished
    case failed
}

private struct BackgroundRecordingFinalizationContext: Equatable, Sendable {
    let token: RecordingBackgroundTaskToken
    let recordingID: UUID
    let sessionID: UUID
    let lifecycleGeneration: UInt64
    let episodeID: UUID
}

private enum RecordingFinalizationDisposition: Equatable, Sendable {
    case awaitingDisposition
    case normalCompletion
    case interrupted(
        reason: CaptureInterruptionReason,
        episodeID: UUID?
    )
    case failed

    var isEligibleForInterruption: Bool {
        switch self {
        case .awaitingDisposition, .interrupted:
            true
        case .normalCompletion, .failed:
            false
        }
    }
}

private struct FinalizedRecordingMedia: Equatable, Sendable {
    let outputURL: URL
    let duration: TimeInterval
}

private struct RecordingFinalizationFacts: Equatable, Sendable {
    let recording: PendingRecording
    let sessionID: UUID
    let lifecycleGeneration: UInt64
    var didConfirmRecordingStart = false
    var finalizedMedia: FinalizedRecordingMedia?
    var disposition: RecordingFinalizationDisposition =
        .awaitingDisposition
    var isReconciling = false
    var backgroundTaskExpired = false
}

private enum FinalizationDiagnosticEvent: Sendable {
    case pendingRegistered
    case awaitingDisposition
    case episodeLinked
    case factsReconciled
    case manifestCommitStarted
    case manifestCommitSucceeded
    case manifestCommitFailed
    case foregroundScanWaiting
    case recoverablePublished
}

#if DEBUG
private extension CameraLifecycleDebugStage {
    var diagnosticLabel: String {
        switch self {
        case .idle: "idle"
        case .prepareStarted: "prepare_started"
        case .drainingPreviousObservers: "draining_previous_observers"
        case .previousObserversDrained: "previous_observers_drained"
        case .captureEventStreamSubscribing:
            "capture_event_stream_subscribing"
        case .captureEventStreamActive: "capture_event_stream_active"
        case .audioEventStreamSubscribing:
            "audio_event_stream_subscribing"
        case .audioEventStreamActive: "audio_event_stream_active"
        case .captureConfiguring: "capture_configuring"
        case .captureConfigured: "capture_configured"
        case .previewStarting: "preview_starting"
        case .previewStartReturned: "preview_start_returned"
        case .sessionReady: "session_ready"
        case .prepareFinished: "prepare_finished"
        case .disappearStarted: "disappear_started"
        case .previewStopping: "preview_stopping"
        case .previewStopped: "preview_stopped"
        case .observersDraining: "observers_draining"
        case .observersDrained: "observers_drained"
        case .audioDeactivating: "audio_deactivating"
        case .disappeared: "disappeared"
        case .cleanupStarted: "cleanup_started"
        case .cleanupFinished: "cleanup_finished"
        case .failed: "failed"
        }
    }
}
#endif

@MainActor
final class CameraRecordingViewModel: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var previewSource: CapturePreviewSource?
    @Published private(set) var configuration: CaptureConfiguration?
    @Published private(set) var capabilities: CaptureCapabilities = .unavailable
    @Published private(set) var audioRoute: AudioInputRoute = .unavailable
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var completedRecording: CompletedRecording?
    @Published private(set) var recoverableReviewItems:
        [RecoverableRecordingReviewItem] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var interruptionNoticeMessage: String?
    @Published private(set) var requiresManualReprepare = false
    @Published private(set) var interruptionEpisode: InterruptionEpisode?
    @Published private(set) var focusAndExposureNoticeMessage: String?
    @Published private(set) var isFocusAndExposureLocked = false
    @Published private(set)
    var isFocusAndExposureOperationInProgress = false
    @Published private(set)
    var focusAndExposureFeedbackGeneration: UInt64 = 0
    @Published private(set) var captureRotationAngle = 0.0
    @Published private(set) var selectedResolution:
        VideoResolution = .fullHD1080p

    #if DEBUG
    let recoveryDiagnosticViewModelID = String(
        UUID().uuidString.prefix(8)
    )
    private(set) var ignoredFinalizationCallbackCountForTesting = 0
    var finalizedRecordingsAwaitingDispositionForTesting: Set<UUID> {
        Set(
            finalizationFactsByRecordingID.values.compactMap { facts in
                guard facts.finalizedMedia != nil,
                      case .awaitingDisposition = facts.disposition
                else {
                    return nil
                }
                return facts.recording.recordingID
            }
        )
    }
    private var lifecycleDebugStage: CameraLifecycleDebugStage = .idle
    private var lifecycleDebugTrace: [CameraLifecycleDebugStage] = [
        .idle
    ]
    #endif

    private let scriptID: UUID
    private let dependencies: CameraRecordingDependencies
    private var machine = RecordingStateMachine()
    private var pendingRecording: PendingRecording?
    private var finalizationFactsByRecordingID:
        [UUID: RecordingFinalizationFacts] = [:]
    private var eventTask: Task<Void, Never>?
    private var audioRouteTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var storageMonitorTask: Task<Void, Never>?
    private var cameraSwitchTask: Task<Void, Never>?
    private var preparationTimeoutTask: Task<Void, Never>?
    private var recordingStartTimeoutTask: Task<Void, Never>?
    private var recordingFinalizationTimeoutTask: Task<Void, Never>?
    private var recordingFinalizationWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var lifecycleCleanupInProgress = false
    private var lifecycleCleanupWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var callbackGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var activeSessionID: UUID?
    private var interruptionReason: CaptureInterruptionReason?
    private var recordingStartConfirmed = false
    private var applicationInterruptionPending = false
    private var isVisible = false
    private var isShuttingDown = false
    private var focusAndExposureOperationGeneration: UInt64 = 0
    private var recoverableOperationGenerations: [UUID: UInt64] = [:]
    private var manualReprepareTargetSessionID: UUID?
    private var manualReprepareTargetGeneration: UInt64?
    private var isManualReprepareInProgress = false
    private var scenePhaseName = "active"
    private var backgroundFinalizationContext:
        BackgroundRecordingFinalizationContext?

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
        recordingFinalizationWaiters.forEach { $0.resume() }
        lifecycleCleanupWaiters.forEach { $0.resume() }
    }

    var canSwitchCamera: Bool {
        machine.permitsCameraSwitch()
    }

    var canStartRecording: Bool {
        state == .ready
    }

    var canRetryPreparation: Bool {
        guard !isManualReprepareInProgress else {
            return false
        }
        if requiresManualReprepare {
            return interruptionEpisode?.isWaitingForRecoveryCommit != true
        }
        return machine.permitsRecovery()
    }

    var shouldShowManualReprepare: Bool {
        requiresManualReprepare || machine.permitsRecovery()
    }

    var recoverableRecording: RecoverableRecording? {
        recoverableReviewItems.last?.recording
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

    var canTriggerInterruptionAndEndForUITesting: Bool {
        guard case .recording = state else {
            return false
        }
        return manualInterruptionUITestController != nil
    }

    func triggerInterruptionAndEndForUITesting() async {
        guard
            case .recording = state,
            let controller = manualInterruptionUITestController
        else {
            return
        }
        _ = await controller.triggerInterruptionAndEndForUITesting()
    }

    private var manualInterruptionUITestController:
        (any CaptureSessionUITestControlling)?
    {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            dependencies.isUITestFake,
            arguments.contains("-ui-testing"),
            arguments.contains(
                "-ui-testing-capture-interruption-ends"
            )
        else {
            return nil
        }
        return dependencies.capture
            as? any CaptureSessionUITestControlling
    }
#endif

    func prepare() async {
        await prepareLifecycle(isManualReprepare: false)
    }

    private func prepareLifecycle(isManualReprepare: Bool) async {
        await waitForLifecycleCleanupIfNeeded()
        if isVisible, activeSessionID != nil {
            return
        }
        guard !isShuttingDown else {
            return
        }

        recordLifecycleDebugStage(.prepareStarted)
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        recordLifecycleDebugStage(.drainingPreviousObservers)
        await cancelTasksForNewLifecycle()
        recordLifecycleDebugStage(.previousObserversDrained)
        let sessionID = UUID()
        activeSessionID = sessionID
        if isManualReprepare {
            manualReprepareTargetSessionID = sessionID
            manualReprepareTargetGeneration = generation
        } else {
            requiresManualReprepare = false
            interruptionEpisode = nil
            interruptionNoticeMessage = nil
            manualReprepareTargetSessionID = nil
            manualReprepareTargetGeneration = nil
        }
        errorMessage = nil
        if !isManualReprepare {
            noticeMessage = nil
            completedRecording = nil
            recoverableReviewItems = []
#if DEBUG
            recordRecoverableItemsPublished()
#endif
        }
        recoverableOperationGenerations.removeAll()
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
            try ensureCurrentLifecycle(sessionID, generation: generation)
            await startAudioRouteObservation(
                sessionID: sessionID,
                generation: generation
            )
            try ensureCurrentLifecycle(sessionID, generation: generation)
            try await dependencies.audio.activateForRecording()
            try ensureCurrentLifecycle(sessionID, generation: generation)
            audioRoute = await dependencies.audio.currentInputRoute()
            try ensureCurrentLifecycle(sessionID, generation: generation)
            guard audioRoute.isAvailable else {
                throw CaptureError.microphoneUnavailable
            }
            recordLifecycleDebugStage(
                .captureConfiguring,
                sessionID: sessionID,
                generation: generation
            )
            try await dependencies.capture.configure(
                sessionID: sessionID,
                position: .front,
                preferredResolution: selectedResolution
            )
            try ensureCurrentLifecycle(sessionID, generation: generation)
            recordLifecycleDebugStage(
                .captureConfigured,
                sessionID: sessionID,
                generation: generation
            )
            recordLifecycleDebugStage(
                .previewStarting,
                sessionID: sessionID,
                generation: generation
            )
            try await dependencies.capture.startPreview(
                sessionID: sessionID
            )
            try ensureCurrentLifecycle(sessionID, generation: generation)
            recordLifecycleDebugStage(
                .previewStartReturned,
                sessionID: sessionID,
                generation: generation
            )
            let recovered =
                await dependencies.files.recoverPendingRecordings()
            try ensureCurrentLifecycle(sessionID, generation: generation)
            mergeRecoveredRecordings(recovered)
            if !recovered.isEmpty {
                noticeMessage =
                    CameraRecordingStrings.recoveredRecordingFound
            }
            recordLifecycleDebugStage(
                .prepareFinished,
                sessionID: sessionID,
                generation: generation
            )
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
        await waitForLifecycleCleanupIfNeeded()
        guard canRetryPreparation else {
            return
        }
        isManualReprepareInProgress = true
        defer { isManualReprepareInProgress = false }
        await viewDidDisappear()
        await prepareLifecycle(isManualReprepare: true)
    }

    func recoverableItem(
        recordingID: UUID
    ) -> RecoverableRecordingReviewItem? {
        recoverableReviewItems.first { $0.id == recordingID }
    }

    @discardableResult
    func validateRecoverableRecording(recordingID: UUID) async -> Bool {
        guard
            isVisible,
            let sessionID = activeSessionID,
            let index = recoverableIndex(recordingID: recordingID)
        else {
            return false
        }
        switch recoverableReviewItems[index].state {
        case .validating, .retaining, .deleting:
            return false
        case .playable, .retained:
            return true
        case .pending, .damaged, .operationFailed:
            break
        }

        let lifecycle = lifecycleGeneration
        let operation = beginRecoverableOperation(recordingID: recordingID)
        let recording = recoverableReviewItems[index].recording
        recoverableReviewItems[index].state = .validating
        let result = await dependencies.recoverableMediaValidator.validate(
            recording
        )
        guard isCurrentRecoverableOperation(
            recordingID: recordingID,
            operation: operation,
            sessionID: sessionID,
            lifecycle: lifecycle
        ), let currentIndex = recoverableIndex(recordingID: recordingID)
        else {
            return false
        }

        switch result {
        case .playable(let info):
            recoverableReviewItems[currentIndex].state = .playable(info)
            return true
        case .invalid(let failure):
            do {
                let damaged = try await dependencies.files
                    .markRecoverableRecordingDamaged(recording)
                guard isCurrentRecoverableOperation(
                    recordingID: recordingID,
                    operation: operation,
                    sessionID: sessionID,
                    lifecycle: lifecycle
                ), let updatedIndex = recoverableIndex(
                    recordingID: recordingID
                ) else {
                    return false
                }
                recoverableReviewItems[updatedIndex] =
                    RecoverableRecordingReviewItem(
                        recording: damaged,
                        state: .damaged(failure)
                    )
            } catch {
                recoverableReviewItems[currentIndex].state =
                    .damaged(failure)
            }
            return false
        }
    }

    func retainRecoverableRecording(recordingID: UUID) async -> Bool {
        guard
            isVisible,
            let sessionID = activeSessionID,
            let index = recoverableIndex(recordingID: recordingID)
        else {
            return false
        }
        let info: RecoverableMediaInfo
        switch recoverableReviewItems[index].state {
        case .playable(let mediaInfo):
            info = mediaInfo
        case .operationFailed(_, let mediaInfo?):
            info = mediaInfo
        case .retained:
            return true
        default:
            return false
        }
        let recording = recoverableReviewItems[index].recording
        let lifecycle = lifecycleGeneration
        let operation = beginRecoverableOperation(recordingID: recordingID)
        recoverableReviewItems[index].state = .retaining(info)
        do {
            let completed = try await dependencies.files
                .retainRecoverableRecording(
                    recording,
                    duration: info.duration
                )
            guard isCurrentRecoverableOperation(
                recordingID: recordingID,
                operation: operation,
                sessionID: sessionID,
                lifecycle: lifecycle
            ), let updatedIndex = recoverableIndex(
                recordingID: recordingID
            ) else {
                return false
            }
            recoverableReviewItems[updatedIndex].state =
                .retained(completed, info)
            completedRecording = completed
            noticeMessage = CameraRecordingStrings.recoverableRetained
            return true
        } catch {
            guard isCurrentRecoverableOperation(
                recordingID: recordingID,
                operation: operation,
                sessionID: sessionID,
                lifecycle: lifecycle
            ), let updatedIndex = recoverableIndex(
                recordingID: recordingID
            ) else {
                return false
            }
            recoverableReviewItems[updatedIndex].state = .operationFailed(
                CameraRecordingStrings.recoverableRetainFailed,
                info
            )
            return false
        }
    }

    func deleteRecoverableRecording(recordingID: UUID) async -> Bool {
        guard
            isVisible,
            let sessionID = activeSessionID,
            let index = recoverableIndex(recordingID: recordingID)
        else {
            return false
        }
        let item = recoverableReviewItems[index]
        let mediaInfo = mediaInfo(for: item.state)
        switch item.state {
        case .retaining, .deleting:
            return false
        case .retained:
            return false
        default:
            break
        }
        let lifecycle = lifecycleGeneration
        let operation = beginRecoverableOperation(recordingID: recordingID)
        recoverableReviewItems[index].state = .deleting
        do {
            try await dependencies.files.deleteRecoverableRecording(
                projectID: item.recording.projectID,
                recordingID: item.recording.recordingID
            )
            guard isCurrentRecoverableOperation(
                recordingID: recordingID,
                operation: operation,
                sessionID: sessionID,
                lifecycle: lifecycle
            ) else {
                return false
            }
            recoverableReviewItems.removeAll { $0.id == recordingID }
            recoverableOperationGenerations.removeValue(
                forKey: recordingID
            )
            return true
        } catch {
            guard isCurrentRecoverableOperation(
                recordingID: recordingID,
                operation: operation,
                sessionID: sessionID,
                lifecycle: lifecycle
            ), let updatedIndex = recoverableIndex(
                recordingID: recordingID
            ) else {
                return false
            }
            recoverableReviewItems[updatedIndex].state = .operationFailed(
                CameraRecordingStrings.recoverableDeleteFailed,
                mediaInfo
            )
            return false
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
            let requiresCaptureStop = markNormalCompletionIntent(
                recordingID: recordingID
            )
            let shouldStop = try machine.beginStopping(
                recordingID: recordingID
            )
            synchronize()
            guard shouldStop, requiresCaptureStop else {
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
        scenePhaseName = "background"
        applicationInterruptionPending = true
        if case .starting = state {
            cancelCountdown()
        }
        guard let sessionID = activeSessionID else {
            return
        }
        let recordingIDToStop = registerInterruption(
            recordingID: pendingRecording?.recordingID,
            reason: .applicationBackgrounded,
            source: .applicationBackgrounded
        )
        if
            let recordingID = interruptionEpisode?.recordingID,
            let episodeID = interruptionEpisode?.id
        {
            beginBackgroundFinalization(
                recordingID: recordingID,
                sessionID: sessionID,
                lifecycleGeneration: lifecycleGeneration,
                episodeID: episodeID
            )
        }
        Task {
            if let recordingIDToStop {
                try? await dependencies.capture.stopRecording(
                    recordingID: recordingIDToStop
                )
            }
            await dependencies.capture.handleApplicationBackgrounded(
                sessionID: sessionID
            )
        }
    }

    func sceneDidBecomeActive() {
        scenePhaseName = "active"
        guard
            applicationInterruptionPending,
            let sessionID = activeSessionID
        else {
            return
        }
        applicationInterruptionPending = false
        let generation = lifecycleGeneration
        Task {
            await dependencies.capture.handleApplicationForegrounded(
                sessionID: sessionID
            )
            guard isCurrentLifecycle(sessionID, generation: generation) else {
                return
            }
            handleInterruptionEnded(source: .applicationLifecycle)
            await refreshRecoverableQueueAfterForeground(
                sessionID: sessionID,
                lifecycleGeneration: generation
            )
        }
    }

    func viewDidDisappear() async {
        await waitForLifecycleCleanupIfNeeded()
        guard isVisible || activeSessionID != nil else {
            return
        }
        guard !isShuttingDown else {
            return
        }
        recordLifecycleDebugStage(.disappearStarted)
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
                let requiresCaptureStop = markNormalCompletionIntent(
                    recordingID: recordingID
                )
                let shouldStop = try machine.beginStopping(
                    recordingID: recordingID
                )
                synchronize()
                if shouldStop, requiresCaptureStop {
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
            recordLifecycleDebugStage(
                .previewStopping,
                sessionID: sessionID,
                generation: lifecycleGeneration
            )
            await dependencies.capture.stopPreview(sessionID: sessionID)
            recordLifecycleDebugStage(
                .previewStopped,
                sessionID: sessionID,
                generation: lifecycleGeneration
            )
        }
        if pendingRecording != nil {
            await waitForRecordingFinalization()
        }
        recordLifecycleDebugStage(.observersDraining)
        await cancelAndDrainObservationTasks()
        recordLifecycleDebugStage(.observersDrained)
        recordLifecycleDebugStage(.audioDeactivating)
        await dependencies.audio.deactivateAfterRecording()
        activeSessionID = nil
        previewSource = nil
        configuration = nil
        capabilities = .unavailable
        resetFocusAndExposureUIState()
        machine.reset()
        synchronize()
        isShuttingDown = false
        recordLifecycleDebugStage(.disappeared)
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
            registerPendingFinalization(
                pending,
                sessionID: sessionID,
                lifecycleGeneration: lifecycleGeneration
            )
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
                finalizationFactsByRecordingID.removeValue(
                    forKey: pendingRecording.recordingID
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
                finalizationFactsByRecordingID.removeValue(
                    forKey: pendingRecording.recordingID
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
        await cancelAndDrainCaptureObservation()
        recordLifecycleDebugStage(
            .captureEventStreamSubscribing,
            sessionID: sessionID,
            generation: generation
        )
        let events = await dependencies.capture.events(for: sessionID)
        guard isCurrentLifecycle(sessionID, generation: generation) else {
            return
        }
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
        recordLifecycleDebugStage(
            .captureEventStreamActive,
            sessionID: sessionID,
            generation: generation
        )
    }

    private func startAudioRouteObservation(
        sessionID: UUID,
        generation: UInt64
    ) async {
        await cancelAndDrainAudioObservation()
        recordLifecycleDebugStage(
            .audioEventStreamSubscribing,
            sessionID: sessionID,
            generation: generation
        )
        let events = await dependencies.audio.events()
        guard isCurrentLifecycle(sessionID, generation: generation) else {
            return
        }
        audioRouteTask = Task { [weak self] in
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
                case .interruptionBegan(let details):
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
                        interruptionEnded: false,
                        audioDetails: details
                    )
                    await self.handleAudioInterruptionBegan(details: details)
                case .interruptionEnded(let details):
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
                        interruptionEnded: true,
                        audioDetails: details
                    )
                    self.handleInterruptionEnded(
                        source: .audioSession,
                        audioDetails: details
                    )
                case .mediaServicesWereLost:
                    CaptureDiagnostics.record(
                        "audio_media_services_lost_received",
                        state: self.state,
                        lifecycleGeneration: generation,
                        sessionID: sessionID,
                        cameraPosition: self.configuration?.position,
                        isRecording: self.state.isActivelyRecording,
                        isFinalizing: self.pendingRecording != nil,
                        isReconfiguring: self.state == .configuring,
                        interruptionReason: .mediaServicesLost,
                        interruptionEnded: false
                    )
                    await self.handleAudioMediaServicesEvent(
                        reason: .mediaServicesLost
                    )
                case .mediaServicesWereReset:
                    CaptureDiagnostics.record(
                        "audio_media_services_reset_received",
                        state: self.state,
                        lifecycleGeneration: generation,
                        sessionID: sessionID,
                        cameraPosition: self.configuration?.position,
                        isRecording: self.state.isActivelyRecording,
                        isFinalizing: self.pendingRecording != nil,
                        isReconfiguring: self.state == .configuring,
                        interruptionReason: .mediaServicesReset,
                        interruptionEnded: true
                    )
                    await self.handleAudioMediaServicesEvent(
                        reason: .mediaServicesReset
                    )
                }
            }
        }
        recordLifecycleDebugStage(
            .audioEventStreamActive,
            sessionID: sessionID,
            generation: generation
        )
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
            let outputURL,
            let duration
        ):
            await handleRecordingFinished(
                recordingID: recordingID,
                outputURL: outputURL,
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
                if isMatchingInterruptionEpisode(
                    recordingID: recordingID,
                    sessionID: sessionID,
                    lifecycleGeneration: generation
                ) {
                    interruptionEpisode?.markAVFoundationFinalized()
                    interruptionEpisode?.markRecoveryManifestNotRequired()
                    settleInterruptionToRecoveryRequired()
                } else {
                    finalizeUnstartedInterruptionIfNeeded(
                        recordingID: recordingID
                    )
                }
                finishBackgroundFinalizationIfMatching(
                    recordingID: recordingID,
                    sessionID: sessionID,
                    lifecycleGeneration: generation,
                    stage: "did_finish_without_media"
                )
                resumeRecordingFinalizationWaiters()
                if isCurrentLifecycle(sessionID, generation: generation),
                   interruptionEpisode == nil {
                    fail(error)
                }
                return
            }
            let episodeMatches = isMatchingInterruptionEpisode(
                recordingID: recordingID,
                sessionID: sessionID,
                lifecycleGeneration: generation
            )
            if episodeMatches {
                interruptionEpisode?.markAVFoundationFinalized()
            }
            let didPreserve = await preserveAfterFailure(
                recordingID: recordingID,
                reason: interruptionEpisode?.primaryReason
                    ?? interruptionReason ?? .unknown
            )
            if episodeMatches {
                if didPreserve {
                    interruptionEpisode?.markRecoveryManifestCommitted()
                    await refreshRecoverableQueueForCurrentEpisode()
                    noticeMessage =
                        CameraRecordingStrings.recoveredRecordingFound
                } else {
                    interruptionEpisode?.markRecoveryManifestFailed()
                    errorMessage =
                        CaptureError.fileFinalizationFailed.errorDescription
                }
                settleInterruptionToRecoveryRequired()
                if !didPreserve {
                    interruptionNoticeMessage =
                        CameraRecordingStrings.recoveryCommitFailed
                }
            } else if didPreserve {
                try? machine.markInterruptedRecordingFinalized(
                    recordingID: recordingID
                )
                synchronize()
            }
            finishBackgroundFinalizationIfMatching(
                recordingID: recordingID,
                sessionID: sessionID,
                lifecycleGeneration: generation,
                stage: didPreserve
                    ? "manifest_committed" : "manifest_failed"
            )
            finalizationFactsByRecordingID.removeValue(
                forKey: recordingID
            )
            resumeRecordingFinalizationWaiters()
            if isCurrentLifecycle(sessionID, generation: generation),
               !episodeMatches {
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
            recordLifecycleDebugStage(
                .sessionReady,
                sessionID: sessionID,
                generation: generation
            )
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
                    if
                        manualReprepareTargetSessionID == sessionID,
                        manualReprepareTargetGeneration == generation
                    {
                        recordInterruptionDiagnostic(
                            "manual_reprepare_ready",
                            interruptionEnded: true
                        )
                        interruptionEpisode?
                            .clearManualReprepareAfterNewSessionReady()
                        requiresManualReprepare = false
                        interruptionEpisode = nil
                        interruptionNoticeMessage = nil
                        manualReprepareTargetSessionID = nil
                        manualReprepareTargetGeneration = nil
                    }
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
            let recordingIDToStop = registerInterruption(
                recordingID: recordingID,
                reason: reason,
                source: InterruptionEpisode.source(for: reason)
            )
            if let recordingIDToStop {
                try? await dependencies.capture.stopRecording(
                    recordingID: recordingIDToStop
                )
            }
        case .interruptionEnded(let reason):
            handleInterruptionEnded(
                source: .captureSession,
                reason: reason
            )
        case .audioRouteChanged(let route):
            audioRoute = route
        case .mediaServicesReset:
            let recordingIDToStop = registerInterruption(
                recordingID: pendingRecording?.recordingID,
                reason: .mediaServicesReset,
                source: .mediaServices
            )
            if let recordingIDToStop {
                try? await dependencies.capture.stopRecording(
                    recordingID: recordingIDToStop
                )
            }
        }
    }

    private func registerPendingFinalization(
        _ recording: PendingRecording,
        sessionID: UUID,
        lifecycleGeneration: UInt64
    ) {
        let facts = RecordingFinalizationFacts(
            recording: recording,
            sessionID: sessionID,
            lifecycleGeneration: lifecycleGeneration
        )
        finalizationFactsByRecordingID[recording.recordingID] = facts
        recordFinalizationDiagnostic(.pendingRegistered, facts: facts)
    }

    @discardableResult
    private func markNormalCompletionIntent(recordingID: UUID) -> Bool {
        guard var facts = finalizationFactsByRecordingID[recordingID] else {
            return true
        }
        guard case .awaitingDisposition = facts.disposition else {
            return facts.finalizedMedia == nil
        }
        facts.disposition = .normalCompletion
        finalizationFactsByRecordingID[recordingID] = facts
        let requiresCaptureStop = facts.finalizedMedia == nil
        if !requiresCaptureStop {
            Task { [weak self] in
                await self?.reconcileFinalizationIfPossible(
                    recordingID: recordingID
                )
            }
        }
        return requiresCaptureStop
    }

    private func matchingInterruptionEpisode(
        for facts: RecordingFinalizationFacts
    ) -> InterruptionEpisode? {
        guard
            let episode = interruptionEpisode,
            episode.recordingID == facts.recording.recordingID,
            episode.captureSessionID == facts.sessionID,
            episode.lifecycleGeneration == facts.lifecycleGeneration
        else {
            return nil
        }
        return episode
    }

    private func reconcileFinalizationIfPossible(
        recordingID: UUID
    ) async {
        guard var facts = finalizationFactsByRecordingID[recordingID] else {
            return
        }
        guard facts.finalizedMedia != nil, !facts.isReconciling else {
            return
        }

        switch facts.disposition {
        case .awaitingDisposition:
            return
        case .failed:
            finishFinalizationResolution(
                facts,
                backgroundStage: "failed"
            )
            return
        case .normalCompletion, .interrupted:
            break
        }

        if facts.backgroundTaskExpired,
           case .interrupted = facts.disposition {
            if isMatchingInterruptionEpisode(
                recordingID: recordingID,
                sessionID: facts.sessionID,
                lifecycleGeneration: facts.lifecycleGeneration
            ) {
                interruptionEpisode?.markAVFoundationFinalizationFailed()
                interruptionEpisode?.markRecoveryManifestFailed()
                settleInterruptionToRecoveryRequired()
            }
            finishFinalizationResolution(
                facts,
                backgroundStage: "expired"
            )
            return
        }

        facts.isReconciling = true
        finalizationFactsByRecordingID[recordingID] = facts
        recordFinalizationDiagnostic(.factsReconciled, facts: facts)

        switch facts.disposition {
        case .normalCompletion:
            await reconcileNormalCompletion(facts)
        case .interrupted(let reason, let episodeID):
            await reconcileInterruptedCompletion(
                facts,
                reason: reason,
                episodeID: episodeID
            )
        case .awaitingDisposition, .failed:
            break
        }
    }

    private func reconcileNormalCompletion(
        _ facts: RecordingFinalizationFacts
    ) async {
        let recordingID = facts.recording.recordingID
        guard let media = facts.finalizedMedia else {
            return
        }
        do {
            let completed = try await dependencies.files.completeRecording(
                facts.recording,
                duration: media.duration
            )
            clearPendingRecordingIfMatching(recordingID)
            let canFinishMachine: Bool
            if case .stopping(let stoppingID) = state {
                canFinishMachine = stoppingID == recordingID
            } else {
                canFinishMachine = false
            }
            if canFinishMachine {
                try machine.finish(
                    recordingID: recordingID,
                    fileURL: completed.fileURL,
                    generation: callbackGeneration
                )
            }
            completedRecording = completed
            recordingDuration = completed.duration
            synchronize()
            if
                canFinishMachine,
                isCurrentLifecycle(
                    facts.sessionID,
                    generation: facts.lifecycleGeneration
                ),
                !isShuttingDown,
                !requiresManualReprepare
            {
                try machine.prepareForNextRecording(
                    recordingID: recordingID,
                    generation: callbackGeneration
                )
                synchronize()
            }
            finishFinalizationResolution(
                facts,
                backgroundStage: "normal_completed"
            )
        } catch {
            _ = await preserveAfterFailure(
                recordingID: recordingID,
                reason: .unknown
            )
            finishFinalizationResolution(
                facts,
                backgroundStage: "normal_completion_failed"
            )
            if isCurrentLifecycle(
                facts.sessionID,
                generation: facts.lifecycleGeneration
            ) {
                fail(error)
            }
        }
    }

    private func reconcileInterruptedCompletion(
        _ facts: RecordingFinalizationFacts,
        reason: CaptureInterruptionReason,
        episodeID: UUID?
    ) async {
        let recordingID = facts.recording.recordingID
        if let episodeID {
            guard
                let episode = interruptionEpisode,
                episode.id == episodeID,
                episode.recordingID == recordingID,
                episode.captureSessionID == facts.sessionID,
                episode.lifecycleGeneration == facts.lifecycleGeneration
            else {
                finishFinalizationResolution(
                    facts,
                    backgroundStage: "stale_episode"
                )
                return
            }
            interruptionEpisode?.markAVFoundationFinalized()
        }
        recordFinalizationDiagnostic(.manifestCommitStarted, facts: facts)
        let didPreserve = await preserveAfterFailure(
            recordingID: recordingID,
            reason: reason
        )
        if didPreserve {
            if episodeID != nil {
                interruptionEpisode?.markRecoveryManifestCommitted()
                await refreshRecoverableQueueForCurrentEpisode()
            } else {
                try? machine.markInterruptedRecordingFinalized(
                    recordingID: recordingID
                )
                synchronize()
            }
            if episodeID != nil {
                noticeMessage =
                    CameraRecordingStrings.recoveredRecordingFound
            }
            recordFinalizationDiagnostic(
                .manifestCommitSucceeded,
                facts: facts
            )
        } else {
            if episodeID != nil {
                interruptionEpisode?.markRecoveryManifestFailed()
            }
            errorMessage = CaptureError.fileFinalizationFailed.errorDescription
            recordFinalizationDiagnostic(.manifestCommitFailed, facts: facts)
        }
        if episodeID != nil {
            settleInterruptionToRecoveryRequired()
            if !didPreserve {
                interruptionNoticeMessage =
                    CameraRecordingStrings.recoveryCommitFailed
            }
        }
        finishFinalizationResolution(
            facts,
            backgroundStage: didPreserve
                ? "manifest_committed" : "manifest_failed"
        )
    }

    private func finishFinalizationResolution(
        _ facts: RecordingFinalizationFacts,
        backgroundStage: String
    ) {
        let recordingID = facts.recording.recordingID
        finalizationFactsByRecordingID.removeValue(forKey: recordingID)
        clearPendingRecordingIfMatching(recordingID)
        finishBackgroundFinalizationIfMatching(
            recordingID: recordingID,
            sessionID: facts.sessionID,
            lifecycleGeneration: facts.lifecycleGeneration,
            stage: backgroundStage
        )
        resumeRecordingFinalizationWaiters()
    }

    private func clearPendingRecordingIfMatching(_ recordingID: UUID) {
        guard pendingRecording?.recordingID == recordingID else {
            return
        }
        pendingRecording = nil
        finalizationFactsByRecordingID.removeValue(forKey: recordingID)
        recordingStartConfirmed = false
    }

    private func handleRecordingFinished(
        recordingID: UUID,
        outputURL: URL,
        duration: TimeInterval,
        sessionID: UUID,
        lifecycleGeneration: UInt64
    ) async {
        guard var facts = finalizationFactsByRecordingID[recordingID] else {
            #if DEBUG
            ignoredFinalizationCallbackCountForTesting += 1
            #endif
            return
        }
        guard
            facts.sessionID == sessionID,
            facts.lifecycleGeneration == lifecycleGeneration,
            facts.recording.temporaryURL.standardizedFileURL
                == outputURL.standardizedFileURL
        else {
            #if DEBUG
            ignoredFinalizationCallbackCountForTesting += 1
            #endif
            return
        }
        recordingStartTimeoutTask?.cancel()
        recordingStartTimeoutTask = nil
        storageMonitorTask?.cancel()

        guard facts.didConfirmRecordingStart else {
            await discardUnstartedRecording(recordingID: recordingID)
            if isMatchingInterruptionEpisode(
                recordingID: recordingID,
                sessionID: sessionID,
                lifecycleGeneration: lifecycleGeneration
            ) {
                interruptionEpisode?.markAVFoundationFinalized()
                interruptionEpisode?.markRecoveryManifestNotRequired()
                settleInterruptionToRecoveryRequired()
            } else {
                finalizeUnstartedInterruptionIfNeeded(
                    recordingID: recordingID
                )
            }
            finishBackgroundFinalizationIfMatching(
                recordingID: recordingID,
                sessionID: sessionID,
                lifecycleGeneration: lifecycleGeneration,
                stage: "did_finish_without_media"
            )
            resumeRecordingFinalizationWaiters()
            return
        }

        facts.finalizedMedia = FinalizedRecordingMedia(
            outputURL: outputURL,
            duration: duration.isFinite ? max(duration, 0) : 0
        )
        if case .awaitingDisposition = facts.disposition,
           let episode = matchingInterruptionEpisode(for: facts) {
            facts.disposition = .interrupted(
                reason: episode.primaryReason,
                episodeID: episode.id
            )
        } else if case .awaitingDisposition = facts.disposition,
                  let interruptionReason {
            facts.disposition = .interrupted(
                reason: interruptionReason,
                episodeID: nil
            )
        }
        finalizationFactsByRecordingID[recordingID] = facts
        if case .awaitingDisposition = facts.disposition {
            recordFinalizationDiagnostic(.awaitingDisposition, facts: facts)
        }
        await reconcileFinalizationIfPossible(recordingID: recordingID)
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
            if var facts = finalizationFactsByRecordingID[recordingID] {
                facts.didConfirmRecordingStart = true
                finalizationFactsByRecordingID[recordingID] = facts
            }
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
            let recovered =
                try await dependencies.files.preserveRecoverableRecording(
                    pending,
                    reason: reason
                )
            if isVisible, !isShuttingDown {
                upsertRecoverableRecording(recovered)
                if let facts = finalizationFactsByRecordingID[recordingID] {
                    recordFinalizationDiagnostic(
                        .recoverablePublished,
                        facts: facts
                    )
                }
            }
            pendingRecording = nil
            recordingStartConfirmed = false
            return true
        } catch {
            AppLogger.error(
                "recording_recovery_metadata_failed",
                category: .persistence
            )
            pendingRecording = nil
            recordingStartConfirmed = false
            return false
        }
    }

    private func waitForRecordingFinalization() async {
        guard pendingRecording != nil else {
            return
        }
        await withCheckedContinuation { continuation in
            recordingFinalizationWaiters.append(continuation)
            guard recordingFinalizationTimeoutTask == nil else {
                return
            }
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
                interruptionEpisode?.markAVFoundationFinalizationFailed()
                interruptionEpisode?.markRecoveryManifestFailed()
                finalizationFactsByRecordingID.removeValue(
                    forKey: recordingID
                )
                pendingRecording = nil
                recordingStartConfirmed = false
                errorMessage =
                    CaptureError.fileFinalizationFailed.errorDescription
                interruptionNoticeMessage =
                    CameraRecordingStrings.recoveryCommitFailed
                settleInterruptionToRecoveryRequired()
            } else {
                await discardUnstartedRecording(
                    recordingID: recordingID
                )
                interruptionEpisode?.markAVFoundationFinalizationFailed()
                interruptionEpisode?.markRecoveryManifestNotRequired()
                settleInterruptionToRecoveryRequired()
            }
        }
        resumeRecordingFinalizationWaiters()
    }

    private func resumeRecordingFinalizationWaiters() {
        recordingFinalizationTimeoutTask?.cancel()
        recordingFinalizationTimeoutTask = nil
        let waiters = recordingFinalizationWaiters
        recordingFinalizationWaiters.removeAll()
        waiters.forEach { $0.resume() }
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

    private func handleAudioInterruptionBegan(
        details: AudioInterruptionDetails
    ) async {
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
        let recordingIDToStop = registerInterruption(
            recordingID: recordingID,
            reason: .audioSessionInterrupted,
            source: .audioSession,
            audioDetails: details
        )
        if let recordingIDToStop {
            try? await dependencies.capture.stopRecording(
                recordingID: recordingIDToStop
            )
        }
    }

    private func handleAudioRouteLoss() async {
        guard case .recording = state else {
            return
        }
        await handleAudioInterruptionBegan(details: .unspecified)
    }

    private func handleAudioMediaServicesEvent(
        reason: CaptureInterruptionReason
    ) async {
        let recordingIDToStop = registerInterruption(
            recordingID: pendingRecording?.recordingID,
            reason: reason,
            source: .mediaServices
        )
        if reason == .mediaServicesReset {
            interruptionNoticeMessage =
                CameraRecordingStrings.mediaServicesRestored
        }
        if let recordingIDToStop {
            try? await dependencies.capture.stopRecording(
                recordingID: recordingIDToStop
            )
        }
    }

    private func handleInterruptionEnded(
        source: CaptureInterruptionSource,
        reason: CaptureInterruptionReason? = nil,
        audioDetails: AudioInterruptionDetails? = nil
    ) {
        guard let episode = interruptionEpisode,
              episode.captureSessionID == activeSessionID,
              episode.lifecycleGeneration == lifecycleGeneration
        else {
            return
        }
        recordInterruptionDiagnostic(
            "interruption_source_ended_\(source.rawValue)",
            interruptionEnded: true,
            reason: reason,
            audioDetails: audioDetails
        )
        if !episode.isWaitingForRecoveryCommit {
            settleInterruptionToRecoveryRequired()
        }
    }

    private func registerInterruption(
        recordingID: UUID?,
        reason: CaptureInterruptionReason,
        source: InterruptionEpisodeSource,
        audioDetails: AudioInterruptionDetails? = nil
    ) -> UUID? {
        guard
            let sessionID = activeSessionID,
            isCurrentLifecycle(
                sessionID,
                generation: lifecycleGeneration
            )
        else {
            return nil
        }
        let lifecycle = lifecycleGeneration
        let activeRecordingID = finalizationCandidateRecordingID(
            preferred: recordingID ?? pendingRecording?.recordingID,
            sessionID: sessionID,
            lifecycleGeneration: lifecycle
        )
        let occurredDuringRecording = activeRecordingID.flatMap {
            finalizationFactsByRecordingID[$0]?.didConfirmRecordingStart
        } ?? false

        if var episode = interruptionEpisode,
           episode.captureSessionID == sessionID,
           episode.lifecycleGeneration == lifecycle {
            episode.merge(
                source: source,
                reason: reason,
                recordingID: activeRecordingID,
                occurredDuringRecording: occurredDuringRecording
            )
            interruptionEpisode = episode
        } else {
            interruptionEpisode = InterruptionEpisode(
                recordingID: activeRecordingID,
                captureSessionID: sessionID,
                lifecycleGeneration: lifecycle,
                source: source,
                reason: reason,
                occurredDuringRecording: occurredDuringRecording
            )
        }

        guard var episode = interruptionEpisode else {
            return nil
        }
        if let activeRecordingID,
           var facts = finalizationFactsByRecordingID[activeRecordingID] {
            facts.disposition = .interrupted(
                reason: episode.primaryReason,
                episodeID: episode.id
            )
            if facts.finalizedMedia != nil {
                episode.markAVFoundationFinalized()
            }
            finalizationFactsByRecordingID[activeRecordingID] = facts
            interruptionEpisode = episode
            recordFinalizationDiagnostic(.episodeLinked, facts: facts)
            if facts.finalizedMedia != nil {
                Task { [weak self] in
                    await self?.reconcileFinalizationIfPossible(
                        recordingID: activeRecordingID
                    )
                }
            }
        }
        requiresManualReprepare = true
        interruptionReason = episode.primaryReason
        let alreadyRecoveryRequired: Bool
        if case .recoveryRequired = state {
            alreadyRecoveryRequired = true
        } else {
            alreadyRecoveryRequired = false
        }
        if alreadyRecoveryRequired,
           !episode.isWaitingForRecoveryCommit {
            machine.updateInterruptionReason(episode.primaryReason)
        } else {
            _ = machine.interrupt(
                recordingID: activeRecordingID,
                reason: episode.primaryReason,
                source: machineSource(for: source)
            )
            machine.updateInterruptionReason(episode.primaryReason)
        }
        if !episode.occurredDuringRecording
            || (alreadyRecoveryRequired
                && !episode.isWaitingForRecoveryCommit) {
            try? machine.requireRecovery(reason: episode.primaryReason)
        }
        synchronize()
        if episode.didResolveRecoveryManifest,
           !episode.didCommitRecoveryManifest {
            interruptionNoticeMessage =
                CameraRecordingStrings.recoveryCommitFailed
        } else {
            interruptionNoticeMessage = CameraRecordingStrings
                .interruptionMessage(
                    for: episode.primaryReason,
                    recordingWasActive: episode.occurredDuringRecording
                )
        }

        let shouldRequestStop = episode.requestFinalizationIfNeeded()
        interruptionEpisode = episode
        recordInterruptionDiagnostic(
            "interruption_source_began_\(source.rawValue)",
            interruptionEnded: false,
            audioDetails: audioDetails
        )
        return shouldRequestStop ? episode.recordingID : nil
    }

    private func finalizationCandidateRecordingID(
        preferred: UUID?,
        sessionID: UUID,
        lifecycleGeneration: UInt64
    ) -> UUID? {
        if let preferred,
           let facts = finalizationFactsByRecordingID[preferred],
           facts.sessionID == sessionID,
           facts.lifecycleGeneration == lifecycleGeneration,
           facts.disposition.isEligibleForInterruption {
            return preferred
        }
        return finalizationFactsByRecordingID.values
            .filter {
                $0.sessionID == sessionID
                    && $0.lifecycleGeneration == lifecycleGeneration
                    && $0.didConfirmRecordingStart
                    && $0.disposition.isEligibleForInterruption
            }
            .sorted {
                $0.recording.createdAt > $1.recording.createdAt
            }
            .first?
            .recording.recordingID
    }

    private func settleInterruptionToRecoveryRequired() {
        guard let episode = interruptionEpisode else {
            return
        }
        machine.updateInterruptionReason(episode.primaryReason)
        try? machine.requireRecovery(reason: episode.primaryReason)
        synchronize()
        interruptionNoticeMessage = CameraRecordingStrings
            .recoveryRequiredMessage(for: episode.primaryReason)
        recordInterruptionDiagnostic(
            "interruption_recovery_required",
            interruptionEnded: true
        )
    }

    private func machineSource(
        for source: InterruptionEpisodeSource
    ) -> CaptureInterruptionSource {
        switch source {
        case .applicationBackgrounded:
            .applicationLifecycle
        case .audioSession, .microphoneInUseByAnotherClient:
            .audioSession
        case .captureSession, .cameraInUseByAnotherClient,
             .systemPressure, .mediaServices, .unknownSystem:
            .captureSession
        }
    }

    private func recordInterruptionDiagnostic(
        _ event: String,
        interruptionEnded: Bool? = nil,
        reason: CaptureInterruptionReason? = nil,
        audioDetails: AudioInterruptionDetails? = nil,
        manifestStage: String? = nil,
        backgroundTaskStage: String? = nil,
        recoveredItemCount: Int? = nil
    ) {
        let episode = interruptionEpisode
        CaptureDiagnostics.record(
            event,
            state: state,
            lifecycleGeneration: lifecycleGeneration,
            sessionID: activeSessionID,
            cameraPosition: configuration?.position,
            isRecording: state.isActivelyRecording,
            isFinalizing: pendingRecording != nil,
            isReconfiguring: state == .configuring,
            interruptionReason: reason ?? episode?.primaryReason,
            interruptionEnded: interruptionEnded,
            episodeID: episode?.id,
            recordingID: episode?.recordingID,
            scenePhase: scenePhaseName,
            audioDetails: audioDetails,
            didFinishFile: episode?.didFinishAVFoundationFinalization,
            didCommitManifest: episode?.didCommitRecoveryManifest,
            requiresManualReprepare: requiresManualReprepare,
            manifestStage: manifestStage,
            backgroundTaskStage: backgroundTaskStage,
            recoveredItemCount: recoveredItemCount
        )
    }

    private func recordFinalizationDiagnostic(
        _ event: FinalizationDiagnosticEvent,
        facts: RecordingFinalizationFacts
    ) {
        #if DEBUG
        let eventName: String
        switch event {
        case .pendingRegistered:
            eventName = "pending_finalization_registered"
        case .awaitingDisposition:
            eventName = "finalized_recording_awaiting_disposition"
        case .episodeLinked:
            eventName = "interruption_episode_recording_linked"
        case .factsReconciled:
            eventName = "finalization_facts_reconciled"
        case .manifestCommitStarted:
            eventName = "recovery_manifest_commit_started"
        case .manifestCommitSucceeded:
            eventName = "recovery_manifest_commit_succeeded"
        case .manifestCommitFailed:
            eventName = "recovery_manifest_commit_failed"
        case .foregroundScanWaiting:
            eventName = "foreground_scan_waiting_for_finalization"
        case .recoverablePublished:
            eventName = "recoverable_recording_published"
        }
        let episodeID: UUID?
        if case .interrupted(_, let id) = facts.disposition {
            episodeID = id
        } else {
            episodeID = nil
        }
        CaptureDiagnostics.record(
            eventName,
            state: state,
            lifecycleGeneration: facts.lifecycleGeneration,
            sessionID: facts.sessionID,
            cameraPosition: configuration?.position,
            isRecording: state.isActivelyRecording,
            isFinalizing: true,
            isReconfiguring: state == .configuring,
            interruptionReason: interruptionEpisode?.primaryReason,
            episodeID: episodeID,
            recordingID: facts.recording.recordingID,
            scenePhase: scenePhaseName,
            didFinishFile: facts.finalizedMedia != nil,
            didCommitManifest:
                interruptionEpisode?.didCommitRecoveryManifest,
            requiresManualReprepare: requiresManualReprepare,
            manifestStage: finalizationManifestStage(for: event),
            backgroundTaskStage:
                backgroundFinalizationContext == nil ? "inactive" : "active"
        )
        #endif
    }

    #if DEBUG
    private func finalizationManifestStage(
        for event: FinalizationDiagnosticEvent
    ) -> String? {
        switch event {
        case .manifestCommitStarted:
            "started"
        case .manifestCommitSucceeded, .recoverablePublished:
            "committed"
        case .manifestCommitFailed:
            "failed"
        case .pendingRegistered, .awaitingDisposition, .episodeLinked,
             .factsReconciled, .foregroundScanWaiting:
            nil
        }
    }
    #endif

#if DEBUG
    private func recoveryDiagnosticIDs(_ ids: [UUID]) -> String {
        guard !ids.isEmpty else {
            return "none"
        }
        return ids.map { String($0.uuidString.prefix(8)) }
            .joined(separator: ",")
    }

    private func recordRecoverableItemsPublished() {
        let ids = recoverableReviewItems.map(\.id)
        AppLogger.info(
            "capture_debug event=recoverable_items_published "
                + "published_count=\(ids.count) "
                + "published_ids=\(recoveryDiagnosticIDs(ids)) "
                + "view_model_id=\(recoveryDiagnosticViewModelID)",
            category: .recording
        )
    }

    private func recordRecoverableMerge(
        before: [UUID],
        incoming: [UUID]
    ) {
        let after = recoverableReviewItems.map(\.id)
        AppLogger.info(
            "capture_debug event=recoverable_items_merged "
                + "before_count=\(before.count) "
                + "before_ids=\(recoveryDiagnosticIDs(before)) "
                + "incoming_count=\(incoming.count) "
                + "incoming_ids=\(recoveryDiagnosticIDs(incoming)) "
                + "after_count=\(after.count) "
                + "after_ids=\(recoveryDiagnosticIDs(after)) "
                + "view_model_id=\(recoveryDiagnosticViewModelID)",
            category: .recording
        )
    }

    private func recordForegroundRecoveryScan(
        _ recordings: [RecoverableRecording],
        sessionID: UUID,
        lifecycleGeneration: UInt64
    ) {
        let ids = recordings.map(\.recordingID)
        AppLogger.info(
            "capture_debug event=foreground_recovery_scan_details "
                + "scanned_count=\(ids.count) "
                + "scanned_recording_ids=\(recoveryDiagnosticIDs(ids)) "
                + "lifecycle=\(lifecycleGeneration) "
                + "session=\(String(sessionID.uuidString.prefix(8))) "
                + "view_model_id=\(recoveryDiagnosticViewModelID)",
            category: .recording
        )
    }

    func recordSwiftUIRecoverableItemsObserved(
        _ items: [RecoverableRecordingReviewItem]
    ) {
        let ids = items.map(\.id)
        AppLogger.info(
            "capture_debug event=swiftui_recovery_items_observed "
                + "swiftui_observed_count=\(ids.count) "
                + "swiftui_observed_ids=\(recoveryDiagnosticIDs(ids)) "
                + "view_model_id=\(recoveryDiagnosticViewModelID)",
            category: .recording
        )
    }

    func recordRecoveryCardAppeared(recordingID: UUID) {
        AppLogger.info(
            "capture_debug event=recovery_card_appeared "
                + "recording_id=\(String(recordingID.uuidString.prefix(8))) "
                + "view_model_id=\(recoveryDiagnosticViewModelID)",
            category: .recording
        )
    }

    func recordRecoveryCardFrame(
        recordingID: UUID,
        globalFrame: CGRect,
        safeAreaFrame: CGRect
    ) {
        let intersection = globalFrame.intersection(safeAreaFrame)
        AppLogger.info(
            "capture_debug event=recovery_card_frame "
                + "recording_id=\(String(recordingID.uuidString.prefix(8))) "
                + "global_frame=\(recoveryDiagnosticRect(globalFrame)) "
                + "safe_area_frame=\(recoveryDiagnosticRect(safeAreaFrame)) "
                + "safe_area_intersection="
                + "\(recoveryDiagnosticRect(intersection)) "
                + "is_visible=\(!intersection.isNull && !intersection.isEmpty) "
                + "view_model_id=\(recoveryDiagnosticViewModelID)",
            category: .recording
        )
    }

    private func recoveryDiagnosticRect(_ rect: CGRect) -> String {
        guard !rect.isNull else {
            return "null"
        }
        return String(
            format: "%.1f,%.1f,%.1f,%.1f",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }
#endif

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
            }(),
            episodeID: interruptionEpisode?.id,
            recordingID: interruptionEpisode?.recordingID,
            scenePhase: scenePhaseName,
            didFinishFile:
                interruptionEpisode?.didFinishAVFoundationFinalization,
            didCommitManifest:
                interruptionEpisode?.didCommitRecoveryManifest,
            requiresManualReprepare: requiresManualReprepare
        )
    }

    private func cancelTasksForNewLifecycle() async {
        countdownTask?.cancel()
        storageMonitorTask?.cancel()
        cameraSwitchTask?.cancel()
        preparationTimeoutTask?.cancel()
        recordingStartTimeoutTask?.cancel()
        await cancelAndDrainObservationTasks()
        recoverableOperationGenerations.removeAll()
        resetFocusAndExposureUIState()
    }

    private func cancelAndDrainObservationTasks() async {
        let captureObservation = eventTask
        let audioObservation = audioRouteTask
        eventTask = nil
        audioRouteTask = nil
        captureObservation?.cancel()
        audioObservation?.cancel()
        await captureObservation?.value
        await audioObservation?.value
    }

    private func cancelAndDrainCaptureObservation() async {
        let observation = eventTask
        eventTask = nil
        observation?.cancel()
        await observation?.value
    }

    private func cancelAndDrainAudioObservation() async {
        let observation = audioRouteTask
        audioRouteTask = nil
        observation?.cancel()
        await observation?.value
    }

    private func recoverableIndex(recordingID: UUID) -> Int? {
        recoverableReviewItems.firstIndex { $0.id == recordingID }
    }

    private func mergeRecoveredRecordings(
        _ recordings: [RecoverableRecording]
    ) {
#if DEBUG
        let beforeIDs = recoverableReviewItems.map(\.id)
        let incomingIDs = recordings.map(\.recordingID)
#endif
        for recording in recordings {
            if let index = recoverableIndex(
                recordingID: recording.recordingID
            ) {
                let existingState = recoverableReviewItems[index].state
                recoverableReviewItems[index] = RecoverableRecordingReviewItem(
                    recording: recording,
                    state: existingState
                )
            } else {
                upsertRecoverableRecording(recording)
            }
        }
        recoverableReviewItems.sort {
            $0.recording.discoveredAt < $1.recording.discoveredAt
        }
#if DEBUG
        recordRecoverableMerge(before: beforeIDs, incoming: incomingIDs)
        recordRecoverableItemsPublished()
#endif
    }

    private func refreshRecoverableQueueForCurrentEpisode() async {
        guard let episode = interruptionEpisode else {
            return
        }
        let recovered = await dependencies.files.recoverCommittedRecordings()
        guard
            let current = interruptionEpisode,
            current.id == episode.id,
            current.captureSessionID == activeSessionID,
            current.lifecycleGeneration == lifecycleGeneration,
            isVisible,
            !isShuttingDown
        else {
            return
        }
        mergeRecoveredRecordings(recovered)
    }

    private func refreshRecoverableQueueAfterForeground(
        sessionID: UUID,
        lifecycleGeneration: UInt64
    ) async {
        let episodeID = interruptionEpisode?.id
        let episodeRecordingID = interruptionEpisode?.recordingID
        if let episodeRecordingID,
           let facts = finalizationFactsByRecordingID[episodeRecordingID],
           facts.finalizedMedia != nil {
            recordFinalizationDiagnostic(
                .foregroundScanWaiting,
                facts: facts
            )
        }
        recordInterruptionDiagnostic(
            "foreground_recovery_scan_started",
            manifestStage: "scan_started"
        )
        let recovered = await dependencies.files.recoverCommittedRecordings()
        guard
            isCurrentLifecycle(
                sessionID,
                generation: lifecycleGeneration
            ),
            isVisible,
            !isShuttingDown,
            interruptionEpisode?.id == episodeID
        else {
            return
        }

        // A scan can observe the current temporary file before AVFoundation's
        // didFinish callback. That file must not become a success card before
        // the matching recovery manifest has been committed.
        let safeToPublish = recovered.filter { recording in
            guard recording.recordingID == episodeRecordingID else {
                return true
            }
            return interruptionEpisode?.didCommitRecoveryManifest == true
        }
        mergeRecoveredRecordings(safeToPublish)
#if DEBUG
        recordForegroundRecoveryScan(
            recovered,
            sessionID: sessionID,
            lifecycleGeneration: lifecycleGeneration
        )
#endif
        recordInterruptionDiagnostic(
            "foreground_recovery_scan_finished",
            manifestStage: "scan_finished",
            recoveredItemCount: safeToPublish.count
        )
    }

    private func beginBackgroundFinalization(
        recordingID: UUID,
        sessionID: UUID,
        lifecycleGeneration: UInt64,
        episodeID: UUID
    ) {
        guard backgroundFinalizationContext == nil else {
            return
        }
        let token = dependencies.backgroundTasks.beginRecordingFinalization {
            [weak self] in
            self?.backgroundFinalizationDidExpire(
                recordingID: recordingID,
                sessionID: sessionID,
                lifecycleGeneration: lifecycleGeneration,
                episodeID: episodeID
            )
        }
        guard let token else {
            if var facts = finalizationFactsByRecordingID[recordingID] {
                facts.backgroundTaskExpired = true
                finalizationFactsByRecordingID[recordingID] = facts
            }
            interruptionEpisode?.markAVFoundationFinalizationFailed()
            interruptionEpisode?.markRecoveryManifestFailed()
            settleInterruptionToRecoveryRequired()
            interruptionNoticeMessage =
                CameraRecordingStrings.backgroundFinalizationDeferred
            recordInterruptionDiagnostic(
                "background_finalization_unavailable",
                manifestStage: "not_committed",
                backgroundTaskStage: "unavailable"
            )
            return
        }
        backgroundFinalizationContext = BackgroundRecordingFinalizationContext(
            token: token,
            recordingID: recordingID,
            sessionID: sessionID,
            lifecycleGeneration: lifecycleGeneration,
            episodeID: episodeID
        )
        recordInterruptionDiagnostic(
            "background_finalization_started",
            backgroundTaskStage: "active"
        )
    }

    private func backgroundFinalizationDidExpire(
        recordingID: UUID,
        sessionID: UUID,
        lifecycleGeneration: UInt64,
        episodeID: UUID
    ) {
        guard
            let context = backgroundFinalizationContext,
            context.recordingID == recordingID,
            context.sessionID == sessionID,
            context.lifecycleGeneration == lifecycleGeneration,
            context.episodeID == episodeID
        else {
            return
        }
        backgroundFinalizationContext = nil
        if var facts = finalizationFactsByRecordingID[recordingID] {
            facts.backgroundTaskExpired = true
            finalizationFactsByRecordingID[recordingID] = facts
        }
        guard
            isMatchingInterruptionEpisode(
                recordingID: recordingID,
                sessionID: sessionID,
                lifecycleGeneration: lifecycleGeneration
            )
        else {
            return
        }
        interruptionEpisode?.markAVFoundationFinalizationFailed()
        interruptionEpisode?.markRecoveryManifestFailed()
        settleInterruptionToRecoveryRequired()
        interruptionNoticeMessage =
            CameraRecordingStrings.backgroundFinalizationDeferred
        recordInterruptionDiagnostic(
            "background_finalization_expired",
            manifestStage: "not_committed",
            backgroundTaskStage: "expired"
        )
    }

    private func finishBackgroundFinalizationIfMatching(
        recordingID: UUID,
        sessionID: UUID,
        lifecycleGeneration: UInt64,
        stage: String
    ) {
        guard
            let context = backgroundFinalizationContext,
            context.recordingID == recordingID,
            context.sessionID == sessionID,
            context.lifecycleGeneration == lifecycleGeneration
        else {
            return
        }
        dependencies.backgroundTasks.endRecordingFinalization(context.token)
        backgroundFinalizationContext = nil
        recordInterruptionDiagnostic(
            "background_finalization_ended",
            backgroundTaskStage: stage
        )
    }

    private func isMatchingInterruptionEpisode(
        recordingID: UUID,
        sessionID: UUID,
        lifecycleGeneration: UInt64
    ) -> Bool {
        guard let episode = interruptionEpisode else {
            return false
        }
        return episode.recordingID == recordingID
            && episode.captureSessionID == sessionID
            && episode.lifecycleGeneration == lifecycleGeneration
    }

    private func upsertRecoverableRecording(
        _ recording: RecoverableRecording
    ) {
        let item = RecoverableRecordingReviewItem(
            recording: recording,
            state: recording.disposition == .damaged
                ? .damaged(.containerUnrecognized) : .pending
        )
        if let index = recoverableIndex(recordingID: recording.recordingID) {
            recoverableReviewItems[index] = item
        } else {
            recoverableReviewItems.append(item)
            recoverableReviewItems.sort {
                $0.recording.discoveredAt < $1.recording.discoveredAt
            }
        }
#if DEBUG
        recordRecoverableItemsPublished()
#endif
    }

    private func beginRecoverableOperation(recordingID: UUID) -> UInt64 {
        let next = (recoverableOperationGenerations[recordingID] ?? 0) &+ 1
        recoverableOperationGenerations[recordingID] = next
        return next
    }

    private func isCurrentRecoverableOperation(
        recordingID: UUID,
        operation: UInt64,
        sessionID: UUID,
        lifecycle: UInt64
    ) -> Bool {
        isCurrentLifecycle(sessionID, generation: lifecycle)
            && recoverableOperationGenerations[recordingID] == operation
    }

    private func mediaInfo(
        for state: RecoverableRecordingReviewState
    ) -> RecoverableMediaInfo? {
        switch state {
        case .playable(let info), .retaining(let info),
             .retained(_, let info):
            info
        case .operationFailed(_, let info):
            info
        default:
            nil
        }
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
        recordLifecycleDebugStage(
            .failed,
            sessionID: sessionID,
            generation: generation
        )
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
        if lifecycleCleanupInProgress {
            await waitForLifecycleCleanupIfNeeded()
            return
        }
        guard isCurrentLifecycle(sessionID, generation: generation) else {
            return
        }
        lifecycleCleanupInProgress = true
        recordLifecycleDebugStage(
            .cleanupStarted,
            sessionID: sessionID,
            generation: generation
        )
        isVisible = false
        preparationTimeoutTask?.cancel()
        preparationTimeoutTask = nil
        recordingStartTimeoutTask?.cancel()
        recordingStartTimeoutTask = nil
        cameraSwitchTask?.cancel()
        await dependencies.capture.stopPreview(sessionID: sessionID)
        await cancelAndDrainObservationTasks()
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
        recordLifecycleDebugStage(
            .cleanupFinished,
            sessionID: sessionID,
            generation: generation
        )
        finishLifecycleCleanup()
    }

    private func waitForLifecycleCleanupIfNeeded() async {
        guard lifecycleCleanupInProgress else {
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleCleanupWaiters.append(continuation)
        }
    }

    private func finishLifecycleCleanup() {
        lifecycleCleanupInProgress = false
        let waiters = lifecycleCleanupWaiters
        lifecycleCleanupWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func recordLifecycleDebugStage(
        _ stage: CameraLifecycleDebugStage,
        sessionID: UUID? = nil,
        generation: UInt64? = nil
    ) {
        #if DEBUG
        lifecycleDebugStage = stage
        lifecycleDebugTrace.append(stage)
        if lifecycleDebugTrace.count > 96 {
            lifecycleDebugTrace.removeFirst(
                lifecycleDebugTrace.count - 96
            )
        }
        CaptureDiagnostics.record(
            "lifecycle_stage_\(stage.diagnosticLabel)",
            state: state,
            lifecycleGeneration: generation ?? lifecycleGeneration,
            sessionID: sessionID ?? activeSessionID,
            cameraPosition: configuration?.position,
            isRecording: state.isActivelyRecording,
            isFinalizing: pendingRecording != nil,
            isReconfiguring: state == .configuring,
            interruptionReason: interruptionReason,
            episodeID: interruptionEpisode?.id,
            recordingID: interruptionEpisode?.recordingID,
            scenePhase: scenePhaseName,
            requiresManualReprepare: requiresManualReprepare
        )
        #endif
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

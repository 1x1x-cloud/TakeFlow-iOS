import AVFoundation
import XCTest
@testable import TakeFlow

final class RecordingStateMachineTests: XCTestCase {
    func testLegalPermissionConfigurationRecordingAndFinishFlow() throws {
        var machine = RecordingStateMachine()
        let recordingID = UUID()
        let outputURL = URL(fileURLWithPath: "/tmp/recording.mov")

        try machine.beginPermissionRequest()
        XCTAssertEqual(machine.state, .requestingPermissions)
        try machine.beginConfiguration()
        XCTAssertEqual(machine.state, .configuring)
        try machine.markReady()
        XCTAssertEqual(machine.state, .ready)
        try machine.beginCountdown(seconds: 3)
        XCTAssertEqual(machine.state, .starting(countdownRemaining: 3))
        try machine.updateCountdown(remaining: 2)
        try machine.markRecordingStartRequested(recordingID: recordingID)
        XCTAssertEqual(
            machine.state,
            .awaitingRecordingStart(recordingID: recordingID)
        )
        try machine.confirmRecordingStarted(recordingID: recordingID)
        XCTAssertEqual(machine.state, .recording(recordingID: recordingID))
        XCTAssertTrue(try machine.beginStopping(recordingID: recordingID))
        try machine.finish(
            recordingID: recordingID,
            fileURL: outputURL,
            generation: machine.generation
        )

        XCTAssertEqual(
            machine.state,
            .finished(recordingID: recordingID, fileURL: outputURL)
        )
        XCTAssertFalse(machine.permitsCameraSwitch())

        try machine.prepareForNextRecording(
            recordingID: recordingID,
            generation: machine.generation
        )
        XCTAssertEqual(machine.state, .ready)
        XCTAssertTrue(machine.permitsCameraSwitch())
    }

    func testCannotStartBeforeReady() {
        var machine = RecordingStateMachine()

        XCTAssertThrowsError(try machine.beginCountdown(seconds: 3)) {
            XCTAssertEqual($0 as? CaptureError, .invalidTransition)
        }
    }

    func testCountdownCanBeCancelledToReady() throws {
        var machine = try makeReadyMachine()

        try machine.beginCountdown(seconds: 3)
        try machine.cancelCountdown()

        XCTAssertEqual(machine.state, .ready)
    }

    func testRepeatedStartWhileStartingIsRejected() throws {
        var machine = try makeReadyMachine()
        try machine.beginCountdown(seconds: 3)

        XCTAssertThrowsError(try machine.beginCountdown(seconds: 3)) {
            XCTAssertEqual($0 as? CaptureError, .invalidTransition)
        }
    }

    func testStartRequestWaitsForExplicitDelegateConfirmation() throws {
        let recordingID = UUID()
        var machine = try makeReadyMachine()
        try machine.beginCountdown(seconds: 1)

        try machine.markRecordingStartRequested(recordingID: recordingID)

        XCTAssertEqual(
            machine.state,
            .awaitingRecordingStart(recordingID: recordingID)
        )
        XCTAssertFalse(machine.state.isActivelyRecording)
        XCTAssertTrue(machine.state.hasPendingOrActiveRecording)
        try machine.confirmRecordingStarted(recordingID: recordingID)
        XCTAssertEqual(
            machine.state,
            .recording(recordingID: recordingID)
        )
    }

    func testPendingStartCanBeStoppedOrInterruptedSafely() throws {
        let recordingID = UUID()
        var stopping = try makeReadyMachine()
        try stopping.beginCountdown(seconds: 1)
        try stopping.markRecordingStartRequested(recordingID: recordingID)
        XCTAssertTrue(
            try stopping.beginStopping(recordingID: recordingID)
        )
        XCTAssertEqual(
            stopping.state,
            .stopping(recordingID: recordingID)
        )

        var interrupted = try makeReadyMachine()
        try interrupted.beginCountdown(seconds: 1)
        try interrupted.markRecordingStartRequested(
            recordingID: recordingID
        )
        XCTAssertTrue(
            interrupted.interrupt(
                recordingID: recordingID,
                reason: .applicationBackgrounded
            )
        )
        XCTAssertEqual(
            interrupted.state,
            .interrupted(
                recordingID: recordingID,
                reason: .applicationBackgrounded
            )
        )
    }

    func testRepeatedStopCompletesOnlyOnce() throws {
        let recordingID = UUID()
        var machine = try makeRecordingMachine(recordingID: recordingID)

        XCTAssertTrue(try machine.beginStopping(recordingID: recordingID))
        XCTAssertFalse(try machine.beginStopping(recordingID: recordingID))
    }

    func testRecordingRejectsCameraSwitch() throws {
        let recordingID = UUID()
        let machine = try makeRecordingMachine(recordingID: recordingID)

        XCTAssertFalse(machine.permitsCameraSwitch())
    }

    func testCameraSwitchUsesExplicitConfigurationState() throws {
        var machine = try makeReadyMachine()

        try machine.beginCameraSwitch()

        XCTAssertEqual(machine.state, .configuring)
        XCTAssertFalse(machine.permitsCameraSwitch())
        XCTAssertThrowsError(try machine.beginCameraSwitch()) {
            XCTAssertEqual($0 as? CaptureError, .invalidTransition)
        }

        try machine.markReady()
        XCTAssertEqual(machine.state, .ready)
    }

    func testInterruptedAndFailedStatesCannotSwitchCamera() throws {
        var interrupted = try makeReadyMachine()
        XCTAssertTrue(
            interrupted.interrupt(
                recordingID: nil,
                reason: .cameraUnavailable
            )
        )
        XCTAssertFalse(interrupted.permitsCameraSwitch())

        var failed = try makeReadyMachine()
        failed.fail(.cameraUnavailable)
        XCTAssertFalse(failed.permitsCameraSwitch())
    }

    func testStaleCompletionCannotPrepareNextRecording() throws {
        let recordingID = UUID()
        var machine = try makeRecordingMachine(recordingID: recordingID)
        _ = try machine.beginStopping(recordingID: recordingID)
        let generation = machine.generation
        let outputURL = URL(fileURLWithPath: "/tmp/completed.mov")
        try machine.finish(
            recordingID: recordingID,
            fileURL: outputURL,
            generation: generation
        )
        machine.reset()

        XCTAssertThrowsError(
            try machine.prepareForNextRecording(
                recordingID: recordingID,
                generation: generation
            )
        ) {
            XCTAssertEqual($0 as? CaptureError, .staleCallback)
        }
        XCTAssertEqual(machine.state, .idle)
    }

    func testInterruptionWinsConcurrentStopOnlyOnce() throws {
        let recordingID = UUID()
        var machine = try makeRecordingMachine(recordingID: recordingID)
        XCTAssertTrue(try machine.beginStopping(recordingID: recordingID))

        XCTAssertTrue(
            machine.interrupt(
                recordingID: recordingID,
                reason: .audioSessionInterrupted
            )
        )
        XCTAssertFalse(
            machine.interrupt(
                recordingID: recordingID,
                reason: .applicationBackgrounded
            )
        )
    }

    func testIdleInterruptionRequiresExplicitRecoveryAfterItEnds()
        throws
    {
        var machine = try makeReadyMachine()

        XCTAssertTrue(
            machine.interrupt(
                recordingID: nil,
                reason: .videoDeviceInUseByAnotherClient,
                source: .captureSession
            )
        )
        XCTAssertFalse(machine.permitsRecovery())
        XCTAssertTrue(
            machine.endInterruption(source: .captureSession)
        )
        XCTAssertEqual(
            machine.state,
            .recoveryRequired(
                reason: .videoDeviceInUseByAnotherClient
            )
        )
        XCTAssertTrue(machine.permitsRecovery())
        XCTAssertFalse(machine.permitsCameraSwitch())
    }

    func testRecordingInterruptionWaitsForFileFinalizationAndAllSources()
        throws
    {
        let recordingID = UUID()
        var machine = try makeRecordingMachine(recordingID: recordingID)

        XCTAssertTrue(
            machine.interrupt(
                recordingID: recordingID,
                reason: .audioDeviceInUseByAnotherClient,
                source: .captureSession
            )
        )
        XCTAssertTrue(
            machine.interrupt(
                recordingID: recordingID,
                reason: .audioSessionInterrupted,
                source: .audioSession
            )
        )
        XCTAssertFalse(
            machine.endInterruption(source: .captureSession)
        )
        try machine.markInterruptedRecordingFinalized(
            recordingID: recordingID
        )
        XCTAssertFalse(machine.permitsRecovery())

        XCTAssertTrue(machine.endInterruption(source: .audioSession))
        XCTAssertEqual(
            machine.state,
            .recoveryRequired(
                reason: .audioDeviceInUseByAnotherClient
            )
        )
    }

    func testLateSecondInterruptionRevokesRecoveryUntilItAlsoEnds()
        throws
    {
        var machine = try makeReadyMachine()

        XCTAssertTrue(
            machine.interrupt(
                recordingID: nil,
                reason: .audioSessionInterrupted,
                source: .audioSession
            )
        )
        XCTAssertTrue(machine.endInterruption(source: .audioSession))
        XCTAssertTrue(machine.permitsRecovery())

        XCTAssertTrue(
            machine.interrupt(
                recordingID: nil,
                reason: .videoDeviceInUseByAnotherClient,
                source: .captureSession
            )
        )
        XCTAssertFalse(machine.permitsRecovery())
        XCTAssertEqual(
            machine.state,
            .interrupted(
                recordingID: nil,
                reason: .videoDeviceInUseByAnotherClient
            )
        )

        XCTAssertTrue(machine.endInterruption(source: .captureSession))
        XCTAssertEqual(
            machine.state,
            .recoveryRequired(
                reason: .videoDeviceInUseByAnotherClient
            )
        )
    }

    func testInterruptionEndArrivingBeforeBeginIsPairedWithinLifecycle()
        throws
    {
        var machine = try makeReadyMachine()

        XCTAssertFalse(
            machine.endInterruption(source: .applicationLifecycle)
        )
        XCTAssertTrue(
            machine.interrupt(
                recordingID: nil,
                reason: .applicationBackgrounded,
                source: .applicationLifecycle
            )
        )
        XCTAssertEqual(
            machine.state,
            .recoveryRequired(reason: .applicationBackgrounded)
        )
    }

    func testRecordingStillFinalizesWhenEndArrivesBeforeBegin()
        throws
    {
        let recordingID = UUID()
        var machine = try makeRecordingMachine(recordingID: recordingID)

        XCTAssertFalse(
            machine.endInterruption(source: .captureSession)
        )
        XCTAssertTrue(
            machine.interrupt(
                recordingID: recordingID,
                reason: .videoDeviceInUseByAnotherClient,
                source: .captureSession
            )
        )
        XCTAssertFalse(machine.permitsRecovery())

        try machine.markInterruptedRecordingFinalized(
            recordingID: recordingID
        )
        XCTAssertEqual(
            machine.state,
            .recoveryRequired(
                reason: .videoDeviceInUseByAnotherClient
            )
        )
    }

    func testAVFoundationInterruptionReasonsRemainDistinguishable() {
        XCTAssertEqual(
            AVFoundationCaptureService.domainInterruptionReason(
                fromAVFoundationRawValue: 1
            ),
            .applicationBackgrounded
        )
        XCTAssertEqual(
            AVFoundationCaptureService.domainInterruptionReason(
                fromAVFoundationRawValue: 2
            ),
            .audioDeviceInUseByAnotherClient
        )
        XCTAssertEqual(
            AVFoundationCaptureService.domainInterruptionReason(
                fromAVFoundationRawValue: 3
            ),
            .videoDeviceInUseByAnotherClient
        )
        XCTAssertEqual(
            AVFoundationCaptureService.domainInterruptionReason(
                fromAVFoundationRawValue: 4
            ),
            .videoDeviceNotAvailableWithMultipleForegroundApps
        )
        XCTAssertEqual(
            AVFoundationCaptureService.domainInterruptionReason(
                fromAVFoundationRawValue: 5
            ),
            .videoDeviceNotAvailableDueToSystemPressure
        )
        XCTAssertEqual(
            AVFoundationCaptureService.domainInterruptionReason(
                fromAVFoundationRawValue: 6
            ),
            .sensitiveContentMitigationActivated
        )
        XCTAssertEqual(
            AVFoundationCaptureService.domainInterruptionReason(
                fromAVFoundationRawValue: 999
            ),
            .unknown
        )
    }

    func testAVFoundationRuntimeErrorRecognizesOnlyMediaServicesReset() {
        let resetError = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.mediaServicesWereReset.rawValue
        )
        let unrelatedError = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.deviceWasDisconnected.rawValue
        )

        XCTAssertTrue(
            AVFoundationCaptureService
                .isMediaServicesResetRuntimeError(resetError)
        )
        XCTAssertFalse(
            AVFoundationCaptureService
                .isMediaServicesResetRuntimeError(unrelatedError)
        )
        XCTAssertFalse(
            AVFoundationCaptureService
                .isMediaServicesResetRuntimeError(
                    NSError(domain: NSCocoaErrorDomain, code: 0)
                )
        )
    }

    func testOldRecordingIDCannotStopCurrentRecording() throws {
        let currentID = UUID()
        var machine = try makeRecordingMachine(recordingID: currentID)

        XCTAssertThrowsError(
            try machine.beginStopping(recordingID: UUID())
        ) {
            XCTAssertEqual($0 as? CaptureError, .notRecording)
        }
        XCTAssertEqual(
            machine.state,
            .recording(recordingID: currentID)
        )
    }

    func testOldGenerationCannotFinishNewLifecycle() throws {
        var machine = try makeReadyMachine()
        let staleGeneration = machine.generation
        machine.reset()
        let recordingID = UUID()
        try machine.beginPermissionRequest()
        try machine.beginConfiguration()
        try machine.markReady()
        try machine.beginCountdown(seconds: 1)
        try machine.markRecordingStartRequested(recordingID: recordingID)
        try machine.confirmRecordingStarted(recordingID: recordingID)
        _ = try machine.beginStopping(recordingID: recordingID)

        XCTAssertThrowsError(
            try machine.finish(
                recordingID: recordingID,
                fileURL: URL(fileURLWithPath: "/tmp/stale.mov"),
                generation: staleGeneration
            )
        ) {
            XCTAssertEqual($0 as? CaptureError, .staleCallback)
        }
    }

    func testCompletionForDifferentRecordingCannotPolluteState() throws {
        let recordingID = UUID()
        var machine = try makeRecordingMachine(recordingID: recordingID)
        _ = try machine.beginStopping(recordingID: recordingID)

        XCTAssertThrowsError(
            try machine.finish(
                recordingID: UUID(),
                fileURL: URL(fileURLWithPath: "/tmp/other.mov"),
                generation: machine.generation
            )
        ) {
            XCTAssertEqual($0 as? CaptureError, .staleCallback)
        }
    }

    func testBackgroundInterruptionDoesNotBecomeReadyAutomatically()
        throws
    {
        let recordingID = UUID()
        var machine = try makeRecordingMachine(recordingID: recordingID)

        XCTAssertTrue(
            machine.interrupt(
                recordingID: recordingID,
                reason: .applicationBackgrounded
            )
        )
        XCTAssertEqual(
            machine.state,
            .interrupted(
                recordingID: recordingID,
                reason: .applicationBackgrounded
            )
        )
    }

    func testInterruptionEpisodeKeepsHighestPriorityReason() {
        let recordingID = UUID()
        var episode = InterruptionEpisode(
            recordingID: recordingID,
            captureSessionID: UUID(),
            lifecycleGeneration: 7,
            source: .applicationBackgrounded,
            reason: .applicationBackgrounded,
            occurredDuringRecording: true
        )

        episode.merge(
            source: .audioSession,
            reason: .audioSessionInterrupted,
            recordingID: recordingID
        )
        episode.merge(
            source: .cameraInUseByAnotherClient,
            reason: .videoDeviceInUseByAnotherClient,
            recordingID: recordingID
        )

        XCTAssertEqual(episode.primaryReason, .applicationBackgrounded)
        XCTAssertEqual(
            episode.sources,
            Set([
                .applicationBackgrounded,
                .audioSession,
                .cameraInUseByAnotherClient
            ])
        )
        XCTAssertEqual(episode.reasons.count, 3)
    }

    func testInterruptionEpisodeRequestsFinalizationOnlyOnce() {
        var episode = InterruptionEpisode(
            recordingID: UUID(),
            captureSessionID: UUID(),
            lifecycleGeneration: 4,
            source: .captureSession,
            reason: .unknown,
            occurredDuringRecording: true
        )

        XCTAssertTrue(episode.requestFinalizationIfNeeded())
        XCTAssertFalse(episode.requestFinalizationIfNeeded())
        XCTAssertTrue(episode.didRequestFinalization)
    }

    func testInterruptionEpisodeWaitsForFileAndManifestBeforeRecovery() {
        var episode = InterruptionEpisode(
            recordingID: UUID(),
            captureSessionID: UUID(),
            lifecycleGeneration: 2,
            source: .mediaServices,
            reason: .mediaServicesReset,
            occurredDuringRecording: true
        )

        XCTAssertTrue(episode.isWaitingForRecoveryCommit)
        episode.markAVFoundationFinalized()
        XCTAssertTrue(episode.isWaitingForRecoveryCommit)
        episode.markRecoveryManifestCommitted()
        XCTAssertFalse(episode.isWaitingForRecoveryCommit)
        XCTAssertTrue(episode.requiresManualReprepare)
    }

    func testInterruptionEpisodeManifestFailureResolvesWaitingWithoutSuccess() {
        var episode = InterruptionEpisode(
            recordingID: UUID(),
            captureSessionID: UUID(),
            lifecycleGeneration: 3,
            source: .captureSession,
            reason: .unknown,
            occurredDuringRecording: true
        )

        episode.markAVFoundationFinalized()
        episode.markRecoveryManifestFailed()

        XCTAssertFalse(episode.isWaitingForRecoveryCommit)
        XCTAssertTrue(episode.didFinishAVFoundationFinalization)
        XCTAssertTrue(episode.didResolveRecoveryManifest)
        XCTAssertFalse(episode.didCommitRecoveryManifest)
        XCTAssertTrue(episode.requiresManualReprepare)
    }

    func testInterruptionEpisodeLatchClearsOnlyAfterNewSessionReady() {
        var episode = InterruptionEpisode(
            recordingID: nil,
            captureSessionID: UUID(),
            lifecycleGeneration: 1,
            source: .audioSession,
            reason: .audioSessionInterrupted,
            occurredDuringRecording: false
        )

        episode.merge(
            source: .captureSession,
            reason: .unknown,
            recordingID: nil
        )
        XCTAssertTrue(episode.requiresManualReprepare)

        episode.clearManualReprepareAfterNewSessionReady()
        XCTAssertFalse(episode.requiresManualReprepare)
    }

    func testStorageThresholdsAreCentralizedAndOrdered() {
        let policy = RecordingStoragePolicy.production

        XCTAssertEqual(policy.minimumStartBytes, 500 * 1_024 * 1_024)
        XCTAssertEqual(policy.safeStopBytes, 250 * 1_024 * 1_024)
        XCTAssertGreaterThan(
            policy.minimumStartBytes,
            policy.safeStopBytes
        )
    }

    private func makeReadyMachine() throws -> RecordingStateMachine {
        var machine = RecordingStateMachine()
        try machine.beginPermissionRequest()
        try machine.beginConfiguration()
        try machine.markReady()
        return machine
    }

    private func makeRecordingMachine(
        recordingID: UUID
    ) throws -> RecordingStateMachine {
        var machine = try makeReadyMachine()
        try machine.beginCountdown(seconds: 1)
        try machine.markRecordingStartRequested(recordingID: recordingID)
        try machine.confirmRecordingStarted(recordingID: recordingID)
        return machine
    }
}

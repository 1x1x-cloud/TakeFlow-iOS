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
        try machine.markRecording(recordingID: recordingID)
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
        try machine.markRecording(recordingID: recordingID)
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
        try machine.markRecording(recordingID: recordingID)
        return machine
    }
}

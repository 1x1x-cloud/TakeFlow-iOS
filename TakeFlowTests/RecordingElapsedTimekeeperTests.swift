import Foundation
import XCTest
@testable import TakeFlow

final class RecordingElapsedTimekeeperTests: XCTestCase {
    func testElapsedTimeDoesNotExistBeforeConfirmedStart() {
        let source = TestMonotonicTimeSource()
        let recordingID = UUID()
        let timekeeper = RecordingElapsedTimekeeper(timeSource: source)

        source.advance(by: .seconds(2))

        XCTAssertNil(timekeeper.elapsed(for: recordingID))
    }

    func testConfirmedStartBeginsAtZeroAndAdvancesBy250Milliseconds()
        throws
    {
        let source = TestMonotonicTimeSource()
        let recordingID = UUID()
        var timekeeper = RecordingElapsedTimekeeper(timeSource: source)

        XCTAssertTrue(timekeeper.start(recordingID: recordingID))
        XCTAssertEqual(timekeeper.elapsed(for: recordingID), 0)

        source.advance(by: .milliseconds(250))

        let elapsed = try XCTUnwrap(
            timekeeper.elapsed(for: recordingID)
        )
        XCTAssertEqual(elapsed, 0.25, accuracy: 0.000_001)
    }

    func testDuplicateStartCannotResetElapsedTimeOrCreateSecondClock()
        throws
    {
        let source = TestMonotonicTimeSource()
        let recordingID = UUID()
        var timekeeper = RecordingElapsedTimekeeper(timeSource: source)
        XCTAssertTrue(timekeeper.start(recordingID: recordingID))
        source.advance(by: .seconds(1))

        XCTAssertFalse(timekeeper.start(recordingID: recordingID))

        let elapsed = try XCTUnwrap(
            timekeeper.elapsed(for: recordingID)
        )
        XCTAssertEqual(elapsed, 1, accuracy: 0.000_001)
    }

    func testConsecutiveRecordingsUseIndependentZeroPoints() {
        let source = TestMonotonicTimeSource()
        let firstID = UUID()
        let secondID = UUID()
        var timekeeper = RecordingElapsedTimekeeper(timeSource: source)
        XCTAssertTrue(timekeeper.start(recordingID: firstID))
        source.advance(by: .seconds(10))
        XCTAssertEqual(timekeeper.stop(recordingID: firstID), 10)

        source.advance(by: .seconds(5))
        XCTAssertTrue(timekeeper.start(recordingID: secondID))

        XCTAssertEqual(timekeeper.elapsed(for: secondID), 0)
        XCTAssertNil(timekeeper.elapsed(for: firstID))
    }

    func testRecoveryFragmentIntervalRemainsTwoSeconds() {
        XCTAssertEqual(
            RecordingMediaPolicy.movieFragmentIntervalSeconds,
            2
        )
    }

    func test1080pAnd4KUseIdenticalMonotonicTimingSemantics()
        throws
    {
        var elapsedByResolution: [VideoResolution: TimeInterval] = [:]

        for resolution in VideoResolution.allCases {
            let source = TestMonotonicTimeSource()
            let recordingID = UUID()
            var timekeeper = RecordingElapsedTimekeeper(
                timeSource: source
            )
            XCTAssertTrue(timekeeper.start(recordingID: recordingID))
            source.advance(by: .seconds(3.25))
            elapsedByResolution[resolution] = try XCTUnwrap(
                timekeeper.elapsed(for: recordingID)
            )
        }

        XCTAssertEqual(
            elapsedByResolution[.fullHD1080p],
            elapsedByResolution[.ultraHD4K]
        )
    }
}

private final class TestMonotonicTimeSource:
    RecordingMonotonicTimeProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000_000

    var uptimeNanoseconds: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by duration: Duration) {
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let nanoseconds =
            UInt64(seconds) * 1_000_000_000
            + UInt64(attoseconds / 1_000_000_000)
        lock.lock()
        value &+= nanoseconds
        lock.unlock()
    }
}

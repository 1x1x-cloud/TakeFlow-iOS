import XCTest
@testable import TakeFlow

final class TeleprompterPlaybackMachineTests: XCTestCase {
    func testIdleStartsCountdownAndCanCancel() {
        var machine = makeMachine()

        machine.start(
            at: 10,
            countdownSeconds: 3,
            hasReadableContent: true
        )
        XCTAssertEqual(
            machine.state,
            .countingDown(remainingSeconds: 3)
        )

        machine.cancelCountdown()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.scrollOffset, 0)
    }

    func testCountdownUsesElapsedTimeThenBeginsRunning() {
        var machine = makeMachine(speed: 40)
        machine.start(
            at: 100,
            countdownSeconds: 3,
            hasReadableContent: true
        )

        machine.tick(at: 101.2)
        XCTAssertEqual(
            machine.state,
            .countingDown(remainingSeconds: 2)
        )
        machine.tick(at: 103.5)

        XCTAssertEqual(machine.state, .running)
        XCTAssertEqual(machine.scrollOffset, 20, accuracy: 0.000_001)
    }

    func testPauseResumeAndPauseFreezesPosition() {
        var machine = makeMachine(speed: 50)
        machine.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )
        machine.tick(at: 2)
        machine.pause(at: 2)
        XCTAssertEqual(machine.state, .paused)
        XCTAssertEqual(machine.scrollOffset, 100, accuracy: 0.000_001)

        machine.tick(at: 20)
        XCTAssertEqual(machine.scrollOffset, 100, accuracy: 0.000_001)

        machine.resume(at: 20)
        machine.tick(at: 22)
        XCTAssertEqual(machine.state, .running)
        XCTAssertEqual(machine.scrollOffset, 200, accuracy: 0.000_001)
    }

    func testDifferentTickIntervalsProduceSameLogicalDistance() {
        var sparse = makeMachine(speed: 48)
        var irregular = makeMachine(speed: 48)
        sparse.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )
        irregular.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )

        sparse.tick(at: 10)
        for time in [0.013, 0.9, 2.7, 4.1, 7.77, 10] {
            irregular.tick(at: time)
        }

        XCTAssertEqual(
            sparse.scrollOffset,
            irregular.scrollOffset,
            accuracy: 0.000_001
        )
    }

    func testSimulated60And120HertzProduceSameDistance() {
        var sixty = makeMachine(speed: 60)
        var oneTwenty = makeMachine(speed: 60)
        sixty.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )
        oneTwenty.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )

        for frame in 1...600 {
            sixty.tick(at: Double(frame) / 60)
        }
        for frame in 1...1_200 {
            oneTwenty.tick(at: Double(frame) / 120)
        }

        XCTAssertEqual(sixty.scrollOffset, 600, accuracy: 0.000_001)
        XCTAssertEqual(
            sixty.scrollOffset,
            oneTwenty.scrollOffset,
            accuracy: 0.000_001
        )
    }

    func testBackgroundPausesAndDoesNotAccumulateTime() {
        var machine = makeMachine(speed: 50)
        machine.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )
        machine.enterBackground(at: 2)
        XCTAssertEqual(machine.state, .paused)
        XCTAssertEqual(machine.scrollOffset, 100, accuracy: 0.000_001)

        machine.returnToForeground(at: 200)
        machine.tick(at: 201)
        XCTAssertEqual(machine.scrollOffset, 100, accuracy: 0.000_001)

        machine.resume(at: 201)
        machine.tick(at: 202)
        XCTAssertEqual(machine.scrollOffset, 150, accuracy: 0.000_001)
    }

    func testDraggingRunningScriptResumesAtNewPosition() {
        var machine = makeMachine(speed: 40)
        machine.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )
        machine.beginDragging(at: 1)
        XCTAssertEqual(
            machine.state,
            .userDragging(resumesWhenReleased: true)
        )

        machine.updateDrag(
            offset: 300,
            anchor: ScriptReadingAnchor(characterOffset: 42)
        )
        machine.endDragging(
            at: 10,
            offset: 300,
            anchor: ScriptReadingAnchor(characterOffset: 42)
        )
        machine.tick(at: 11)

        XCTAssertEqual(machine.state, .running)
        XCTAssertEqual(machine.scrollOffset, 340, accuracy: 0.000_001)
        XCTAssertEqual(machine.anchor.characterOffset, 42)
    }

    func testReachingEndAndRestarting() {
        var machine = makeMachine(speed: 100, maximumOffset: 250)
        machine.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )
        machine.tick(at: 3)
        XCTAssertEqual(machine.state, .finished)
        XCTAssertEqual(machine.scrollOffset, 250)

        machine.restart()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.scrollOffset, 0)
        XCTAssertEqual(machine.anchor.characterOffset, 0)
    }

    func testEmptyScriptEntersTypedErrorSafely() {
        var machine = makeMachine()
        machine.start(
            at: 0,
            countdownSeconds: 3,
            hasReadableContent: false
        )
        XCTAssertEqual(machine.state, .error(.emptyScript))
        XCTAssertEqual(machine.scrollOffset, 0)
    }

    func testLayoutChangePreservesContentAnchor() {
        var machine = makeMachine()
        let anchor = ScriptReadingAnchor(characterOffset: 888)
        machine.updateLayout(
            maximumOffset: 2_000,
            restoredOffset: 720,
            anchor: anchor
        )

        XCTAssertEqual(machine.anchor, anchor)
        XCTAssertEqual(machine.scrollOffset, 720)
        XCTAssertEqual(machine.maximumScrollOffset, 2_000)
    }

    func testMirrorAndDisplayPreferencesAreIndependentState() {
        let preferences = TeleprompterPreferences(
            fontSize: 70,
            lineSpacing: 30,
            scrollSpeedPointsPerSecond: 90,
            horizontalMargin: 60,
            textAreaWidthFraction: 0.7,
            verticalPosition: -0.2,
            appearance: .light,
            isHorizontallyMirrored: true,
            isVerticallyMirrored: true,
            countdownSeconds: 10
        )

        XCTAssertTrue(preferences.isHorizontallyMirrored)
        XCTAssertTrue(preferences.isVerticallyMirrored)
        XCTAssertEqual(preferences.appearance, .light)
        XCTAssertEqual(preferences.countdownSeconds, 10)
    }

    func testLongScriptPlaybackUpdatesRemainResponsive() {
        let content = String(repeating: "长", count: 100_000)
        var machine = makeMachine(
            speed: 80,
            maximumOffset: 1_000_000
        )
        machine.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: !content.isEmpty
        )

        measure {
            for frame in 1...6_000 {
                machine.tick(at: Double(frame) / 120)
            }
        }
        XCTAssertEqual(machine.state, .running)
        XCTAssertEqual(machine.scrollOffset, 4_000, accuracy: 0.001)
    }

    private func makeMachine(
        speed: Double = 48,
        maximumOffset: Double = 10_000
    ) -> TeleprompterPlaybackMachine {
        var machine = TeleprompterPlaybackMachine(
            scrollSpeedPointsPerSecond: speed
        )
        machine.configure(
            initialAnchor: ScriptReadingAnchor(characterOffset: 0),
            maximumOffset: maximumOffset
        )
        return machine
    }
}

import XCTest
@testable import TakeFlow

@MainActor
final class CameraTeleprompterIntegrationTests: XCTestCase {
    func testContinuousCaptureEventsDoNotChangeTeleprompterDistance() {
        var standalone = makeMachine()
        var withCaptureOverlay = makeMachine()
        standalone.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )
        withCaptureOverlay.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )
        let recordingID = UUID()

        for frame in 1...1_200 {
            let time = Double(frame) / 120
            standalone.tick(at: time)
            let event = CaptureSessionEvent.duration(
                recordingID: recordingID,
                seconds: time
            )
            if case .duration = event {
                withCaptureOverlay.tick(at: time)
            }
        }

        XCTAssertEqual(
            standalone.scrollOffset,
            withCaptureOverlay.scrollOffset,
            accuracy: 0.000_001
        )
    }

    func testCameraOverlayKeepsSingleGlobalCharacterAnchor() {
        let document = TeleprompterDocument(
            content: String(
                repeating: "摄像提词跨块锚点🙂。\n",
                count: 10_000
            )
        )
        let globalOffset = document.characterCount * 3 / 4
        let location = document.location(
            forGlobalCharacterOffset: globalOffset
        )

        XCTAssertEqual(
            document.globalCharacterOffset(
                chunkIndex: location.chunkIndex,
                localCharacterOffset: location.localCharacterOffset
            ),
            globalOffset
        )
        XCTAssertLessThanOrEqual(
            TeleprompterTextView.Coordinator.textCacheCapacity,
            8
        )
    }

    func testCaptureEventsDoNotRebuildDocumentContentVersion() {
        let document = TeleprompterDocument(
            content: String(repeating: "性能回归文本。", count: 12_500)
        )
        let revision = document.contentRevision
        let recordingID = UUID()

        for index in 0..<10_000 {
            _ = CaptureSessionEvent.duration(
                recordingID: recordingID,
                seconds: Double(index) / 30
            )
        }

        XCTAssertEqual(document.contentRevision, revision)
    }

    private func makeMachine() -> TeleprompterPlaybackMachine {
        var machine = TeleprompterPlaybackMachine(
            scrollSpeedPointsPerSecond: 72
        )
        machine.configure(
            initialAnchor: ScriptReadingAnchor(characterOffset: 0),
            maximumOffset: 100_000
        )
        return machine
    }
}

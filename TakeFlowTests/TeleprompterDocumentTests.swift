import XCTest
@testable import TakeFlow

final class TeleprompterDocumentTests: XCTestCase {
    func testReadableContentFlagIsPrecomputedWithIndex() {
        XCTAssertFalse(
            TeleprompterDocument(content: " \n\t").hasReadableContent
        )
        XCTAssertTrue(
            TeleprompterDocument(content: " \n🙂").hasReadableContent
        )
    }

    func testChunkBoundariesPreserveEveryCharacterExactlyOnce() {
        let content = String(
            repeating: "第一段中文🙂 English 123。\n第二段继续👨‍👩‍👧‍👦。\n",
            count: 500
        )
        let document = TeleprompterDocument(content: content)

        XCTAssertEqual(document.reconstructedContent(), content)
        XCTAssertEqual(
            document.chunks.reduce(0) { $0 + $1.characterCount },
            content.count
        )
        for pair in zip(document.chunks, document.chunks.dropFirst()) {
            XCTAssertEqual(
                pair.0.characterRange.upperBound,
                pair.1.characterRange.lowerBound
            )
        }
    }

    func testGlobalAndLocalOffsetsRoundTripAcrossAllBoundaries() {
        let content = String(repeating: "段落内容🙂。\n", count: 2_000)
        let document = TeleprompterDocument(content: content)
        var offsets = [0, content.count]
        for chunk in document.chunks {
            offsets.append(chunk.characterRange.lowerBound)
            offsets.append(chunk.characterRange.upperBound)
            offsets.append(max(0, chunk.characterRange.upperBound - 1))
        }

        for offset in Set(offsets) {
            let location = document.location(
                forGlobalCharacterOffset: offset
            )
            XCTAssertEqual(
                document.globalCharacterOffset(
                    chunkIndex: location.chunkIndex,
                    localCharacterOffset: location.localCharacterOffset
                ),
                offset
            )
        }
    }

    func testEmojiCombiningCharactersAndMixedLanguagesAreNeverSplit() {
        let composed = "你e\u{301}好👨‍👩‍👧‍👦🇨🇳🙂ABC，123。\n"
        let content = String(repeating: composed, count: 300)
        let document = TeleprompterDocument(
            content: content,
            targetChunkCharacterCount: 31,
            maximumChunkCharacterCount: 43
        )

        XCTAssertEqual(document.reconstructedContent(), content)
        XCTAssertEqual(
            document.chunks.map(\.characterCount).reduce(0, +),
            content.count
        )
        XCTAssertTrue(
            document.chunks.dropLast().allSatisfy {
                $0.characterCount <= 43
            }
        )
    }

    func testParagraphBoundaryIsPreferredWhenAvailable() {
        let firstParagraph = String(repeating: "段", count: 1_700) + "\n"
        let content = firstParagraph + String(repeating: "后", count: 2_000)
        let document = TeleprompterDocument(content: content)

        XCTAssertEqual(document.chunks[0].text, firstParagraph)
        XCTAssertEqual(
            document.chunks[0].characterRange,
            0..<firstParagraph.count
        )
    }

    func testParagraphLongerThanMaximumUsesSafeCharacterBoundaries() {
        let content = String(repeating: "👨‍👩‍👧‍👦", count: 1_000)
        let document = TeleprompterDocument(
            content: content,
            targetChunkCharacterCount: 100,
            maximumChunkCharacterCount: 120
        )

        XCTAssertEqual(document.reconstructedContent(), content)
        XCTAssertTrue(
            document.chunks.allSatisfy { $0.characterCount <= 120 }
        )
    }

    func testQuarterHalfThreeQuarterAndNearEndLocationsAreDirect() {
        let content = String(repeating: "稿", count: 100_000)
        let document = TeleprompterDocument(content: content)

        for offset in [25_000, 50_000, 75_000, 99_500] {
            let location = document.location(
                forGlobalCharacterOffset: offset
            )
            XCTAssertEqual(
                document.globalCharacterOffset(
                    chunkIndex: location.chunkIndex,
                    localCharacterOffset: location.localCharacterOffset
                ),
                offset
            )
        }
    }

    func testContentRevisionInvalidatesSameLengthChangedText() {
        let original = TeleprompterDocument(
            content: String(repeating: "甲", count: 10_000)
        )
        let updated = TeleprompterDocument(
            content: String(repeating: "乙", count: 10_000)
        )

        XCTAssertNotEqual(
            original.contentRevision,
            updated.contentRevision
        )
        XCTAssertNotEqual(original, updated)
    }

    func testChunkCacheHasHardLimitAndCanReleaseNonCurrentEntries() {
        var cache = TeleprompterChunkCache<String>(capacity: 8)
        for index in 0..<100 {
            cache.insert("chunk-\(index)", for: index)
        }

        XCTAssertEqual(cache.count, 8)
        XCTAssertNotNil(cache.value(for: 99))
        cache.retain(keys: [98, 99])
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(Set(cache.values.keys), [98, 99])
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    func testAutomaticScrollingCanCrossChunkAndKeepGlobalAnchor() {
        let document = TeleprompterDocument(
            content: String(repeating: "自动滚动段落。\n", count: 2_000)
        )
        XCTAssertGreaterThan(document.chunks.count, 2)
        var machine = TeleprompterPlaybackMachine(
            scrollSpeedPointsPerSecond: 100
        )
        machine.configure(
            initialAnchor: ScriptReadingAnchor(characterOffset: 0),
            maximumOffset: 10_000
        )
        machine.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )
        machine.tick(at: 20)
        let secondChunkAnchor =
            document.chunks[1].characterRange.lowerBound + 10
        machine.updateVisibleAnchor(
            ScriptReadingAnchor(characterOffset: secondChunkAnchor)
        )

        XCTAssertEqual(machine.state, .running)
        XCTAssertEqual(machine.scrollOffset, 2_000)
        XCTAssertEqual(machine.anchor.characterOffset, secondChunkAnchor)
    }

    func testManualDraggingCanMoveForwardAndBackwardAcrossChunks() {
        let document = TeleprompterDocument(
            content: String(repeating: "拖动段落。\n", count: 3_000)
        )
        var machine = TeleprompterPlaybackMachine(
            scrollSpeedPointsPerSecond: 50
        )
        machine.configure(
            initialAnchor: ScriptReadingAnchor(characterOffset: 0),
            maximumOffset: 20_000
        )
        machine.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )

        let forwardAnchor =
            document.chunks[min(3, document.chunks.count - 1)]
                .characterRange.lowerBound
        machine.beginDragging(at: 1)
        machine.updateDrag(
            offset: 8_000,
            anchor: ScriptReadingAnchor(characterOffset: forwardAnchor)
        )
        machine.endDragging(
            at: 2,
            offset: 8_000,
            anchor: ScriptReadingAnchor(characterOffset: forwardAnchor)
        )
        XCTAssertEqual(machine.anchor.characterOffset, forwardAnchor)
        XCTAssertEqual(machine.state, .running)

        let backwardAnchor =
            document.chunks[1].characterRange.lowerBound
        machine.beginDragging(at: 3)
        machine.updateDrag(
            offset: 2_000,
            anchor: ScriptReadingAnchor(characterOffset: backwardAnchor)
        )
        machine.endDragging(
            at: 4,
            offset: 2_000,
            anchor: ScriptReadingAnchor(characterOffset: backwardAnchor)
        )
        XCTAssertEqual(machine.anchor.characterOffset, backwardAnchor)
        XCTAssertEqual(machine.state, .running)
    }

    func testPauseResumeAndRestartRemainSingleStateMachineAcrossChunks() {
        let document = TeleprompterDocument(
            content: String(repeating: "状态机段落。\n", count: 2_000)
        )
        var machine = TeleprompterPlaybackMachine(
            scrollSpeedPointsPerSecond: 100
        )
        machine.configure(
            initialAnchor: ScriptReadingAnchor(
                characterOffset:
                    document.chunks[1].characterRange.lowerBound
            ),
            initialOffset: 4_000,
            maximumOffset: 20_000
        )
        machine.start(
            at: 0,
            countdownSeconds: 0,
            hasReadableContent: true
        )
        machine.pause(at: 2)
        let pausedOffset = machine.scrollOffset
        machine.tick(at: 20)
        XCTAssertEqual(machine.scrollOffset, pausedOffset)

        machine.resume(at: 20)
        machine.tick(at: 21)
        XCTAssertEqual(machine.scrollOffset, pausedOffset + 100)

        machine.restart()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.scrollOffset, 0)
        XCTAssertEqual(machine.anchor.characterOffset, 0)
    }
}

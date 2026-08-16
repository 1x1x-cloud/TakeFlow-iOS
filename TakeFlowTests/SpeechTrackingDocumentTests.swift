import XCTest
@testable import TakeFlow

final class SpeechTrackingDocumentTests: XCTestCase {
    private let builder = SpeechDocumentBuilder()

    func testEmptyAndPunctuationOnlyDocumentsHaveNoSegments() async throws {
        for content in ["", " \t\n", "……！？🙂"] {
            let result = try await builder.buildDocument(
                from: content,
                contentRevision: 7
            )
            XCTAssertFalse(result.document.hasReadableContent)
            XCTAssertTrue(result.document.segments.isEmpty)
            XCTAssertEqual(
                result.document.sourceCharacterCount,
                content.count
            )
        }
    }

    func testSingleCharacterDocumentUsesHalfOpenCharacterRange() async throws {
        let document = try await build("稿")

        XCTAssertEqual(document.segments.count, 1)
        XCTAssertEqual(
            document.segments[0].sourceRange,
            CharacterRange(start: 0, end: 1)
        )
        XCTAssertEqual(document.segments[0].normalizedUnits.map(\.value), ["稿"])
    }

    func testChineseEnglishAndNumbersNormalizeDeterministically() async throws {
        let document = try await build("你好世界。HELLO TakeFlow 12345!")

        XCTAssertEqual(
            document.segments.flatMap(\.normalizedUnits).map(\.value),
            ["你", "好", "世", "界", "hello", "takeflow", "12345"]
        )
    }

    func testPureChineseAndPureEnglishSplitAtApprovedTerminators()
        async throws
    {
        let chinese = try await build("第一句话。第二句话！第三句话？")
        let english = try await build(
            "This is first sentence. This is second sentence! This is third sentence?"
        )

        XCTAssertEqual(chinese.segments.count, 3)
        XCTAssertEqual(english.segments.count, 3)
        XCTAssertEqual(
            english.segments.map { $0.normalizedUnits.map(\.value) },
            [
                ["this", "is", "first", "sentence"],
                ["this", "is", "second", "sentence"],
                ["this", "is", "third", "sentence"]
            ]
        )
    }

    func testCRLFAndLFCreateParagraphBoundaries() async throws {
        let document = try await build("第一段\r\nSecond line\n第三段")

        XCTAssertEqual(document.segments.count, 3)
        XCTAssertEqual(document.segments.map(\.sourceRange.start), [0, 4, 16])
        XCTAssertEqual(
            document.segments.map { $0.normalizedUnits.map(\.value) },
            [["第", "一", "段"], ["second", "line"], ["第", "三", "段"]]
        )
    }

    func testContinuousWhitespaceAndBlankLinesDoNotCreateFakeSegments()
        async throws
    {
        let document = try await build("甲乙丙丁。\n\n\t  戊己庚辛。")

        XCTAssertEqual(document.segments.count, 2)
        XCTAssertEqual(
            document.segments.flatMap(\.normalizedUnits).map(\.value),
            ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛"]
        )
    }

    func testContinuousPunctuationQuotesAndParenthesesStayWithReadableText()
        async throws
    {
        let content = "“你好？！”（下一句）...Final!』"
        let document = try await build(content)

        XCTAssertFalse(document.segments.isEmpty)
        XCTAssertEqual(document.segments.first?.sourceRange.start, 0)
        XCTAssertEqual(document.segments.last?.sourceRange.end, content.count)
        XCTAssertTrue(
            document.segments.allSatisfy { !$0.normalizedUnits.isEmpty }
        )
    }

    func testEmojiAndExtendedGraphemeClustersAreNeverSplit() async throws {
        let content = "A👨‍👩‍👧‍👦B👍🏽🇨🇳 e\u{301}，结束。"
        let document = try await build(content)

        XCTAssertEqual(document.sourceCharacterCount, content.count)
        XCTAssertEqual(
            document.segments.flatMap(\.normalizedUnits).map(\.value),
            ["a", "b", "é", "结", "束"]
        )
        XCTAssertTrue(
            document.segments.allSatisfy {
                $0.sourceRange.start >= 0
                    && $0.sourceRange.end <= content.count
            }
        )
    }

    func testFullWidthCharactersUseCompatibilityNormalization() async throws {
        let document = try await build("ＡＢＣ１２３，ＴａｋｅＦｌｏｗ。")

        XCTAssertEqual(
            document.segments.flatMap(\.normalizedUnits).map(\.value),
            ["abc", "123", "takeflow"]
        )
    }

    func testTextWithoutTrailingPunctuationRetainsFinalRange() async throws {
        let content = "没有末尾标点 mixed 42"
        let document = try await build(content)

        XCTAssertEqual(document.segments.last?.sourceRange.end, content.count)
        XCTAssertEqual(document.segments.last?.normalizedUnits.last?.value, "42")
    }

    func testSoftBoundaryOnlySplitsLongHardSentence() async throws {
        let short = "甲乙丙丁，戊己庚辛。"
        let long = String(repeating: "甲", count: 24)
            + "，"
            + String(repeating: "乙", count: 24)
            + "。"

        let shortDocument = try await build(short)
        let longDocument = try await build(long)

        XCTAssertEqual(shortDocument.segments.count, 1)
        XCTAssertEqual(longDocument.segments.count, 2)
    }

    func testOverlongSentenceChunksAtSafeUnitBoundaries() async throws {
        let content = String(repeating: "稿", count: 121)
        let document = try await build(content)

        XCTAssertEqual(
            document.segments.map { $0.normalizedUnits.count },
            [48, 48, 25]
        )
        XCTAssertEqual(document.segments.first?.sourceRange.start, 0)
        XCTAssertEqual(document.segments.last?.sourceRange.end, 121)
    }

    func testShortSegmentsMergeWithinButNotAcrossParagraphs() async throws {
        let sameParagraph = try await build("甲。乙丙丁戊。")
        let separateParagraphs = try await build("甲。\n乙丙丁戊。")

        XCTAssertEqual(sameParagraph.segments.count, 1)
        XCTAssertEqual(separateParagraphs.segments.count, 2)
    }

    func testRepeatedSentencesKeepIndependentStablePositions() async throws {
        let content = "重复句子。\n重复句子。\n重复句子。"
        let document = try await build(content)

        XCTAssertEqual(document.segments.count, 3)
        XCTAssertEqual(Set(document.segments.map(\.id)).count, 3)
        XCTAssertEqual(document.segments.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(document.segments.map(\.sourceRange.start), [0, 6, 12])
    }

    func testSegmentRangesSelectExactOriginalCharacters() async throws {
        let content = "引号“第一句！”  Second sentence.\n末句🙂"
        let document = try await build(content)
        let characters = Array(content)

        for segment in document.segments {
            let source = String(characters[segment.sourceRange.range])
            let normalized = try SpeechTextNormalizer().normalize(
                source,
                sourceStart: CharacterAnchor(offset: segment.sourceRange.start),
                unitStart: segment.unitRange.start
            )
            XCTAssertEqual(
                normalized.normalizedUnits.map(\.value),
                segment.normalizedUnits.map(\.value)
            )
        }
    }

    func testSourceToNormalizedMappingHandlesZeroOneAndManyUnits()
        async throws
    {
        let content = "Ａ，㍿ e\u{301}"
        let document = try await build(content)
        let index = document.index

        XCTAssertEqual(
            index.normalizedUnitRange(
                forSourceAnchor: CharacterAnchor(offset: 0)
            ).count,
            1
        )
        XCTAssertEqual(
            index.normalizedUnitRange(
                forSourceAnchor: CharacterAnchor(offset: 1)
            ).count,
            0
        )
        let expanded = index.normalizedUnitRange(
            forSourceAnchor: CharacterAnchor(offset: 2)
        )
        XCTAssertEqual(expanded.count, 4)
        XCTAssertEqual(
            index.sourceRange(forNormalizedUnitRange: expanded),
            CharacterRange(start: 2, end: 3)
        )
    }

    func testReadableSourceMappingsRoundTripWithoutLeavingCharacterBounds()
        async throws
    {
        let content = "中文 FullWidthＡＢＣ 123 e\u{301} ㍿。"
        let document = try await build(content)

        for offset in 0..<content.count {
            let unitRange = document.index.normalizedUnitRange(
                forSourceAnchor: CharacterAnchor(offset: offset)
            )
            guard unitRange.count > 0 else {
                continue
            }
            let sourceRange = try XCTUnwrap(
                document.index.sourceRange(
                    forNormalizedUnitRange: unitRange
                )
            )
            XCTAssertTrue(sourceRange.range.contains(offset))
        }
    }

    func testAllRequestedAnchorsAreClampedAndLocateSafely() async throws {
        let document = try await build("第一句。第二句。")

        for offset in [-100, 0, 2, 10_000] {
            let anchor = CharacterAnchor(offset: offset)
            let clamped = document.clampedAnchor(anchor)
            XCTAssertGreaterThanOrEqual(clamped.offset, 0)
            XCTAssertLessThanOrEqual(
                clamped.offset,
                document.sourceCharacterCount
            )
            XCTAssertNotNil(
                document.index.segmentOrdinal(atOrFollowing: clamped)
            )
        }
    }

    func testCandidateWindowUsesTwoPreviousAndSixFollowingSegments()
        async throws
    {
        let content = (0..<12).map { "第\($0)句内容。" }.joined(separator: "\n")
        let document = try await build(content)
        let anchor = document.segments[5].startAnchor
        let window = IndexedSpeechCandidateProvider().candidateWindow(
            in: document,
            around: anchor
        )

        XCTAssertEqual(window.centerSegmentOrdinal, 5)
        XCTAssertEqual(window.segments.map(\.ordinal), Array(3...11))

        let first = IndexedSpeechCandidateProvider().candidateWindow(
            in: document,
            around: CharacterAnchor(offset: 0)
        )
        let last = IndexedSpeechCandidateProvider().candidateWindow(
            in: document,
            around: CharacterAnchor(offset: content.count)
        )
        XCTAssertEqual(first.segments.map(\.ordinal), Array(0...6))
        XCTAssertEqual(last.segments.map(\.ordinal), Array(9...11))
    }

    func testNGramPostingsKeepDuplicatesAndStableDocumentOrder()
        async throws
    {
        let content = String(repeating: "甲乙丙丁。\n", count: 12)
        let document = try await build(content)
        let gram = SpeechNGram(first: "甲", second: "乙")

        XCTAssertEqual(
            document.index.nGramPostings[gram],
            Array(0..<12)
        )
        XCTAssertEqual(
            document.segments.flatMap { segment in
                segment.normalizedUnits.map { unit in
                    document.index.segmentOrdinal(
                        forNormalizedUnit: unit.ordinal
                    )
                }
            },
            document.segments.flatMap { segment in
                Array(
                    repeating: Optional(segment.ordinal),
                    count: segment.normalizedUnits.count
                )
            }
        )
        XCTAssertEqual(
            document.index.relocationSegmentOrdinals(for: [gram]),
            Array(0..<8)
        )
    }

    func testIdenticalInputsBuildExactlyIdenticalDocuments() async throws {
        let content = "确定性🙂 Mixed 123。\n重复。重复。"
        let first = try await builder.buildDocument(
            from: content,
            contentRevision: nil
        ).document
        let second = try await builder.buildDocument(
            from: content,
            contentRevision: nil
        ).document

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.contentRevision, second.contentRevision)
    }

    func testFrozenTranscriptFixtureOnlyGeneratesExpectedCandidates()
        async throws
    {
        let script = "今天介绍产品。\nTakeFlow帮助你轻松口播。\n最后感谢观看。"
        let document = try await build(script)
        let transcript = try SpeechTextNormalizer().normalize(
            "TakeFlow帮助你轻松口播",
            sourceStart: CharacterAnchor(offset: 0),
            unitStart: 0
        )
        let grams = SpeechNGram.bigrams(for: transcript.normalizedUnits)
        let candidates = IndexedSpeechCandidateProvider()
            .relocationCandidates(in: document, for: grams)

        XCTAssertEqual(candidates.map(\.ordinal), [1])
        // 4B intentionally stops at candidate generation. No score or anchor
        // advancement is asserted here; those are 4C responsibilities.
    }

    func testRecognitionConfigurationCannotDisableOnDeviceInvariant() {
        let configuration = SpeechRecognitionConfiguration()

        XCTAssertEqual(configuration.localeIdentifier, "zh-CN")
        XCTAssertTrue(configuration.requiresOnDeviceRecognition)
    }

    func testFrameworkNeutralProtocolBoundariesAcceptTestFake() async throws {
        let fake = SpeechProtocolBoundaryFake()
        let capability = await fake.capability(for: "zh-CN")
        let access = await fake.access()
        let authorization = await fake.authorizationState()
        let frames = await fake.frames()
        var frameCount = 0
        for try await _ in frames {
            frameCount += 1
        }

        XCTAssertEqual(
            capability,
            OnDeviceSpeechCapability(
                localeIdentifier: "zh-CN",
                isSupported: true,
                isAvailable: true
            )
        )
        XCTAssertEqual(access, .allowed)
        XCTAssertEqual(authorization, .authorized)
        XCTAssertEqual(frameCount, 0)
    }

    private func build(_ content: String) async throws -> SpeechDocument {
        try await builder.buildDocument(
            from: content,
            contentRevision: 42
        ).document
    }
}

private actor SpeechProtocolBoundaryFake:
    SpeechRecognitionAuthorizing,
    OnDeviceSpeechRecognizing,
    SpeechAudioSource,
    VoiceTrackingAccessChecking,
    VoiceTrackingUsageObserving
{
    private let audioIdentity = SpeechAudioSourceIdentity(
        sourceID: UUID(),
        captureSessionID: nil,
        generation: 1
    )

    func authorizationState() -> SpeechAuthorizationState {
        .authorized
    }

    func requestAuthorization() -> SpeechAuthorizationState {
        .authorized
    }

    func capability(
        for localeIdentifier: String
    ) -> OnDeviceSpeechCapability {
        OnDeviceSpeechCapability(
            localeIdentifier: localeIdentifier,
            isSupported: true,
            isAvailable: true
        )
    }

    func results(
        configuration: SpeechRecognitionConfiguration,
        audio: AsyncThrowingStream<TransientSpeechAudioFrame, any Error>
    ) -> AsyncThrowingStream<TransientSpeechRecognitionResult, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func cancel(generation: UInt64) {}

    func identity() -> SpeechAudioSourceIdentity {
        audioIdentity
    }

    func frames() -> AsyncThrowingStream<
        TransientSpeechAudioFrame,
        any Error
    > {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func stop() {}

    func access() -> VoiceTrackingAccess {
        .allowed
    }

    func observe(_ event: VoiceTrackingUsageEvent) {}
}

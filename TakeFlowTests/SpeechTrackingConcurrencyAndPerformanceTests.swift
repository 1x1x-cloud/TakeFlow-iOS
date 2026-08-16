import XCTest
@testable import TakeFlow

final class SpeechTrackingConcurrencyAndPerformanceTests: XCTestCase {
    func testCancelledBuildDoesNotPublishPartialIndex() async {
        let content = String(repeating: "超长稿件 English 123。\n", count: 25_000)
        let task = Task {
            try await SpeechDocumentBuilder().buildDocument(
                from: content,
                contentRevision: 1
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消的构建不得发布完整或半成品索引")
        } catch is CancellationError {
            XCTAssertTrue(true)
        } catch {
            XCTFail("取消应保持 CancellationError，实际为 \(type(of: error))")
        }
    }

    func testConcurrentDocumentsDoNotShareIndexState() async throws {
        async let first = SpeechDocumentBuilder().buildDocument(
            from: String(repeating: "甲乙丙丁。\n", count: 1_000),
            contentRevision: 11
        )
        async let second = SpeechDocumentBuilder().buildDocument(
            from: String(repeating: "ABCD 9876!\n", count: 1_000),
            contentRevision: 22
        )
        let (left, right) = try await (first, second)

        XCTAssertEqual(left.document.contentRevision, 11)
        XCTAssertEqual(right.document.contentRevision, 22)
        XCTAssertNil(
            left.document.index.nGramPostings[
                SpeechNGram(first: "abcd", second: "9876")
            ]
        )
        XCTAssertNil(
            right.document.index.nGramPostings[
                SpeechNGram(first: "甲", second: "乙")
            ]
        )
    }

    func testBuilderDoesNotPersistContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "TakeFlow-SpeechTracking-Privacy-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await SpeechDocumentBuilder().buildDocument(
            from: "private-sentinel-稿件正文",
            contentRevision: 9
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
    }

    func testExplicitCapacityRejectsOversizedDocument() async {
        let policy = SpeechIndexPolicy(maximumSourceCharacters: 10)

        do {
            _ = try await SpeechDocumentBuilder(policy: policy)
                .buildDocument(
                    from: String(repeating: "稿", count: 11),
                    contentRevision: 1
                )
            XCTFail("超过明确容量上限的文档必须失败")
        } catch let error as SpeechTrackingError {
            XCTAssertEqual(error, .documentTooLarge(limit: 10))
        } catch {
            XCTFail("应返回类型化容量错误")
        }
    }

    func testTenThousandAndHundredThousandBuildThresholdsThreeRounds()
        async throws
    {
        let cases = [
            (label: "10k", count: 10_000, limit: 500.0, memory: 8_000_000),
            (label: "100k", count: 100_000, limit: 2_000.0, memory: 32_000_000)
        ]
        for testCase in cases {
            let content = makeContent(characterCount: testCase.count)
            for round in 1...3 {
                let result = try await SpeechDocumentBuilder().buildDocument(
                    from: content,
                    contentRevision: UInt64(round)
                )
                let metrics = result.metrics
                record(metrics, label: testCase.label, round: round)
                XCTAssertEqual(metrics.characterCount, testCase.count)
                XCTAssertLessThanOrEqual(
                    metrics.totalMilliseconds,
                    testCase.limit,
                    "\(testCase.label) 第\(round)轮超出冻结构建阈值"
                )
                XCTAssertLessThanOrEqual(
                    metrics.estimatedIndexBytes,
                    testCase.memory,
                    "\(testCase.label) 第\(round)轮索引估算超过冻结内存上限"
                )
                XCTAssertGreaterThan(metrics.segmentCount, 0)
                XCTAssertGreaterThan(metrics.unitCount, 0)
            }
        }
    }

    private func makeContent(characterCount: Int) -> String {
        let paragraph = "中文 English 123，设备端语音跟随。\n"
        var content = String(
            repeating: paragraph,
            count: characterCount / paragraph.count + 1
        )
        content = String(content.prefix(characterCount))
        XCTAssertEqual(content.count, characterCount)
        return content
    }

    private func record(
        _ metrics: SpeechDocumentBuildMetrics,
        label: String,
        round: Int
    ) {
        let observation = "\(label) round=\(round) chars=\(metrics.characterCount) segments=\(metrics.segmentCount) units=\(metrics.unitCount) ngrams=\(metrics.nGramKeyCount) split_ms=\(formatted(metrics.segmentationMilliseconds)) normalize_ms=\(formatted(metrics.normalizationMilliseconds)) index_ms=\(formatted(metrics.indexingMilliseconds)) total_ms=\(formatted(metrics.totalMilliseconds)) estimated_index_bytes=\(metrics.estimatedIndexBytes)"
        print("TAKEFLOW_SPEECH_4B_PERFORMANCE \(observation)")
        let attachment = XCTAttachment(string: observation)
        attachment.name = "\(label)-round-\(round)-speech-4b-performance"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

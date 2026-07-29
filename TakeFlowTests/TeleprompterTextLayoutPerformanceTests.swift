import UIKit
import XCTest
@testable import TakeFlow

@MainActor
final class TeleprompterTextLayoutPerformanceTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)

    private func prewarmUIKitText() {
        // Exclude one-time UIKit class initialization from product entry
        // latency. The App has already initialized UIKit before navigation.
        let cell = TeleprompterChunkCell(frame: viewport)
        cell.apply(
            attributedText: NSAttributedString(string: "预热"),
            chunkIndex: 0,
            horizontalMargin: 24,
            accessibilityValue: "预热"
        )
        cell.layoutIfNeeded()
    }

    func testTenThousandCharacterFirstScreenMeetsThreshold() async throws {
        prewarmUIKitText()
        let content = makeContent(characterCount: 10_000)
        let result = try await measureEntry(content: content)
        recordEntry(result, label: "10k")

        XCTAssertTrue(result.hasVisibleChunk)
        XCTAssertLessThan(
            result.totalMilliseconds,
            500,
            "1万字符进入首屏必须低于0.5秒，实测 \(result)"
        )
    }

    func testFittedChunkHeightContainsRenderedText() {
        let cell = TeleprompterChunkCell(frame: viewport)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 18
        let attributed = NSAttributedString(
            string: makeContent(characterCount: 2_200),
            attributes: [
                .font: UIFont.systemFont(ofSize: 48),
                .paragraphStyle: paragraph
            ]
        )
        cell.apply(
            attributedText: attributed,
            chunkIndex: 0,
            horizontalMargin: 24,
            accessibilityValue: attributed.string
        )
        let estimated = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        estimated.size = CGSize(width: viewport.width, height: 120)
        let fitted = cell.preferredLayoutAttributesFitting(estimated)
        cell.frame = CGRect(
            origin: .zero,
            size: fitted.size
        )
        cell.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(
            fitted.size.height + 0.5,
            ceil(cell.textView.contentSize.height),
            "可见块拟合高度不得裁切块内正文"
        )
    }

    func testOneHundredThousandCharacterFirstScreenMeetsThreshold()
        async throws
    {
        prewarmUIKitText()
        let content = makeContent(characterCount: 100_000)
        let result = try await measureEntry(content: content)
        recordEntry(result, label: "100k")

        XCTAssertTrue(result.hasVisibleChunk)
        XCTAssertLessThan(
            result.totalMilliseconds,
            2_000,
            "10万字符进入首屏必须低于2秒，实测 \(result)"
        )
    }

    func testPreferenceRelayoutStaysBelowOneSecond() async {
        let content = makeContent(characterCount: 100_000)
        let document = await buildDocument(content)
        let initial = makeRenderer(document: document)
        initial.collectionView.frame = viewport
        initial.coordinator.applyDocument(
            to: initial.collectionView,
            restoring: ScriptReadingAnchor(characterOffset: 50_000)
        )
        initial.collectionView.layoutIfNeeded()

        let changedPreferences = TeleprompterPreferences(
            fontSize: 72,
            lineSpacing: 30,
            horizontalMargin: 64,
            textAreaWidthFraction: 0.65
        )
        let updatedParent = makeRepresentable(
            document: document,
            preferences: changedPreferences,
            anchor: ScriptReadingAnchor(characterOffset: 50_000),
            layoutRevision: 2
        )
        initial.coordinator.update(parent: updatedParent)

        let start = ContinuousClock.now
        initial.coordinator.applyDocument(
            to: initial.collectionView,
            restoring: ScriptReadingAnchor(characterOffset: 50_000)
        )
        initial.collectionView.layoutIfNeeded()
        let elapsed = milliseconds(since: start)

        XCTAssertLessThan(
            elapsed,
            1_000,
            "字号、行距、边距和宽度重排不得冻结主线程超过1秒"
        )
    }

    func testDistantAnchorJumpsDoNotLayOutWholeDocument() async {
        let content = makeContent(characterCount: 100_000)
        let document = await buildDocument(content)
        let renderer = makeRenderer(document: document)
        renderer.collectionView.frame = viewport

        for offset in [25_000, 50_000, 75_000, 99_500] {
            let parent = makeRepresentable(
                document: document,
                anchor: ScriptReadingAnchor(characterOffset: offset),
                layoutRevision: offset
            )
            renderer.coordinator.update(parent: parent)
            let start = ContinuousClock.now
            renderer.coordinator.applyDocument(
                to: renderer.collectionView,
                restoring: ScriptReadingAnchor(characterOffset: offset)
            )
            renderer.collectionView.layoutIfNeeded()
            let elapsed = milliseconds(since: start)
            let expectedChunk = document.location(
                forGlobalCharacterOffset: offset
            ).chunkIndex
            let visibleChunks = Set(
                renderer.collectionView.indexPathsForVisibleItems.map(\.item)
            )

            XCTAssertTrue(
                visibleChunks.contains(expectedChunk),
                "全局位置 \(offset) 应直接定位到块 \(expectedChunk)"
            )
            XCTAssertLessThan(
                elapsed,
                1_000,
                "远端跳转不得从头同步布局全文"
            )
        }
    }

    func testRunningUpdatesDoNotRepeatWholeDocumentLayout() async {
        let content = makeContent(characterCount: 100_000)
        let document = await buildDocument(content)
        let renderer = makeRenderer(document: document)
        renderer.collectionView.frame = viewport
        renderer.coordinator.applyDocument(
            to: renderer.collectionView,
            restoring: ScriptReadingAnchor(characterOffset: 0)
        )
        renderer.collectionView.layoutIfNeeded()

        let start = ContinuousClock.now
        for step in 0..<1_200 {
            renderer.coordinator.applyProgrammaticOffset(
                Double(step),
                to: renderer.collectionView
            )
        }
        let elapsed = milliseconds(since: start)

        XCTAssertLessThan(
            elapsed,
            1_000,
            "运行更新不得周期性触发全文赋值或全文布局"
        )
    }

    func testVisibleChunkPreloadsNextAndCacheRemainsBounded() async throws {
        let document = await buildDocument(
            makeContent(characterCount: 100_000)
        )
        let renderer = makeRenderer(document: document)
        renderer.collectionView.frame = viewport
        renderer.coordinator.applyDocument(
            to: renderer.collectionView,
            restoring: ScriptReadingAnchor(characterOffset: 0)
        )
        renderer.collectionView.layoutIfNeeded()
        let firstIndexPath = IndexPath(item: 0, section: 0)
        let firstCell = try XCTUnwrap(
            renderer.collectionView.cellForItem(at: firstIndexPath)
        )
        renderer.coordinator.collectionView(
            renderer.collectionView,
            willDisplay: firstCell,
            forItemAt: firstIndexPath
        )

        XCTAssertTrue(renderer.coordinator.cachedChunkIndices.contains(0))
        XCTAssertTrue(renderer.coordinator.cachedChunkIndices.contains(1))
        XCTAssertTrue(renderer.coordinator.cachedChunkIndices.contains(2))

        for index in document.chunks.indices {
            renderer.coordinator.collectionView(
                renderer.collectionView,
                prefetchItemsAt: [IndexPath(item: index, section: 0)]
            )
        }
        XCTAssertLessThanOrEqual(
            renderer.coordinator.cachedChunkIndices.count,
            TeleprompterTextView.Coordinator.textCacheCapacity
        )

        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        let visible = Set(
            renderer.collectionView.indexPathsForVisibleItems.map(\.item)
        )
        XCTAssertTrue(
            renderer.coordinator.cachedChunkIndices.isSubset(of: visible)
        )
    }

    func testOptimizedPipelineStageTimings() async throws {
        let content = makeContent(characterCount: 100_000)
        var timings: [(String, Double)] = []

        let container = try ScriptModelContainer.make(
            isStoredInMemoryOnly: true
        )
        let repository = SwiftDataScriptRepository(
            modelContainer: container
        )
        let script = Script(
            title: "合成性能稿件",
            content: content,
            normalizedContent: content
        )
        try await repository.save(script)
        let readStart = ContinuousClock.now
        let loaded = try await repository.script(id: script.id)
        timings.append(("01_swiftdata_read", milliseconds(since: readStart)))
        let loadedContent = try XCTUnwrap(loaded?.content)

        let indexStart = ContinuousClock.now
        let document = await buildDocument(loadedContent)
        timings.append(
            ("02_chunk_index_background", milliseconds(since: indexStart))
        )

        let firstChunk = document.chunks[0]
        let constructionStart = ContinuousClock.now
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 14
        let attributed = NSAttributedString(
            string: firstChunk.text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 44),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
        )
        timings.append(
            ("03_visible_chunk_attributed", milliseconds(since: constructionStart))
        )

        let cell = TeleprompterChunkCell(frame: viewport)
        let assignmentStart = ContinuousClock.now
        cell.apply(
            attributedText: attributed,
            chunkIndex: 0,
            horizontalMargin: 24,
            accessibilityValue: firstChunk.text
        )
        timings.append(
            ("04_visible_chunk_assignment", milliseconds(since: assignmentStart))
        )

        let layoutStart = ContinuousClock.now
        cell.layoutIfNeeded()
        timings.append(("05_visible_chunk_layout", milliseconds(since: layoutStart)))

        let visibleStart = ContinuousClock.now
        _ = cell.localCharacterOffset(closestTo: CGPoint(x: 24, y: 24))
        timings.append(
            ("06_visible_content_lookup", milliseconds(since: visibleStart))
        )

        let anchorStart = ContinuousClock.now
        _ = cell.caretRect(
            forLocalCharacterOffset: min(500, firstChunk.characterCount)
        )
        timings.append(
            ("07_anchor_to_chunk_layout", milliseconds(since: anchorStart))
        )

        let renderer = makeRenderer(document: document)
        renderer.collectionView.frame = viewport
        let rendererStart = ContinuousClock.now
        renderer.coordinator.applyDocument(
            to: renderer.collectionView,
            restoring: ScriptReadingAnchor(characterOffset: 0)
        )
        renderer.collectionView.layoutIfNeeded()
        timings.append(
            ("08_virtual_height_and_first_screen", milliseconds(since: rendererStart))
        )

        let updateStart = ContinuousClock.now
        renderer.coordinator.applyProgrammaticOffset(
            100,
            to: renderer.collectionView
        )
        timings.append(
            ("09_swiftui_bridge_equivalent_update", milliseconds(since: updateStart))
        )

        let repeatStart = ContinuousClock.now
        for offset in stride(from: 0.0, through: 600.0, by: 1.0) {
            renderer.coordinator.applyProgrammaticOffset(
                offset,
                to: renderer.collectionView
            )
        }
        timings.append(
            ("10_repeated_visible_only_updates", milliseconds(since: repeatStart))
        )

        let observation = timings
            .map { "\(String(format: "%02.3f", $0.1)) ms \($0.0)" }
            .joined(separator: "\n")
        print("TAKEFLOW_CHUNKED_PIPELINE_BEGIN")
        print(observation)
        print("TAKEFLOW_CHUNKED_PIPELINE_END")
        let attachment = XCTAttachment(string: observation)
        attachment.name = "100k-chunked-stage-timings"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertLessThan(
            timings.first { $0.0 == "08_virtual_height_and_first_screen" }?.1
                ?? .infinity,
            2_000
        )
    }

    private func measureEntry(
        content: String
    ) async throws -> EntryMeasurement {
        let container = try ScriptModelContainer.make(
            isStoredInMemoryOnly: true
        )
        let repository = SwiftDataScriptRepository(
            modelContainer: container
        )
        let script = Script(
            title: "首屏性能稿件",
            content: content,
            normalizedContent: content
        )
        try await repository.save(script)

        let totalStart = ContinuousClock.now
        let readStart = ContinuousClock.now
        let loaded = try await repository.script(id: script.id)
        let readMilliseconds = milliseconds(since: readStart)
        let loadedContent = try XCTUnwrap(loaded?.content)

        let indexStart = ContinuousClock.now
        let document = await buildDocument(loadedContent)
        let indexMilliseconds = milliseconds(since: indexStart)

        let renderStart = ContinuousClock.now
        let renderer = makeRenderer(document: document)
        renderer.collectionView.frame = viewport
        renderer.coordinator.applyDocument(
            to: renderer.collectionView,
            restoring: ScriptReadingAnchor(characterOffset: 0)
        )
        renderer.collectionView.layoutIfNeeded()
        let renderMilliseconds = milliseconds(since: renderStart)
        return EntryMeasurement(
            readMilliseconds: readMilliseconds,
            indexMilliseconds: indexMilliseconds,
            renderMilliseconds: renderMilliseconds,
            totalMilliseconds: milliseconds(since: totalStart),
            hasVisibleChunk:
                !renderer.collectionView.indexPathsForVisibleItems.isEmpty
        )
    }

    private func buildDocument(
        _ content: String
    ) async -> TeleprompterDocument {
        await Task.detached(priority: .userInitiated) {
            TeleprompterDocument(content: content)
        }.value
    }

    private func makeRenderer(
        document: TeleprompterDocument
    ) -> (
        coordinator: TeleprompterTextView.Coordinator,
        collectionView: UICollectionView
    ) {
        let parent = makeRepresentable(document: document)
        let coordinator = parent.makeCoordinator()
        let collectionView = coordinator.makeCollectionView()
        return (coordinator, collectionView)
    }

    private func makeRepresentable(
        document: TeleprompterDocument,
        preferences: TeleprompterPreferences = TeleprompterPreferences(),
        anchor: ScriptReadingAnchor =
            ScriptReadingAnchor(characterOffset: 0),
        layoutRevision: Int = 1
    ) -> TeleprompterTextView {
        TeleprompterTextView(
            document: document,
            preferences: preferences,
            targetOffset: 0,
            anchor: anchor,
            layoutRevision: layoutRevision,
            foregroundColor: .white,
            onTapped: {},
            onDragStarted: {},
            onDragChanged: { _, _ in },
            onDragEnded: { _, _ in },
            onVisibleAnchorChanged: { _ in },
            onLayoutResolved: { _, _, _ in }
        )
    }

    private func makeContent(characterCount: Int) -> String {
        let paragraph = "中文 English 123 🙂 提词性能段落。\n"
        var content = String(
            repeating: paragraph,
            count: characterCount / paragraph.count + 1
        )
        content = String(content.prefix(characterCount))
        XCTAssertEqual(content.count, characterCount)
        return content
    }

    private func recordEntry(
        _ measurement: EntryMeasurement,
        label: String
    ) {
        let observation = "\(label) \(measurement)"
        print("TAKEFLOW_ENTRY_PERFORMANCE \(observation)")
        let attachment = XCTAttachment(string: observation)
        attachment.name = "\(label)-entry-performance"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func milliseconds(
        since start: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
    }
}

private struct EntryMeasurement: CustomStringConvertible {
    let readMilliseconds: Double
    let indexMilliseconds: Double
    let renderMilliseconds: Double
    let totalMilliseconds: Double
    let hasVisibleChunk: Bool

    var description: String {
        String(
            format:
                "read=%.3fms index=%.3fms render=%.3fms total=%.3fms visible=%@",
            readMilliseconds,
            indexMilliseconds,
            renderMilliseconds,
            totalMilliseconds,
            hasVisibleChunk ? "yes" : "no"
        )
    }
}

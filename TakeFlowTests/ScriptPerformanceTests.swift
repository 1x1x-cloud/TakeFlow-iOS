import Foundation
import XCTest
@testable import TakeFlow

final class ScriptPerformanceTests: XCTestCase {
    func testOneHundredThousandCharacterScriptRemainsResponsive() async throws {
        let container = try ScriptModelContainer.make(
            isStoredInMemoryOnly: true
        )
        let repository = SwiftDataScriptRepository(
            modelContainer: container
        )
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore()
        )
        var script = try await service.createBlankScript()
        script.title = "十万字符性能检查"
        script.content = String(repeating: "一", count: 100_000)

        let start = ContinuousClock.now
        let saved = try await service.update(script)
        let matches = try await service.scripts(matching: "一一一")
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(
            ScriptMetrics.characterCount(in: saved.content),
            100_000
        )
        XCTAssertEqual(matches.map(\.id), [script.id])
        XCTAssertLessThan(
            elapsed,
            .seconds(5),
            "模拟器基线要求保存、读取和正文搜索合计小于 5 秒"
        )
    }
}

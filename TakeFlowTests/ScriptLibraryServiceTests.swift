import Foundation
import XCTest
@testable import TakeFlow

final class ScriptLibraryServiceTests: XCTestCase {
    func testCreateUpdateUnicodeMetricsAndReadPosition() async throws {
        let repository = TestScriptRepository()
        let now = Date(timeIntervalSince1970: 1_000)
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore(),
            now: { now }
        )
        var script = try await service.createBlankScript()

        script.title = "中英 Emoji 123"
        script.content = "你好 Swift 6！🙂\n第二行。"
        script.speechRateCharactersPerMinute = 120
        script.lastReadPosition = 10_000
        let updated = try await service.update(script)

        XCTAssertEqual(updated.normalizedContent, "你好 swift 6!🙂\n第二行。")
        XCTAssertEqual(
            ScriptMetrics.characterCount(in: updated.content),
            14
        )
        XCTAssertEqual(updated.estimatedDuration, 7, accuracy: 0.001)
        XCTAssertEqual(updated.lastReadPosition, updated.content.count)
        XCTAssertEqual(updated.updatedAt, now)
    }

    func testDuplicateCreatesIndependentCopy() async throws {
        let repository = TestScriptRepository()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore()
        )
        var original = try await service.createBlankScript()
        original.title = "产品介绍"
        original.content = "一遍完成口播。"
        original = try await service.update(original)

        let duplicate = try await service.duplicate(id: original.id)

        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.title, "产品介绍 副本")
        XCTAssertEqual(duplicate.content, original.content)
        XCTAssertEqual(duplicate.lastReadPosition, 0)
    }

    func testSearchMatchesTitleAndBodyAndSortsByUpdateTime() async throws {
        let repository = TestScriptRepository()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore()
        )
        let older = Script(
            title: "Launch Plan",
            content: "正文",
            normalizedContent: ScriptMetrics.normalizedForSearch("正文"),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let newer = Script(
            title: "其他",
            content: "包含 LAUNCH 关键字",
            normalizedContent: ScriptMetrics.normalizedForSearch(
                "包含 LAUNCH 关键字"
            ),
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 40)
        )
        try await repository.save(older)
        try await repository.save(newer)

        let titleAndBodyMatches = try await service.scripts(
            matching: "launch"
        )
        let allScripts = try await service.scripts(matching: "")

        XCTAssertEqual(titleAndBodyMatches.map(\.id), [newer.id, older.id])
        XCTAssertEqual(allScripts.map(\.id), [newer.id, older.id])
    }

    func testDeleteCanBeUndoneBeforeWindowExpires() async throws {
        let repository = TestScriptRepository()
        let now = Date(timeIntervalSince1970: 1_000)
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore(),
            undoWindow: 5,
            now: { now }
        )
        let script = try await service.createBlankScript()

        let deletion = try await service.delete(id: script.id)
        let afterDelete = try await service.scripts(matching: "")
        XCTAssertTrue(afterDelete.isEmpty)

        try await service.undo(deletion)
        let restored = try await service.script(id: script.id)
        XCTAssertEqual(restored.id, script.id)
    }

    func testExpiredUndoPermanentlyDeletesScript() async throws {
        let repository = TestScriptRepository()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore(),
            undoWindow: -1
        )
        let script = try await service.createBlankScript()
        let deletion = try await service.delete(id: script.id)

        do {
            try await service.undo(deletion)
            XCTFail("过期撤销应失败")
        } catch {
            XCTAssertEqual(error as? AppError, .undoExpired)
        }

        let containsScript = await repository.containsActiveScript(
            id: script.id
        )
        XCTAssertFalse(containsScript)
    }

    func testFinalizePermanentlyDeletesSoftDeletedScript() async throws {
        let repository = TestScriptRepository()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore()
        )
        let script = try await service.createBlankScript()
        let deletion = try await service.delete(id: script.id)

        try await service.finalize(deletion)

        let containsScript = await repository.containsActiveScript(
            id: script.id
        )
        let permanentDeleteCount = await repository.permanentDeleteCallCount
        XCTAssertFalse(containsScript)
        XCTAssertEqual(permanentDeleteCount, 1)
    }

    func testMissingScriptReturnsTypedError() async throws {
        let repository = TestScriptRepository()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore()
        )

        do {
            _ = try await service.script(id: UUID())
            XCTFail("不存在的稿件应返回领域错误")
        } catch {
            XCTAssertEqual(error as? AppError, .scriptNotFound)
        }
    }

    func testPersistenceFailureBecomesUserSafeError() async throws {
        let repository = TestScriptRepository()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore()
        )
        await repository.setShouldFail(true)

        do {
            _ = try await service.createBlankScript()
            XCTFail("持久化失败应向上传递")
        } catch {
            XCTAssertEqual(error as? AppError, .persistenceUnavailable)
            XCTAssertEqual(
                (error as? AppError)?.errorDescription,
                "暂时无法保存或读取内容。"
            )
        }
    }
}

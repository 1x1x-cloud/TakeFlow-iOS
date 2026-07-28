import Foundation
import XCTest
@testable import TakeFlow

@MainActor
final class ScriptRecoveryDraftTests: XCTestCase {
    func testPendingEditCreatesRecoveryDraftBeforeFormalSave() async throws {
        let repository = TestScriptRepository()
        let recoveryStore = TestScriptRecoveryDraftStore()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: recoveryStore
        )
        let script = try await service.createBlankScript()
        let viewModel = ScriptEditorViewModel(
            scriptID: script.id,
            service: service,
            debounceDuration: .seconds(30)
        )
        await viewModel.load()

        viewModel.setTitle("未完成标题")
        viewModel.setContent("尚未进入正式保存的正文🙂")
        try await waitForDraft(script.id, in: recoveryStore)

        let draft = await recoveryStore.draft(for: script.id)
        let official = try await repository.script(id: script.id)
        XCTAssertEqual(draft?.title, "未完成标题")
        XCTAssertEqual(draft?.content, "尚未进入正式保存的正文🙂")
        XCTAssertEqual(official?.content, "")
    }

    func testFormalSaveClearsRecoveryDraft() async throws {
        let repository = TestScriptRepository()
        let recoveryStore = TestScriptRecoveryDraftStore()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: recoveryStore
        )
        let script = try await service.createBlankScript()
        let viewModel = ScriptEditorViewModel(
            scriptID: script.id,
            service: service,
            debounceDuration: .seconds(30)
        )
        await viewModel.load()

        viewModel.setContent("正式保存后清理")
        try await waitForDraft(script.id, in: recoveryStore)
        await viewModel.flushPendingSave()

        let remainingDraft = await recoveryStore.draft(for: script.id)
        let official = try await repository.script(id: script.id)
        XCTAssertNil(remainingDraft)
        XCTAssertEqual(official?.content, "正式保存后清理")
    }

    func testRecreatedFileStoreDiscoversRecoveryDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = Script(title: "正式版", content: "已保存")
        let draft = makeDraft(
            for: script,
            title: "恢复版",
            content: "进程重启后仍能读取"
        )

        let firstStore = try FileScriptRecoveryDraftStore(
            directoryURL: directory
        )
        try await firstStore.write(draft)
        let recreatedStore = try FileScriptRecoveryDraftStore(
            directoryURL: directory
        )

        let restored = try await recreatedStore.draft(for: script.id)
        XCTAssertEqual(restored?.scriptID, draft.scriptID)
        XCTAssertEqual(restored?.title, draft.title)
        XCTAssertEqual(restored?.content, draft.content)
        XCTAssertEqual(restored?.baseScriptVersion, draft.baseScriptVersion)
        XCTAssertEqual(restored?.sessionID, draft.sessionID)
        XCTAssertEqual(restored?.revision, draft.revision)
        XCTAssertEqual(
            restored?.draftUpdatedAt.timeIntervalSince1970 ?? 0,
            draft.draftUpdatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testRecoveryCandidateDoesNotSilentlyReplaceOfficialContent()
        async throws {
        let repository = TestScriptRepository()
        let recoveryStore = TestScriptRecoveryDraftStore()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: recoveryStore
        )
        var script = try await service.createBlankScript()
        script.content = "正式正文"
        script = try await service.update(script)
        let draft = makeDraft(
            for: script,
            title: "恢复标题",
            content: "未完成恢复正文"
        )
        await recoveryStore.seed(draft)
        let viewModel = ScriptEditorViewModel(
            scriptID: script.id,
            service: service,
            debounceDuration: .seconds(30)
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.content, "正式正文")
        XCTAssertEqual(viewModel.pendingRecoveryDraft, draft)
    }

    func testChoosingRecoveryAppliesDraftContentAndPosition() async throws {
        let repository = TestScriptRepository()
        let recoveryStore = TestScriptRecoveryDraftStore()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: recoveryStore
        )
        let script = try await service.createBlankScript()
        let draft = makeDraft(
            for: script,
            title: "恢复标题",
            content: "恢复后的正文🙂",
            lastReadPosition: 4
        )
        await recoveryStore.seed(draft)
        let viewModel = ScriptEditorViewModel(
            scriptID: script.id,
            service: service,
            debounceDuration: .seconds(30)
        )
        await viewModel.load()

        viewModel.recoverPendingDraft()

        XCTAssertEqual(viewModel.title, "恢复标题")
        XCTAssertEqual(viewModel.content, "恢复后的正文🙂")
        XCTAssertEqual(viewModel.lastReadPosition, 4)
        XCTAssertNil(viewModel.pendingRecoveryDraft)
        XCTAssertEqual(viewModel.saveState, .pending)
    }

    func testKeepingOfficialVersionClearsRecoveryDraft() async throws {
        let repository = TestScriptRepository()
        let recoveryStore = TestScriptRecoveryDraftStore()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: recoveryStore
        )
        let script = try await service.createBlankScript()
        let draft = makeDraft(
            for: script,
            title: "不采用",
            content: "不采用的恢复正文"
        )
        await recoveryStore.seed(draft)
        let viewModel = ScriptEditorViewModel(
            scriptID: script.id,
            service: service
        )
        await viewModel.load()

        await viewModel.keepSavedVersion()

        XCTAssertEqual(viewModel.content, script.content)
        XCTAssertNil(viewModel.pendingRecoveryDraft)
        let remaining = await recoveryStore.draft(for: script.id)
        XCTAssertNil(remaining)
    }

    func testCorruptedDraftPreservesOfficialRecordAndDoesNotCrash()
        async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = TestScriptRepository()
        let recoveryStore = try FileScriptRecoveryDraftStore(
            directoryURL: directory
        )
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: recoveryStore
        )
        var script = try await service.createBlankScript()
        script.content = "必须保留的正式正文"
        script = try await service.update(script)
        let corruptURL = directory.appendingPathComponent(
            "\(script.id.uuidString.lowercased()).json"
        )
        try Data("not-json".utf8).write(to: corruptURL, options: .atomic)
        let viewModel = ScriptEditorViewModel(
            scriptID: script.id,
            service: service
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.content, "必须保留的正式正文")
        XCTAssertNil(viewModel.pendingRecoveryDraft)
        XCTAssertEqual(
            viewModel.errorMessage,
            AppError.recoveryDraftCorrupted.errorDescription
        )
        let official = try await repository.script(id: script.id)
        XCTAssertEqual(official?.content, "必须保留的正式正文")
        let remaining = try await recoveryStore.draft(for: script.id)
        XCTAssertNil(remaining)
    }

    func testOlderDraftCannotOverrideNewerOfficialRecord() async throws {
        let repository = TestScriptRepository()
        let recoveryStore = TestScriptRecoveryDraftStore()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: recoveryStore
        )
        let oldOfficial = try await service.createBlankScript()
        let staleDraft = makeDraft(
            for: oldOfficial,
            title: "旧草稿",
            content: "旧内容"
        )
        await recoveryStore.seed(staleDraft)
        var newerOfficial = oldOfficial
        newerOfficial.content = "更新的正式内容"
        newerOfficial.updatedAt = oldOfficial.updatedAt.addingTimeInterval(30)
        try await repository.save(newerOfficial)

        let candidate = try await service.recoveryDraft(
            newerThan: newerOfficial
        )

        XCTAssertNil(candidate)
        let remaining = await recoveryStore.draft(for: oldOfficial.id)
        XCTAssertNil(remaining)
        let stored = try await repository.script(id: oldOfficial.id)
        XCTAssertEqual(stored?.content, "更新的正式内容")
    }

    func testFutureBaseVersionMismatchPreservesOfficialRecord() async throws {
        let repository = TestScriptRepository()
        let recoveryStore = TestScriptRecoveryDraftStore()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: recoveryStore
        )
        var official = try await service.createBlankScript()
        official.content = "当前正式正文"
        official = try await service.update(official)
        var futureBase = official
        futureBase.updatedAt = official.updatedAt.addingTimeInterval(30)
        let mismatchedDraft = makeDraft(
            for: futureBase,
            title: "不匹配草稿",
            content: "不得覆盖"
        )
        await recoveryStore.seed(mismatchedDraft)
        let viewModel = ScriptEditorViewModel(
            scriptID: official.id,
            service: service
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.content, "当前正式正文")
        XCTAssertNil(viewModel.pendingRecoveryDraft)
        XCTAssertEqual(
            viewModel.errorMessage,
            AppError.recoveryDraftVersionMismatch.errorDescription
        )
        let stored = try await repository.script(id: official.id)
        XCTAssertEqual(stored?.content, "当前正式正文")
    }

    func testOlderWriteCannotReplaceNewerDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileScriptRecoveryDraftStore(
            directoryURL: directory
        )
        let script = Script()
        let sessionID = UUID()
        let older = makeDraft(
            for: script,
            title: "revision 1",
            content: "旧内容",
            sessionID: sessionID,
            revision: 1
        )
        let newer = makeDraft(
            for: script,
            title: "revision 2",
            content: "新内容",
            sessionID: sessionID,
            revision: 2
        )

        try await store.write(newer)
        try await store.write(older)

        let stored = try await store.draft(for: script.id)
        XCTAssertEqual(stored?.revision, 2)
        XCTAssertEqual(stored?.content, "新内容")
    }

    func testDeletingScriptAlsoRemovesRecoveryDraft() async throws {
        let repository = TestScriptRepository()
        let recoveryStore = TestScriptRecoveryDraftStore()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: recoveryStore
        )
        let script = try await service.createBlankScript()
        await recoveryStore.seed(
            makeDraft(
                for: script,
                title: "待删除",
                content: "待删除草稿"
            )
        )

        let deletion = try await service.delete(id: script.id)

        let remaining = await recoveryStore.draft(for: script.id)
        let cleanupCount = await recoveryStore.removeAllCallCount
        XCTAssertNil(remaining)
        XCTAssertEqual(cleanupCount, 1)

        try await service.undo(deletion)
        let newDraft = makeDraft(
            for: deletion.script,
            title: "撤销后",
            content: "撤销后仍可保护"
        )
        try await service.writeRecoveryDraft(newDraft)
        let restoredDraft = await recoveryStore.draft(for: script.id)
        XCTAssertEqual(restoredDraft, newDraft)
    }

    func testDraftCleanupFailureRollsBackSoftDelete() async throws {
        let repository = TestScriptRepository()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: UnavailableScriptRecoveryDraftStore()
        )
        let script = try await service.createBlankScript()

        do {
            _ = try await service.delete(id: script.id)
            XCTFail("恢复草稿清理失败时删除应回滚")
        } catch {
            XCTAssertEqual(error as? AppError, .recoveryDraftUnavailable)
        }

        let remainsActive = await repository.containsActiveScript(
            id: script.id
        )
        XCTAssertTrue(remainsActive)
    }

    func testOneHundredThousandCharacterDraftFilePerformance()
        async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileScriptRecoveryDraftStore(
            directoryURL: directory
        )
        let script = Script()
        let draft = makeDraft(
            for: script,
            title: "十万字符",
            content: String(repeating: "一", count: 100_000)
        )

        let start = ContinuousClock.now
        try await store.write(draft)
        let restored = try await store.draft(for: script.id)
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(restored?.content.count, 100_000)
        XCTAssertLessThan(
            elapsed,
            .seconds(5),
            "模拟器基线要求10万字符恢复草稿写入和读取合计小于5秒"
        )
    }

    private func makeDraft(
        for script: Script,
        title: String,
        content: String,
        lastReadPosition: Int = 0,
        sessionID: UUID = UUID(),
        revision: UInt64 = 1
    ) -> ScriptRecoveryDraft {
        ScriptRecoveryDraft(
            scriptID: script.id,
            title: title,
            content: content,
            lastReadPosition: lastReadPosition,
            speechRateCharactersPerMinute:
                script.speechRateCharactersPerMinute,
            draftUpdatedAt: script.updatedAt.addingTimeInterval(10),
            baseScriptUpdatedAt: script.updatedAt,
            sessionID: sessionID,
            revision: revision
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TakeFlow-RecoveryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func waitForDraft(
        _ scriptID: UUID,
        in store: TestScriptRecoveryDraftStore
    ) async throws {
        for _ in 0..<50 {
            if await store.draft(for: scriptID) != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("恢复草稿未在预期时间内写入")
    }
}

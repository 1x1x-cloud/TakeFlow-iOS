import Foundation
import XCTest
@testable import TakeFlow

@MainActor
final class ScriptEditorViewModelTests: XCTestCase {
    func testAutosaveDebouncesRapidChanges() async throws {
        let repository = TestScriptRepository()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore()
        )
        let original = try await service.createBlankScript()
        await repository.resetCounters()
        let viewModel = ScriptEditorViewModel(
            scriptID: original.id,
            service: service,
            debounceDuration: .milliseconds(40)
        )
        await viewModel.load()

        viewModel.setTitle("第")
        viewModel.setTitle("第一版标题")
        viewModel.setContent("第一")
        viewModel.setContent("第一版正文🙂")

        let callsBeforeDebounce = await repository.saveCallCount
        XCTAssertEqual(callsBeforeDebounce, 0)

        try await Task.sleep(for: .milliseconds(150))

        let callsAfterDebounce = await repository.saveCallCount
        let saved = try await repository.script(id: original.id)
        XCTAssertEqual(callsAfterDebounce, 1)
        XCTAssertEqual(saved?.title, "第一版标题")
        XCTAssertEqual(saved?.content, "第一版正文🙂")
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testFlushPersistsPendingDraftImmediately() async throws {
        let repository = TestScriptRepository()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore()
        )
        let original = try await service.createBlankScript()
        await repository.resetCounters()
        let viewModel = ScriptEditorViewModel(
            scriptID: original.id,
            service: service,
            debounceDuration: .seconds(30)
        )
        await viewModel.load()

        viewModel.setContent("进入后台前立即保存🙂")
        viewModel.setLastReadPosition(6)
        await viewModel.flushPendingSave()

        let saved = try await repository.script(id: original.id)
        let saveCount = await repository.saveCallCount
        XCTAssertEqual(saved?.content, "进入后台前立即保存🙂")
        XCTAssertEqual(saved?.lastReadPosition, 6)
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testSaveFailureRetainsDraftAndShowsError() async throws {
        let repository = TestScriptRepository()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore()
        )
        let original = try await service.createBlankScript()
        let viewModel = ScriptEditorViewModel(
            scriptID: original.id,
            service: service,
            debounceDuration: .seconds(30)
        )
        await viewModel.load()
        await repository.setShouldFail(true)

        viewModel.setContent("这段内容不能静默消失🙂")
        await viewModel.flushPendingSave()

        XCTAssertEqual(viewModel.content, "这段内容不能静默消失🙂")
        XCTAssertEqual(viewModel.saveState, .failed)
        XCTAssertEqual(
            viewModel.errorMessage,
            AppError.persistenceUnavailable.errorDescription
        )
    }
}

import Foundation
import XCTest
@testable import TakeFlow

@MainActor
final class TeleprompterViewModelTests: XCTestCase {
    func testFontSizeChangePreservesReadingAnchor() async {
        let service = TestTeleprompterService(
            script: populatedScript()
        )
        let viewModel = TeleprompterViewModel(
            scriptID: await service.scriptID,
            service: service
        )
        await viewModel.load()
        viewModel.layoutResolved(
            maximumOffset: 5_000,
            restoredOffset: 800,
            characterOffset: 420
        )

        viewModel.updatePreferences {
            $0.fontSize = 80
        }

        XCTAssertEqual(viewModel.anchor.characterOffset, 420)
        XCTAssertEqual(viewModel.preferences.fontSize, 80)
    }

    func testLineSpacingMarginsAndWidthPreserveReadingAnchor() async {
        let service = TestTeleprompterService(
            script: populatedScript()
        )
        let viewModel = TeleprompterViewModel(
            scriptID: await service.scriptID,
            service: service
        )
        await viewModel.load()
        viewModel.layoutResolved(
            maximumOffset: 5_000,
            restoredOffset: 600,
            characterOffset: 333
        )

        viewModel.updatePreferences {
            $0.lineSpacing = 32
            $0.horizontalMargin = 64
            $0.textAreaWidthFraction = 0.6
        }

        XCTAssertEqual(viewModel.anchor.characterOffset, 333)
        XCTAssertEqual(viewModel.preferences.lineSpacing, 32)
        XCTAssertEqual(viewModel.preferences.horizontalMargin, 64)
        XCTAssertEqual(
            viewModel.preferences.textAreaWidthFraction,
            0.6
        )
    }

    func testRotationStyleLayoutResolutionPreservesContentAnchor() async {
        let service = TestTeleprompterService(
            script: populatedScript()
        )
        let viewModel = TeleprompterViewModel(
            scriptID: await service.scriptID,
            service: service
        )
        await viewModel.load()
        viewModel.layoutResolved(
            maximumOffset: 8_000,
            restoredOffset: 1_100,
            characterOffset: 720
        )

        // A size-class/orientation change invokes the same text-layout
        // callback with a newly resolved pixel offset for the saved anchor.
        viewModel.layoutResolved(
            maximumOffset: 4_200,
            restoredOffset: 580,
            characterOffset: 720
        )

        XCTAssertEqual(viewModel.anchor.characterOffset, 720)
        XCTAssertEqual(viewModel.scrollOffset, 580)
    }

    func testLongDocumentStyleAndWidthChangesPreserveCrossChunkAnchor()
        async
    {
        let script = Script(
            title: "长稿",
            content: String(repeating: "跨块锚点段落🙂。\n", count: 10_000)
        )
        let service = TestTeleprompterService(script: script)
        let viewModel = TeleprompterViewModel(
            scriptID: await service.scriptID,
            service: service
        )
        await viewModel.load()
        let anchor = 50_000
        viewModel.layoutResolved(
            maximumOffset: 100_000,
            restoredOffset: 50_000,
            characterOffset: anchor
        )

        viewModel.updatePreferences {
            $0.fontSize = 88
            $0.lineSpacing = 40
            $0.horizontalMargin = 72
            $0.textAreaWidthFraction = 0.55
        }

        XCTAssertEqual(viewModel.anchor.characterOffset, anchor)
        let document = viewModel.document
        let location = document?.location(
            forGlobalCharacterOffset: anchor
        )
        XCTAssertEqual(
            document?.globalCharacterOffset(
                chunkIndex: location?.chunkIndex ?? 0,
                localCharacterOffset: location?.localCharacterOffset ?? 0
            ),
            anchor
        )
    }

    func testExternalContentChangePausesWithUnderstandableError() async {
        let service = TestTeleprompterService(
            script: populatedScript()
        )
        let viewModel = TeleprompterViewModel(
            scriptID: await service.scriptID,
            service: service
        )
        await viewModel.load()
        await service.replaceContent("另一处修改后的正文")

        await viewModel.sceneDidBecomeActive()

        XCTAssertEqual(
            viewModel.state,
            .error(.scriptChangedDuringTeleprompter)
        )
        XCTAssertEqual(
            viewModel.errorMessage,
            AppError.scriptChangedDuringTeleprompter.errorDescription
        )
        XCTAssertNil(
            viewModel.document,
            "正文变化后不得继续复用旧分块索引"
        )
    }

    func testPersistenceFailureIsNotSilent() async {
        let service = TestTeleprompterService(
            script: populatedScript()
        )
        let viewModel = TeleprompterViewModel(
            scriptID: await service.scriptID,
            service: service
        )
        await viewModel.load()
        await service.setSaveFailure(true)
        viewModel.layoutResolved(
            maximumOffset: 5_000,
            restoredOffset: 300,
            characterOffset: 200
        )

        viewModel.sceneDidEnterBackground()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            viewModel.state,
            .error(.persistenceUnavailable)
        )
        XCTAssertEqual(
            viewModel.errorMessage,
            AppError.persistenceUnavailable.errorDescription
        )
    }

    private func populatedScript() -> Script {
        Script(
            title: "提词测试",
            content: String(repeating: "这是可阅读的正文。", count: 200)
        )
    }
}

private actor TestTeleprompterService: TeleprompterScriptProviding {
    private var storedScript: Script
    private var shouldFailSave = false

    init(script: Script) {
        storedScript = script
    }

    var scriptID: UUID {
        storedScript.id
    }

    func teleprompterScript(id: UUID) throws -> Script {
        guard id == storedScript.id else {
            throw AppError.scriptNotFound
        }
        return storedScript
    }

    func saveTeleprompterState(
        scriptID: UUID,
        anchor: ScriptReadingAnchor,
        preferences: TeleprompterPreferences
    ) throws -> Script {
        guard !shouldFailSave else {
            throw AppError.persistenceUnavailable
        }
        guard scriptID == storedScript.id else {
            throw AppError.scriptNotFound
        }
        storedScript.lastReadPosition = anchor.characterOffset
        preferences.applying(to: &storedScript)
        return storedScript
    }

    func replaceContent(_ content: String) {
        storedScript.content = content
        storedScript.updatedAt = .now
    }

    func setSaveFailure(_ value: Bool) {
        shouldFailSave = value
    }
}

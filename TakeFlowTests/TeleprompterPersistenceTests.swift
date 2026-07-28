import Foundation
import SwiftData
import XCTest
@testable import TakeFlow

final class TeleprompterPersistenceTests: XCTestCase {
    func testReadingPositionAndPreferencesPersistAcrossContexts() async throws {
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
        script.content = String(repeating: "稿", count: 1_000)
        script = try await service.update(script)

        let preferences = TeleprompterPreferences(
            fontSize: 72,
            lineSpacing: 24,
            scrollSpeedPointsPerSecond: 90,
            horizontalMargin: 48,
            textAreaWidthFraction: 0.75,
            verticalPosition: 0.15,
            appearance: .light,
            isHorizontallyMirrored: true,
            isVerticallyMirrored: true,
            countdownSeconds: 10
        )
        _ = try await service.saveTeleprompterState(
            scriptID: script.id,
            anchor: ScriptReadingAnchor(characterOffset: 678),
            preferences: preferences
        )

        let recreatedRepository = SwiftDataScriptRepository(
            modelContainer: container
        )
        let restoredValue = try await recreatedRepository.script(
            id: script.id
        )
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(restored.lastReadPosition, 678)
        XCTAssertEqual(
            TeleprompterPreferences(script: restored),
            preferences
        )
    }

    func testTeleprompterDoesNotBypassPendingRecoveryDraft() async throws {
        let repository = TestScriptRepository()
        let recoveryStore = TestScriptRecoveryDraftStore()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: recoveryStore
        )
        var script = try await service.createBlankScript()
        script.content = "已保存正文"
        script = try await service.update(script)
        let draft = ScriptRecoveryDraft(
            scriptID: script.id,
            title: script.title,
            content: "尚未确认的恢复正文",
            lastReadPosition: 0,
            speechRateCharactersPerMinute:
                script.speechRateCharactersPerMinute,
            draftUpdatedAt: script.updatedAt.addingTimeInterval(1),
            baseScriptUpdatedAt: script.updatedAt,
            sessionID: UUID(),
            revision: 1
        )
        await recoveryStore.seed(draft)

        do {
            _ = try await service.teleprompterScript(id: script.id)
            XCTFail("存在新恢复草稿时不得进入提词并覆盖状态")
        } catch {
            XCTAssertEqual(
                error as? AppError,
                .pendingRecoveryDraftRequiresReview
            )
        }
    }

    func testSavingTeleprompterStateDoesNotChangeScriptContent() async throws {
        let repository = TestScriptRepository()
        let service = ScriptLibraryService(
            repository: repository,
            recoveryStore: TestScriptRecoveryDraftStore()
        )
        var script = try await service.createBlankScript()
        script.content = "正文🙂不会被提词状态覆盖"
        script = try await service.update(script)

        let saved = try await service.saveTeleprompterState(
            scriptID: script.id,
            anchor: ScriptReadingAnchor(characterOffset: 4),
            preferences: TeleprompterPreferences()
        )

        XCTAssertEqual(saved.content, script.content)
        XCTAssertEqual(saved.lastReadPosition, 4)
    }

    func testLegacyV1StoreMigratesWithSafeTeleprompterDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TakeFlow-V1-Migration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let storeURL = directory.appendingPathComponent("Scripts.store")
        let id = UUID()

        try createV1Store(at: storeURL, id: id)

        let container = try ScriptModelContainer.make(storeURL: storeURL)
        let repository = SwiftDataScriptRepository(
            modelContainer: container
        )
        let migratedValue = try await repository.script(id: id)
        let migrated = try XCTUnwrap(migratedValue)
        let preferences = TeleprompterPreferences(script: migrated)

        XCTAssertEqual(migrated.content, "旧稿仍可读取🙂")
        XCTAssertEqual(
            preferences.scrollSpeedPointsPerSecond,
            TeleprompterPreferences.defaultScrollSpeed
        )
        XCTAssertEqual(
            preferences.lineSpacing,
            TeleprompterPreferences.defaultLineSpacing
        )
        XCTAssertEqual(preferences.appearance, .dark)
        XCTAssertFalse(preferences.isHorizontallyMirrored)
    }

    private func createV1Store(at url: URL, id: UUID) throws {
        let schema = Schema(ScriptSchemaV1.models)
        let configuration = ModelConfiguration(
            "TakeFlow",
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let script = Script(
            id: id,
            title: "旧版稿件",
            content: "旧稿仍可读取🙂",
            normalizedContent: "旧稿仍可读取🙂",
            preferredFontSize: 50,
            preferredScrollSpeed: 1,
            lastReadPosition: 2
        )
        context.insert(ScriptSchemaV1.ScriptRecord(script: script))
        try context.save()
    }
}

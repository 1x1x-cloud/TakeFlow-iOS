import Foundation
import SwiftData
import XCTest
@testable import TakeFlow

final class SwiftDataScriptRepositoryTests: XCTestCase {
    func testInMemoryRepositoryCreatesUpdatesDeletesAndRestores() async throws {
        let container = try ScriptModelContainer.make(
            isStoredInMemoryOnly: true
        )
        let repository = SwiftDataScriptRepository(modelContainer: container)
        var script = Script(title: "初稿", content: "第一版")

        try await repository.save(script)
        script.title = "修订稿"
        script.content = "第二版🙂"
        script.normalizedContent = "第二版🙂"
        script.estimatedDuration = 12
        script.speechRateCharactersPerMinute = 180
        script.lastReadPosition = 3
        try await repository.save(script)

        let updated = try await repository.script(id: script.id)
        XCTAssertEqual(updated, script)

        try await repository.delete(id: script.id, at: .now)
        let afterDelete = try await repository.script(id: script.id)
        XCTAssertNil(afterDelete)

        try await repository.restore(id: script.id)
        let restored = try await repository.script(id: script.id)
        XCTAssertEqual(restored, script)

        try await repository.permanentlyDelete(id: script.id)
        let afterPermanentDelete = try await repository.script(id: script.id)
        XCTAssertNil(afterPermanentDelete)
    }

    func testNewRepositoryContextReadsPreviouslySavedScript() async throws {
        let container = try ScriptModelContainer.make(
            isStoredInMemoryOnly: true
        )
        let firstRepository = SwiftDataScriptRepository(
            modelContainer: container
        )
        let script = Script(title: "跨上下文", content: "仍然可读")
        try await firstRepository.save(script)

        let recreatedRepository = SwiftDataScriptRepository(
            modelContainer: container
        )
        let restored = try await recreatedRepository.script(id: script.id)

        XCTAssertEqual(restored, script)
    }

    func testDiskContainerSurvivesContainerRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TakeFlow-SwiftData-\(UUID().uuidString)",
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
        let script = Script(
            title: "重启恢复",
            content: "写入磁盘后重新创建容器仍能读取。"
        )

        try await save(script, to: storeURL)
        let restored = try await read(script.id, from: storeURL)

        XCTAssertEqual(restored, script)
    }

    private func save(_ script: Script, to storeURL: URL) async throws {
        let container = try ScriptModelContainer.make(storeURL: storeURL)
        let repository = SwiftDataScriptRepository(modelContainer: container)
        try await repository.save(script)
    }

    private func read(_ id: UUID, from storeURL: URL) async throws -> Script? {
        let container = try ScriptModelContainer.make(storeURL: storeURL)
        let repository = SwiftDataScriptRepository(modelContainer: container)
        return try await repository.script(id: id)
    }
}

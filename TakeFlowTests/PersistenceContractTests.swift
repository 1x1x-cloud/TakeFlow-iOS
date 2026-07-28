import Foundation
import XCTest
@testable import TakeFlow

final class PersistenceContractTests: XCTestCase {
    func testMockRepositorySavesAndReadsScript() async throws {
        let repository: any ScriptRepository = MockScriptRepository()
        let script = Script(title: "第一份稿件", content: "用于验证持久化协议")

        try await repository.save(script)
        let restored = try await repository.script(id: script.id)

        XCTAssertEqual(restored, script)
    }

    func testMockRepositoryDeletesOnlyRequestedScript() async throws {
        let repository: any ScriptRepository = MockScriptRepository()
        let retained = Script(title: "保留")
        let deleted = Script(title: "删除")

        try await repository.save(retained)
        try await repository.save(deleted)
        try await repository.delete(id: deleted.id, at: .now)

        let scripts = try await repository.scripts()
        XCTAssertEqual(scripts, [retained])
    }

    func testMockRepositoryCanRestoreSoftDeletedScript() async throws {
        let repository: any ScriptRepository = MockScriptRepository()
        let script = Script(title: "可撤销删除")

        try await repository.save(script)
        try await repository.delete(id: script.id, at: .now)
        try await repository.restore(id: script.id)

        let restored = try await repository.script(id: script.id)
        XCTAssertEqual(restored, script)
    }
}

private actor MockScriptRepository: ScriptRepository {
    private struct Entry {
        var script: Script
        var deletedAt: Date?
    }

    private var storage: [UUID: Entry] = [:]

    func scripts() -> [Script] {
        storage.values
            .filter { $0.deletedAt == nil }
            .map(\.script)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func script(id: UUID) -> Script? {
        guard let entry = storage[id], entry.deletedAt == nil else {
            return nil
        }
        return entry.script
    }

    func save(_ script: Script) {
        storage[script.id] = Entry(script: script, deletedAt: nil)
    }

    func delete(id: UUID, at deletionDate: Date) {
        storage[id]?.deletedAt = deletionDate
    }

    func restore(id: UUID) {
        storage[id]?.deletedAt = nil
    }

    func permanentlyDelete(id: UUID) {
        storage[id] = nil
    }

    func purgeDeleted(before date: Date) {
        storage = storage.filter { _, entry in
            guard let deletedAt = entry.deletedAt else {
                return true
            }
            return deletedAt > date
        }
    }
}

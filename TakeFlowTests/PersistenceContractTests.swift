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
        try await repository.delete(id: deleted.id)

        let scripts = try await repository.scripts()
        XCTAssertEqual(scripts, [retained])
    }
}

private actor MockScriptRepository: ScriptRepository {
    private var storage: [UUID: Script] = [:]

    func scripts() -> [Script] {
        storage.values.sorted { $0.createdAt < $1.createdAt }
    }

    func script(id: UUID) -> Script? {
        storage[id]
    }

    func save(_ script: Script) {
        storage[script.id] = script
    }

    func delete(id: UUID) {
        storage[id] = nil
    }
}

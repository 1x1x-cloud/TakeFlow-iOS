import Foundation

protocol ScriptRepository: Sendable {
    func scripts() async throws -> [Script]
    func script(id: UUID) async throws -> Script?
    func save(_ script: Script) async throws
    func delete(id: UUID, at deletionDate: Date) async throws
    func restore(id: UUID) async throws
    func permanentlyDelete(id: UUID) async throws
    func purgeDeleted(before date: Date) async throws
}

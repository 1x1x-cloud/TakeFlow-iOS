import Foundation

protocol ScriptRepository: Sendable {
    func scripts() async throws -> [Script]
    func script(id: UUID) async throws -> Script?
    func save(_ script: Script) async throws
    func delete(id: UUID) async throws
}

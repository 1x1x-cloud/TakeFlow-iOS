import Foundation

protocol TeleprompterScriptProviding: Sendable {
    func teleprompterScript(id: UUID) async throws -> Script

    @discardableResult
    func saveTeleprompterState(
        scriptID: UUID,
        anchor: ScriptReadingAnchor,
        preferences: TeleprompterPreferences
    ) async throws -> Script
}

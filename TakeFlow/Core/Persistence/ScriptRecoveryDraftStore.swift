import Foundation

protocol ScriptRecoveryDraftStoring: Sendable {
    func draft(for scriptID: UUID) async throws -> ScriptRecoveryDraft?
    func write(_ draft: ScriptRecoveryDraft) async throws
    func removeDraft(
        for scriptID: UUID,
        committedThrough version: ScriptRecoveryDraftWriteVersion
    ) async throws
    func removeAllDraftData(for scriptID: UUID) async throws
    func removeUnreadableDraft(for scriptID: UUID) async throws
    func allowDraftWrites(for scriptID: UUID) async
}

struct UnavailableScriptRecoveryDraftStore: ScriptRecoveryDraftStoring {
    func draft(for scriptID: UUID) async throws -> ScriptRecoveryDraft? {
        throw AppError.recoveryDraftUnavailable
    }

    func write(_ draft: ScriptRecoveryDraft) async throws {
        throw AppError.recoveryDraftUnavailable
    }

    func removeDraft(
        for scriptID: UUID,
        committedThrough version: ScriptRecoveryDraftWriteVersion
    ) async throws {
        throw AppError.recoveryDraftUnavailable
    }

    func removeAllDraftData(for scriptID: UUID) async throws {
        throw AppError.recoveryDraftUnavailable
    }

    func removeUnreadableDraft(for scriptID: UUID) async throws {
        throw AppError.recoveryDraftUnavailable
    }

    func allowDraftWrites(for scriptID: UUID) async {}
}

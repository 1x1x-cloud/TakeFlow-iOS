import Foundation
@testable import TakeFlow

actor TestScriptRecoveryDraftStore: ScriptRecoveryDraftStoring {
    private var storage: [UUID: ScriptRecoveryDraft] = [:]
    private var committedVersions:
        [UUID: ScriptRecoveryDraftWriteVersion] = [:]
    private var blockedScriptIDs: Set<UUID> = []
    private(set) var removeAllCallCount = 0

    func draft(for scriptID: UUID) -> ScriptRecoveryDraft? {
        storage[scriptID]
    }

    func write(_ draft: ScriptRecoveryDraft) {
        guard !blockedScriptIDs.contains(draft.scriptID) else {
            return
        }
        if let committed = committedVersions[draft.scriptID],
           !draft.writeVersion.isNewer(than: committed) {
            return
        }
        if let existing = storage[draft.scriptID],
           !draft.writeVersion.isNewer(than: existing.writeVersion) {
            return
        }
        storage[draft.scriptID] = draft
    }

    func removeDraft(
        for scriptID: UUID,
        committedThrough version: ScriptRecoveryDraftWriteVersion
    ) {
        committedVersions[scriptID] = version
        storage[scriptID] = nil
    }

    func removeAllDraftData(for scriptID: UUID) {
        removeAllCallCount += 1
        blockedScriptIDs.insert(scriptID)
        storage[scriptID] = nil
    }

    func removeUnreadableDraft(for scriptID: UUID) {
        storage[scriptID] = nil
    }

    func allowDraftWrites(for scriptID: UUID) {
        blockedScriptIDs.remove(scriptID)
    }

    func seed(_ draft: ScriptRecoveryDraft) {
        storage[draft.scriptID] = draft
    }
}

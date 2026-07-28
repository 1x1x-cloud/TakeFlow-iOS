import Foundation

struct ScriptDeletion: Equatable, Sendable {
    let script: Script
    let expiresAt: Date
}

protocol ScriptLibraryServicing: Sendable {
    func scripts(matching query: String) async throws -> [Script]
    func script(id: UUID) async throws -> Script
    func createBlankScript() async throws -> Script
    func update(_ script: Script) async throws -> Script
    func duplicate(id: UUID) async throws -> Script
    func delete(id: UUID) async throws -> ScriptDeletion
    func undo(_ deletion: ScriptDeletion) async throws
    func finalize(_ deletion: ScriptDeletion) async throws
    func recoveryDraft(
        newerThan script: Script
    ) async throws -> ScriptRecoveryDraft?
    func writeRecoveryDraft(_ draft: ScriptRecoveryDraft) async throws
    func clearRecoveryDraft(
        for scriptID: UUID,
        committedThrough version: ScriptRecoveryDraftWriteVersion
    ) async throws
}

protocol TakeFlowServicing:
    ScriptLibraryServicing,
    TeleprompterScriptProviding
{}

actor ScriptLibraryService:
    TakeFlowServicing
{
    private let repository: any ScriptRepository
    private let recoveryStore: any ScriptRecoveryDraftStoring
    private let undoWindow: TimeInterval
    private let now: @Sendable () -> Date

    init(
        repository: any ScriptRepository,
        recoveryStore: any ScriptRecoveryDraftStoring,
        undoWindow: TimeInterval = 5,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.repository = repository
        self.recoveryStore = recoveryStore
        self.undoWindow = undoWindow
        self.now = now
    }

    func scripts(matching query: String) async throws -> [Script] {
        do {
            try await repository.purgeDeleted(
                before: now().addingTimeInterval(-undoWindow)
            )
            let storedScripts = try await repository.scripts()
            let normalizedQuery = ScriptMetrics.normalizedForSearch(query)

            guard !normalizedQuery.isEmpty else {
                return storedScripts.sorted { $0.updatedAt > $1.updatedAt }
            }

            return storedScripts
                .filter { script in
                    ScriptMetrics.normalizedForSearch(script.title)
                        .contains(normalizedQuery)
                    || script.normalizedContent.contains(normalizedQuery)
                }
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            throw mappedPersistenceError(error)
        }
    }

    func script(id: UUID) async throws -> Script {
        do {
            guard let script = try await repository.script(id: id) else {
                throw AppError.scriptNotFound
            }
            return script
        } catch {
            throw mappedPersistenceError(error)
        }
    }

    func createBlankScript() async throws -> Script {
        let creationDate = now()
        let script = prepared(
            Script(
                title: "",
                content: "",
                createdAt: creationDate,
                speechRateCharactersPerMinute: ScriptMetrics.defaultSpeechRate
            ),
            updateTimestamp: false
        )

        do {
            try await repository.save(script)
            AppLogger.info("script_created", category: .persistence)
            return script
        } catch {
            AppLogger.error("script_create_failed", category: .persistence)
            throw mappedPersistenceError(error)
        }
    }

    func update(_ script: Script) async throws -> Script {
        let updated = prepared(script, updateTimestamp: true)

        do {
            try await repository.save(updated)
            AppLogger.info("script_saved", category: .persistence)
            return updated
        } catch {
            AppLogger.error("script_save_failed", category: .persistence)
            throw mappedPersistenceError(error)
        }
    }

    func duplicate(id: UUID) async throws -> Script {
        let source = try await script(id: id)
        let duplicationDate = now()
        var duplicate = Script(
                title: duplicateTitle(for: source.title),
                content: source.content,
                createdAt: duplicationDate,
                speechRateCharactersPerMinute:
                    source.speechRateCharactersPerMinute
        )
        TeleprompterPreferences(script: source).applying(to: &duplicate)
        duplicate = prepared(duplicate, updateTimestamp: false)

        do {
            try await repository.save(duplicate)
            AppLogger.info("script_duplicated", category: .persistence)
            return duplicate
        } catch {
            AppLogger.error("script_duplicate_failed", category: .persistence)
            throw mappedPersistenceError(error)
        }
    }

    func delete(id: UUID) async throws -> ScriptDeletion {
        let script = try await script(id: id)
        let deletionDate = now()

        do {
            try await repository.delete(id: id, at: deletionDate)
            do {
                try await recoveryStore.removeAllDraftData(for: id)
            } catch {
                try? await repository.restore(id: id)
                await recoveryStore.allowDraftWrites(for: id)
                throw error
            }
            AppLogger.info("script_soft_deleted", category: .persistence)
            return ScriptDeletion(
                script: script,
                expiresAt: deletionDate.addingTimeInterval(undoWindow)
            )
        } catch {
            AppLogger.error("script_delete_failed", category: .persistence)
            throw mappedPersistenceError(error)
        }
    }

    func undo(_ deletion: ScriptDeletion) async throws {
        guard now() <= deletion.expiresAt else {
            try? await repository.permanentlyDelete(id: deletion.script.id)
            throw AppError.undoExpired
        }

        do {
            try await repository.restore(id: deletion.script.id)
            await recoveryStore.allowDraftWrites(for: deletion.script.id)
            AppLogger.info("script_delete_undone", category: .persistence)
        } catch {
            AppLogger.error("script_restore_failed", category: .persistence)
            throw mappedPersistenceError(error)
        }
    }

    func finalize(_ deletion: ScriptDeletion) async throws {
        do {
            try await repository.permanentlyDelete(id: deletion.script.id)
            AppLogger.info("script_delete_finalized", category: .persistence)
        } catch {
            AppLogger.error("script_delete_finalize_failed", category: .persistence)
            throw mappedPersistenceError(error)
        }
    }

    func recoveryDraft(
        newerThan script: Script
    ) async throws -> ScriptRecoveryDraft? {
        do {
            guard let draft = try await recoveryStore.draft(for: script.id)
            else {
                return nil
            }

            guard draft.matchesBaseVersion(of: script) else {
                if draft.baseScriptUpdatedAt < script.updatedAt {
                    try await recoveryStore.removeDraft(
                        for: script.id,
                        committedThrough: draft.writeVersion
                    )
                    return nil
                }
                throw AppError.recoveryDraftVersionMismatch
            }

            guard draft.draftUpdatedAt > script.updatedAt else {
                try await recoveryStore.removeDraft(
                    for: script.id,
                    committedThrough: draft.writeVersion
                )
                return nil
            }
            return draft
        } catch AppError.recoveryDraftCorrupted {
            try? await recoveryStore.removeUnreadableDraft(for: script.id)
            AppLogger.error(
                "script_recovery_draft_corrupted",
                category: .persistence
            )
            throw AppError.recoveryDraftCorrupted
        } catch let appError as AppError {
            throw appError
        } catch {
            throw AppError.recoveryDraftUnavailable
        }
    }

    func writeRecoveryDraft(_ draft: ScriptRecoveryDraft) async throws {
        do {
            try await recoveryStore.write(draft)
            AppLogger.info(
                "script_recovery_draft_saved",
                category: .persistence
            )
        } catch let appError as AppError {
            AppLogger.error(
                "script_recovery_draft_save_failed",
                category: .persistence
            )
            throw appError
        } catch {
            AppLogger.error(
                "script_recovery_draft_save_failed",
                category: .persistence
            )
            throw AppError.recoveryDraftUnavailable
        }
    }

    func clearRecoveryDraft(
        for scriptID: UUID,
        committedThrough version: ScriptRecoveryDraftWriteVersion
    ) async throws {
        do {
            try await recoveryStore.removeDraft(
                for: scriptID,
                committedThrough: version
            )
            AppLogger.info(
                "script_recovery_draft_cleared",
                category: .persistence
            )
        } catch {
            AppLogger.error(
                "script_recovery_draft_cleanup_failed",
                category: .persistence
            )
            throw AppError.recoveryDraftCleanupFailed
        }
    }

    func teleprompterScript(id: UUID) async throws -> Script {
        let storedScript = try await script(id: id)
        if try await recoveryDraft(newerThan: storedScript) != nil {
            throw AppError.pendingRecoveryDraftRequiresReview
        }
        return storedScript
    }

    func saveTeleprompterState(
        scriptID: UUID,
        anchor: ScriptReadingAnchor,
        preferences: TeleprompterPreferences
    ) async throws -> Script {
        var storedScript = try await script(id: scriptID)
        if try await recoveryDraft(newerThan: storedScript) != nil {
            throw AppError.pendingRecoveryDraftRequiresReview
        }

        storedScript.lastReadPosition = ScriptMetrics.clampedReadPosition(
            anchor.characterOffset,
            content: storedScript.content
        )
        preferences.applying(to: &storedScript)
        return try await update(storedScript)
    }

    private func prepared(
        _ script: Script,
        updateTimestamp: Bool
    ) -> Script {
        var result = script
        result.normalizedContent = ScriptMetrics.normalizedForSearch(script.content)
        result.speechRateCharactersPerMinute = ScriptMetrics.clampedSpeechRate(
            script.speechRateCharactersPerMinute
        )
        result.estimatedDuration = ScriptMetrics.estimatedDuration(
            for: script.content,
            charactersPerMinute: result.speechRateCharactersPerMinute
        )
        result.lastReadPosition = ScriptMetrics.clampedReadPosition(
            script.lastReadPosition,
            content: script.content
        )
        TeleprompterPreferences(script: result).applying(to: &result)
        if updateTimestamp {
            result.updatedAt = now()
        }
        return result
    }

    private func duplicateTitle(for title: String) -> String {
        ScriptEditorStrings.duplicateTitle(for: title)
    }

    private func mappedPersistenceError(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        return .persistenceUnavailable
    }
}

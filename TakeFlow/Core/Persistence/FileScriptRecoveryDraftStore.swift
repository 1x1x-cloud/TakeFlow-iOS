import Foundation

actor FileScriptRecoveryDraftStore: ScriptRecoveryDraftStoring {
    private let directoryURL: URL
    private var committedVersions:
        [UUID: ScriptRecoveryDraftWriteVersion] = [:]
    private var blockedScriptIDs: Set<UUID> = []

    init(directoryURL: URL) throws {
        self.directoryURL = directoryURL.standardizedFileURL
        try FileManager.default.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey:
                    FileProtectionType
                        .completeUntilFirstUserAuthentication
            ]
        )
    }

    static func production() throws -> FileScriptRecoveryDraftStore {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = applicationSupportURL
            .appendingPathComponent("TakeFlow", isDirectory: true)
            .appendingPathComponent("RecoveryDrafts", isDirectory: true)
        return try FileScriptRecoveryDraftStore(
            directoryURL: directoryURL
        )
    }

    func draft(for scriptID: UUID) throws -> ScriptRecoveryDraft? {
        let url = draftURL(for: scriptID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let draft = try decoder().decode(
                ScriptRecoveryDraft.self,
                from: data
            )
            guard
                draft.schemaVersion
                    == ScriptRecoveryDraft.currentSchemaVersion,
                draft.scriptID == scriptID
            else {
                throw AppError.recoveryDraftVersionMismatch
            }
            return draft
        } catch let appError as AppError {
            throw appError
        } catch is DecodingError {
            throw AppError.recoveryDraftCorrupted
        } catch {
            throw AppError.recoveryDraftUnavailable
        }
    }

    func write(_ draft: ScriptRecoveryDraft) throws {
        guard
            draft.schemaVersion == ScriptRecoveryDraft.currentSchemaVersion
        else {
            throw AppError.recoveryDraftVersionMismatch
        }
        guard !blockedScriptIDs.contains(draft.scriptID) else {
            return
        }

        let incomingVersion = draft.writeVersion
        if let committedVersion = committedVersions[draft.scriptID],
           !incomingVersion.isNewer(than: committedVersion) {
            return
        }

        if let existingDraft = try self.draft(for: draft.scriptID),
           !incomingVersion.isNewer(than: existingDraft.writeVersion) {
            return
        }

        do {
            let data = try encoder().encode(draft)
            try data.write(
                to: draftURL(for: draft.scriptID),
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication
                ]
            )
        } catch let appError as AppError {
            throw appError
        } catch {
            throw AppError.recoveryDraftUnavailable
        }
    }

    func removeDraft(
        for scriptID: UUID,
        committedThrough version: ScriptRecoveryDraftWriteVersion
    ) throws {
        if let existing = committedVersions[scriptID] {
            committedVersions[scriptID] = version.isNewer(than: existing)
                ? version
                : existing
        } else {
            committedVersions[scriptID] = version
        }
        try removeFileIfPresent(for: scriptID)
    }

    func removeAllDraftData(for scriptID: UUID) throws {
        blockedScriptIDs.insert(scriptID)
        try removeFileIfPresent(for: scriptID)
    }

    func removeUnreadableDraft(for scriptID: UUID) throws {
        try removeFileIfPresent(for: scriptID)
    }

    func allowDraftWrites(for scriptID: UUID) {
        blockedScriptIDs.remove(scriptID)
    }

    private func removeFileIfPresent(for scriptID: UUID) throws {
        let url = draftURL(for: scriptID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw AppError.recoveryDraftCleanupFailed
        }
    }

    private func draftURL(for scriptID: UUID) -> URL {
        directoryURL.appendingPathComponent(
            "\(scriptID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

import Foundation

struct ScriptRecoveryDraft: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let scriptID: UUID
    let title: String
    let content: String
    let lastReadPosition: Int
    let speechRateCharactersPerMinute: Double
    let draftUpdatedAt: Date
    let baseScriptUpdatedAt: Date
    let baseScriptVersion: UInt64
    let sessionID: UUID
    let revision: UInt64

    init(
        schemaVersion: Int = currentSchemaVersion,
        scriptID: UUID,
        title: String,
        content: String,
        lastReadPosition: Int,
        speechRateCharactersPerMinute: Double,
        draftUpdatedAt: Date,
        baseScriptUpdatedAt: Date,
        sessionID: UUID,
        revision: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.scriptID = scriptID
        self.title = title
        self.content = content
        self.lastReadPosition = lastReadPosition
        self.speechRateCharactersPerMinute =
            speechRateCharactersPerMinute
        self.draftUpdatedAt = draftUpdatedAt
        self.baseScriptUpdatedAt = baseScriptUpdatedAt
        self.baseScriptVersion =
            baseScriptUpdatedAt.timeIntervalSinceReferenceDate.bitPattern
        self.sessionID = sessionID
        self.revision = revision
    }

    var writeVersion: ScriptRecoveryDraftWriteVersion {
        ScriptRecoveryDraftWriteVersion(
            baseScriptUpdatedAt: baseScriptUpdatedAt,
            draftUpdatedAt: draftUpdatedAt,
            sessionID: sessionID,
            revision: revision
        )
    }

    func matchesBaseVersion(of script: Script) -> Bool {
        baseScriptVersion
            == script.updatedAt.timeIntervalSinceReferenceDate.bitPattern
    }
}

struct ScriptRecoveryDraftWriteVersion: Equatable, Sendable {
    let baseScriptUpdatedAt: Date
    let draftUpdatedAt: Date
    let sessionID: UUID
    let revision: UInt64

    func isNewer(than other: Self) -> Bool {
        if baseScriptUpdatedAt != other.baseScriptUpdatedAt {
            return baseScriptUpdatedAt > other.baseScriptUpdatedAt
        }
        if sessionID == other.sessionID {
            return revision > other.revision
        }
        if draftUpdatedAt != other.draftUpdatedAt {
            return draftUpdatedAt > other.draftUpdatedAt
        }
        return sessionID.uuidString > other.sessionID.uuidString
    }
}

import Foundation
import SwiftData

enum ScriptSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ScriptRecord.self]
    }

    @Model
    final class ScriptRecord {
        @Attribute(.unique) var id: UUID
        var title: String
        var content: String
        var normalizedContent: String
        var createdAt: Date
        var updatedAt: Date
        var estimatedDuration: TimeInterval
        var speechRateCharactersPerMinute: Double
        var preferredFontSize: Double
        var preferredScrollSpeed: Double
        var lastReadPosition: Int
        var deletedAt: Date?

        init(script: Script, deletedAt: Date? = nil) {
            id = script.id
            title = script.title
            content = script.content
            normalizedContent = script.normalizedContent
            createdAt = script.createdAt
            updatedAt = script.updatedAt
            estimatedDuration = script.estimatedDuration
            speechRateCharactersPerMinute = script.speechRateCharactersPerMinute
            preferredFontSize = script.preferredFontSize
            preferredScrollSpeed = script.preferredScrollSpeed
            lastReadPosition = script.lastReadPosition
            self.deletedAt = deletedAt
        }

        func update(from script: Script) {
            title = script.title
            content = script.content
            normalizedContent = script.normalizedContent
            updatedAt = script.updatedAt
            estimatedDuration = script.estimatedDuration
            speechRateCharactersPerMinute = script.speechRateCharactersPerMinute
            preferredFontSize = script.preferredFontSize
            preferredScrollSpeed = script.preferredScrollSpeed
            lastReadPosition = script.lastReadPosition
            deletedAt = nil
        }

        var value: Script {
            Script(
                id: id,
                title: title,
                content: content,
                normalizedContent: normalizedContent,
                createdAt: createdAt,
                updatedAt: updatedAt,
                estimatedDuration: estimatedDuration,
                speechRateCharactersPerMinute: speechRateCharactersPerMinute,
                preferredFontSize: preferredFontSize,
                preferredScrollSpeed: preferredScrollSpeed,
                lastReadPosition: lastReadPosition
            )
        }
    }
}

enum TakeFlowSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ScriptSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

typealias ScriptRecord = ScriptSchemaV1.ScriptRecord

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

enum ScriptSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

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
        var preferredLineSpacing: Double = 14
        var preferredHorizontalMargin: Double = 24
        var preferredTextAreaWidthFraction: Double = 1
        var preferredTextAreaVerticalPosition: Double = 0
        var preferredAppearanceRawValue: String = "dark"
        var isHorizontallyMirrored: Bool = false
        var isVerticallyMirrored: Bool = false
        var preferredCountdownSeconds: Int = 3
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
            speechRateCharactersPerMinute =
                script.speechRateCharactersPerMinute
            preferredFontSize = script.preferredFontSize
            preferredScrollSpeed = script.preferredScrollSpeed
            preferredLineSpacing = script.preferredLineSpacing
            preferredHorizontalMargin = script.preferredHorizontalMargin
            preferredTextAreaWidthFraction =
                script.preferredTextAreaWidthFraction
            preferredTextAreaVerticalPosition =
                script.preferredTextAreaVerticalPosition
            preferredAppearanceRawValue =
                script.preferredAppearanceRawValue
            isHorizontallyMirrored = script.isHorizontallyMirrored
            isVerticallyMirrored = script.isVerticallyMirrored
            preferredCountdownSeconds = script.preferredCountdownSeconds
            lastReadPosition = script.lastReadPosition
            self.deletedAt = deletedAt
        }

        func update(from script: Script) {
            title = script.title
            content = script.content
            normalizedContent = script.normalizedContent
            updatedAt = script.updatedAt
            estimatedDuration = script.estimatedDuration
            speechRateCharactersPerMinute =
                script.speechRateCharactersPerMinute
            preferredFontSize = script.preferredFontSize
            preferredScrollSpeed = script.preferredScrollSpeed
            preferredLineSpacing = script.preferredLineSpacing
            preferredHorizontalMargin = script.preferredHorizontalMargin
            preferredTextAreaWidthFraction =
                script.preferredTextAreaWidthFraction
            preferredTextAreaVerticalPosition =
                script.preferredTextAreaVerticalPosition
            preferredAppearanceRawValue =
                script.preferredAppearanceRawValue
            isHorizontallyMirrored = script.isHorizontallyMirrored
            isVerticallyMirrored = script.isVerticallyMirrored
            preferredCountdownSeconds = script.preferredCountdownSeconds
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
                speechRateCharactersPerMinute:
                    speechRateCharactersPerMinute,
                preferredFontSize: preferredFontSize,
                preferredScrollSpeed: preferredScrollSpeed,
                preferredLineSpacing: preferredLineSpacing,
                preferredHorizontalMargin: preferredHorizontalMargin,
                preferredTextAreaWidthFraction:
                    preferredTextAreaWidthFraction,
                preferredTextAreaVerticalPosition:
                    preferredTextAreaVerticalPosition,
                preferredAppearanceRawValue:
                    preferredAppearanceRawValue,
                isHorizontallyMirrored: isHorizontallyMirrored,
                isVerticallyMirrored: isVerticallyMirrored,
                preferredCountdownSeconds: preferredCountdownSeconds,
                lastReadPosition: lastReadPosition
            )
        }
    }
}

enum TakeFlowSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ScriptSchemaV1.self, ScriptSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: ScriptSchemaV1.self,
                toVersion: ScriptSchemaV2.self
            )
        ]
    }
}

typealias ScriptRecord = ScriptSchemaV2.ScriptRecord

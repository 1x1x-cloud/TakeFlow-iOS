import Foundation

struct Script: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var content: String
    var normalizedContent: String
    let createdAt: Date
    var updatedAt: Date
    var estimatedDuration: TimeInterval
    var speechRateCharactersPerMinute: Double
    var preferredFontSize: Double
    var preferredScrollSpeed: Double
    var preferredLineSpacing: Double
    var preferredHorizontalMargin: Double
    var preferredTextAreaWidthFraction: Double
    var preferredTextAreaVerticalPosition: Double
    var preferredAppearanceRawValue: String
    var isHorizontallyMirrored: Bool
    var isVerticallyMirrored: Bool
    var preferredCountdownSeconds: Int
    var lastReadPosition: Int

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        normalizedContent: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        estimatedDuration: TimeInterval = 0,
        speechRateCharactersPerMinute: Double = 240,
        preferredFontSize: Double = 44,
        preferredScrollSpeed: Double = 48,
        preferredLineSpacing: Double = 14,
        preferredHorizontalMargin: Double = 24,
        preferredTextAreaWidthFraction: Double = 1,
        preferredTextAreaVerticalPosition: Double = 0,
        preferredAppearanceRawValue: String =
            TeleprompterAppearance.dark.rawValue,
        isHorizontallyMirrored: Bool = false,
        isVerticallyMirrored: Bool = false,
        preferredCountdownSeconds: Int = 3,
        lastReadPosition: Int = 0
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.normalizedContent = normalizedContent
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.estimatedDuration = estimatedDuration
        self.speechRateCharactersPerMinute = speechRateCharactersPerMinute
        self.preferredFontSize = preferredFontSize
        self.preferredScrollSpeed = preferredScrollSpeed
        self.preferredLineSpacing = preferredLineSpacing
        self.preferredHorizontalMargin = preferredHorizontalMargin
        self.preferredTextAreaWidthFraction =
            preferredTextAreaWidthFraction
        self.preferredTextAreaVerticalPosition =
            preferredTextAreaVerticalPosition
        self.preferredAppearanceRawValue = preferredAppearanceRawValue
        self.isHorizontallyMirrored = isHorizontallyMirrored
        self.isVerticallyMirrored = isVerticallyMirrored
        self.preferredCountdownSeconds = preferredCountdownSeconds
        self.lastReadPosition = lastReadPosition
    }
}

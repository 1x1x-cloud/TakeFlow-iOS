import Foundation

struct Script: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var content: String
    var normalizedContent: String
    let createdAt: Date
    var updatedAt: Date
    var estimatedDuration: TimeInterval
    var preferredFontSize: Double
    var preferredScrollSpeed: Double
    var lastReadPosition: Int

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        normalizedContent: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        estimatedDuration: TimeInterval = 0,
        preferredFontSize: Double = 44,
        preferredScrollSpeed: Double = 1,
        lastReadPosition: Int = 0
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.normalizedContent = normalizedContent
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.estimatedDuration = estimatedDuration
        self.preferredFontSize = preferredFontSize
        self.preferredScrollSpeed = preferredScrollSpeed
        self.lastReadPosition = lastReadPosition
    }
}

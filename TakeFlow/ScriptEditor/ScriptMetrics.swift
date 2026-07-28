import Foundation

enum ScriptMetrics {
    static let defaultSpeechRate = 240.0
    static let minimumSpeechRate = 60.0
    static let maximumSpeechRate = 600.0

    static func characterCount(in text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if !character.isWhitespace {
                count += 1
            }
        }
    }

    static func estimatedDuration(
        for text: String,
        charactersPerMinute: Double
    ) -> TimeInterval {
        let rate = clampedSpeechRate(charactersPerMinute)
        let count = characterCount(in: text)
        return Double(count) / rate * 60
    }

    static func clampedSpeechRate(_ value: Double) -> Double {
        min(max(value, minimumSpeechRate), maximumSpeechRate)
    }

    static func clampedReadPosition(_ position: Int, content: String) -> Int {
        min(max(position, 0), content.count)
    }

    static func normalizedForSearch(_ text: String) -> String {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .lowercased()
    }
}

private extension Character {
    var isWhitespace: Bool {
        unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }
}

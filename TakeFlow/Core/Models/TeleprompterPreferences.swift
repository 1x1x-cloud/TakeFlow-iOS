import Foundation

enum TeleprompterAppearance: String, Codable, CaseIterable, Sendable {
    case dark
    case light
}

struct TeleprompterPreferences: Codable, Equatable, Sendable {
    static let defaultFontSize = 44.0
    static let defaultLineSpacing = 14.0
    static let defaultScrollSpeed = 48.0
    static let defaultHorizontalMargin = 24.0
    static let defaultTextAreaWidthFraction = 1.0
    static let defaultVerticalPosition = 0.0
    static let defaultCountdownSeconds = 3

    static let minimumFontSize = 24.0
    static let maximumFontSize = 96.0
    static let minimumLineSpacing = 0.0
    static let maximumLineSpacing = 48.0
    static let minimumScrollSpeed = 16.0
    static let maximumScrollSpeed = 160.0
    static let minimumHorizontalMargin = 8.0
    static let maximumHorizontalMargin = 80.0
    static let minimumTextAreaWidthFraction = 0.5
    static let maximumTextAreaWidthFraction = 1.0
    static let minimumVerticalPosition = -0.3
    static let maximumVerticalPosition = 0.3
    static let supportedCountdowns = [3, 5, 10]

    var fontSize: Double
    var lineSpacing: Double
    var scrollSpeedPointsPerSecond: Double
    var horizontalMargin: Double
    var textAreaWidthFraction: Double
    var verticalPosition: Double
    var appearance: TeleprompterAppearance
    var isHorizontallyMirrored: Bool
    var isVerticallyMirrored: Bool
    var countdownSeconds: Int

    init(
        fontSize: Double = defaultFontSize,
        lineSpacing: Double = defaultLineSpacing,
        scrollSpeedPointsPerSecond: Double = defaultScrollSpeed,
        horizontalMargin: Double = defaultHorizontalMargin,
        textAreaWidthFraction: Double = defaultTextAreaWidthFraction,
        verticalPosition: Double = defaultVerticalPosition,
        appearance: TeleprompterAppearance = .dark,
        isHorizontallyMirrored: Bool = false,
        isVerticallyMirrored: Bool = false,
        countdownSeconds: Int = defaultCountdownSeconds
    ) {
        self.fontSize = Self.clamp(
            fontSize,
            minimum: Self.minimumFontSize,
            maximum: Self.maximumFontSize
        )
        self.lineSpacing = Self.clamp(
            lineSpacing,
            minimum: Self.minimumLineSpacing,
            maximum: Self.maximumLineSpacing
        )
        self.scrollSpeedPointsPerSecond = Self.normalizedScrollSpeed(
            scrollSpeedPointsPerSecond
        )
        self.horizontalMargin = Self.clamp(
            horizontalMargin,
            minimum: Self.minimumHorizontalMargin,
            maximum: Self.maximumHorizontalMargin
        )
        self.textAreaWidthFraction = Self.clamp(
            textAreaWidthFraction,
            minimum: Self.minimumTextAreaWidthFraction,
            maximum: Self.maximumTextAreaWidthFraction
        )
        self.verticalPosition = Self.clamp(
            verticalPosition,
            minimum: Self.minimumVerticalPosition,
            maximum: Self.maximumVerticalPosition
        )
        self.appearance = appearance
        self.isHorizontallyMirrored = isHorizontallyMirrored
        self.isVerticallyMirrored = isVerticallyMirrored
        self.countdownSeconds = Self.supportedCountdowns.contains(
            countdownSeconds
        )
            ? countdownSeconds
            : Self.defaultCountdownSeconds
    }

    init(script: Script) {
        self.init(
            fontSize: script.preferredFontSize,
            lineSpacing: script.preferredLineSpacing,
            scrollSpeedPointsPerSecond: script.preferredScrollSpeed,
            horizontalMargin: script.preferredHorizontalMargin,
            textAreaWidthFraction: script.preferredTextAreaWidthFraction,
            verticalPosition: script.preferredTextAreaVerticalPosition,
            appearance: TeleprompterAppearance(
                rawValue: script.preferredAppearanceRawValue
            ) ?? .dark,
            isHorizontallyMirrored: script.isHorizontallyMirrored,
            isVerticallyMirrored: script.isVerticallyMirrored,
            countdownSeconds: script.preferredCountdownSeconds
        )
    }

    func applying(to script: inout Script) {
        script.preferredFontSize = fontSize
        script.preferredLineSpacing = lineSpacing
        script.preferredScrollSpeed = scrollSpeedPointsPerSecond
        script.preferredHorizontalMargin = horizontalMargin
        script.preferredTextAreaWidthFraction = textAreaWidthFraction
        script.preferredTextAreaVerticalPosition = verticalPosition
        script.preferredAppearanceRawValue = appearance.rawValue
        script.isHorizontallyMirrored = isHorizontallyMirrored
        script.isVerticallyMirrored = isVerticallyMirrored
        script.preferredCountdownSeconds = countdownSeconds
    }

    private static func normalizedScrollSpeed(_ value: Double) -> Double {
        // Module 0/1 stored an unexposed multiplier with a default of 1.
        // Values below the first public points-per-second range migrate to
        // the Module 2 default instead of becoming unusably slow.
        guard value >= minimumScrollSpeed else {
            return defaultScrollSpeed
        }
        return clamp(
            value,
            minimum: minimumScrollSpeed,
            maximum: maximumScrollSpeed
        )
    }

    private static func clamp(
        _ value: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        min(max(value, minimum), maximum)
    }
}

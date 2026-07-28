import Foundation

struct UserPreferences: Codable, Equatable, Sendable {
    var defaultFontSize: Double
    var lineSpacing: Double
    var textAreaWidth: Double
    var textAreaVerticalPosition: Double
    var overlayOpacity: Double
    var countdownSeconds: Int
    var defaultResolution: VideoResolution
    var voiceTrackingEnabled: Bool

    init(
        defaultFontSize: Double = 44,
        lineSpacing: Double = 12,
        textAreaWidth: Double = 0.85,
        textAreaVerticalPosition: Double = 0.5,
        overlayOpacity: Double = 0.65,
        countdownSeconds: Int = 3,
        defaultResolution: VideoResolution = .fullHD1080p,
        voiceTrackingEnabled: Bool = false
    ) {
        self.defaultFontSize = defaultFontSize
        self.lineSpacing = lineSpacing
        self.textAreaWidth = textAreaWidth
        self.textAreaVerticalPosition = textAreaVerticalPosition
        self.overlayOpacity = overlayOpacity
        self.countdownSeconds = countdownSeconds
        self.defaultResolution = defaultResolution
        self.voiceTrackingEnabled = voiceTrackingEnabled
    }
}

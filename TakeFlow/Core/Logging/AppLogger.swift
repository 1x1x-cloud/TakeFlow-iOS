import OSLog

enum LogCategory: String, Sendable {
    case appLifecycle
    case persistence
    case permissions
    case recording
    case speechTracking
    case export
    case subscription
}

enum AppLogger {
    private static let subsystem = "com.example.takeflow.placeholder"

    static func info(_ event: String, category: LogCategory) {
        logger(for: category).info("\(event, privacy: .public)")
    }

    static func error(_ event: String, category: LogCategory) {
        logger(for: category).error("\(event, privacy: .public)")
    }

    private static func logger(for category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}

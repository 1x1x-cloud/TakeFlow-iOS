import Foundation

enum TeleprompterState: Equatable, Sendable {
    case idle
    case countingDown(remainingSeconds: Int)
    case running
    case paused
    case userDragging(resumesWhenReleased: Bool)
    case finished
    case error(AppError)

    var accessibilityDescription: String {
        switch self {
        case .idle:
            return TeleprompterStrings.stateIdle
        case .countingDown(let remainingSeconds):
            return TeleprompterStrings.countdownState(remainingSeconds)
        case .running:
            return TeleprompterStrings.stateRunning
        case .paused:
            return TeleprompterStrings.statePaused
        case .userDragging:
            return TeleprompterStrings.stateDragging
        case .finished:
            return TeleprompterStrings.stateFinished
        case .error:
            return TeleprompterStrings.stateError
        }
    }
}

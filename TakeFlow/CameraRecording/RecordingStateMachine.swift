import Foundation

enum RecordingState: Equatable, Sendable {
    case idle
    case requestingPermissions
    case configuring
    case ready
    case starting(countdownRemaining: Int)
    case recording(recordingID: UUID)
    case stopping(recordingID: UUID)
    case finished(recordingID: UUID, fileURL: URL)
    case interrupted(recordingID: UUID?, reason: CaptureInterruptionReason)
    case failed(CaptureError)

    var isActivelyRecording: Bool {
        switch self {
        case .recording, .stopping:
            true
        default:
            false
        }
    }
}

struct RecordingStateMachine: Sendable {
    private(set) var state: RecordingState = .idle
    private(set) var generation: UInt64 = 0

    mutating func beginPermissionRequest() throws {
        guard state == .idle || isTerminal else {
            throw CaptureError.invalidTransition
        }
        generation &+= 1
        state = .requestingPermissions
    }

    mutating func beginConfiguration() throws {
        guard state == .requestingPermissions || isTerminal else {
            throw CaptureError.invalidTransition
        }
        state = .configuring
    }

    mutating func markReady() throws {
        guard
            state == .configuring
                || state == .interrupted(
                    recordingID: nil,
                    reason: .mediaServicesReset
                )
        else {
            throw CaptureError.invalidTransition
        }
        state = .ready
    }

    mutating func beginCountdown(seconds: Int) throws {
        guard state == .ready, seconds > 0 else {
            throw CaptureError.invalidTransition
        }
        state = .starting(countdownRemaining: seconds)
    }

    mutating func updateCountdown(remaining: Int) throws {
        guard case .starting = state, remaining > 0 else {
            throw CaptureError.invalidTransition
        }
        state = .starting(countdownRemaining: remaining)
    }

    mutating func cancelCountdown() throws {
        guard case .starting = state else {
            throw CaptureError.invalidTransition
        }
        state = .ready
    }

    mutating func markRecording(recordingID: UUID) throws {
        guard case .starting = state else {
            throw CaptureError.invalidTransition
        }
        state = .recording(recordingID: recordingID)
    }

    mutating func beginStopping(recordingID: UUID) throws -> Bool {
        switch state {
        case .recording(let activeID) where activeID == recordingID:
            state = .stopping(recordingID: recordingID)
            return true
        case .stopping(let activeID) where activeID == recordingID:
            return false
        default:
            throw CaptureError.notRecording
        }
    }

    mutating func finish(
        recordingID: UUID,
        fileURL: URL,
        generation callbackGeneration: UInt64
    ) throws {
        guard callbackGeneration == generation else {
            throw CaptureError.staleCallback
        }
        guard case .stopping(let activeID) = state, activeID == recordingID
        else {
            throw CaptureError.staleCallback
        }
        state = .finished(recordingID: recordingID, fileURL: fileURL)
    }

    mutating func interrupt(
        recordingID: UUID?,
        reason: CaptureInterruptionReason
    ) -> Bool {
        switch state {
        case .recording(let activeID), .stopping(let activeID):
            guard recordingID == nil || recordingID == activeID else {
                return false
            }
            state = .interrupted(recordingID: activeID, reason: reason)
            return true
        case .ready, .configuring:
            state = .interrupted(recordingID: nil, reason: reason)
            return true
        case .interrupted:
            return false
        default:
            return false
        }
    }

    mutating func fail(_ error: CaptureError) {
        state = .failed(error)
    }

    mutating func reset() {
        generation &+= 1
        state = .idle
    }

    func permitsCameraSwitch() -> Bool {
        state == .ready || isTerminal
    }

    private var isTerminal: Bool {
        switch state {
        case .finished, .interrupted, .failed:
            true
        default:
            false
        }
    }
}

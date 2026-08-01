import Foundation

enum RecordingState: Equatable, Sendable {
    case idle
    case requestingPermissions
    case configuring
    case ready
    case starting(countdownRemaining: Int)
    case awaitingRecordingStart(recordingID: UUID)
    case recording(recordingID: UUID)
    case stopping(recordingID: UUID)
    case finished(recordingID: UUID, fileURL: URL)
    case interrupted(recordingID: UUID?, reason: CaptureInterruptionReason)
    case recoveryRequired(reason: CaptureInterruptionReason)
    case failed(CaptureError)

    var isActivelyRecording: Bool {
        switch self {
        case .recording, .stopping:
            true
        default:
            false
        }
    }

    var hasPendingOrActiveRecording: Bool {
        switch self {
        case .awaitingRecordingStart, .recording, .stopping:
            true
        default:
            false
        }
    }
}

struct RecordingStateMachine: Sendable {
    private(set) var state: RecordingState = .idle
    private(set) var generation: UInt64 = 0
    private var activeInterruptionSources: Set<CaptureInterruptionSource> = []
    private var endedSourcesAwaitingBegin: Set<CaptureInterruptionSource> = []
    private var interruptedRecordingWasFinalized = true

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

    mutating func beginCameraSwitch() throws {
        guard state == .ready else {
            throw CaptureError.invalidTransition
        }
        state = .configuring
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

    mutating func markRecordingStartRequested(recordingID: UUID) throws {
        guard case .starting = state else {
            throw CaptureError.invalidTransition
        }
        state = .awaitingRecordingStart(recordingID: recordingID)
    }

    mutating func confirmRecordingStarted(recordingID: UUID) throws {
        guard
            case .awaitingRecordingStart(let requestedID) = state,
            requestedID == recordingID
        else {
            throw CaptureError.staleCallback
        }
        state = .recording(recordingID: recordingID)
    }

    mutating func beginStopping(recordingID: UUID) throws -> Bool {
        switch state {
        case .awaitingRecordingStart(let activeID)
            where activeID == recordingID:
            state = .stopping(recordingID: recordingID)
            return true
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

    mutating func prepareForNextRecording(
        recordingID: UUID,
        generation callbackGeneration: UInt64
    ) throws {
        guard callbackGeneration == generation else {
            throw CaptureError.staleCallback
        }
        guard
            case .finished(let finishedID, _) = state,
            finishedID == recordingID
        else {
            throw CaptureError.invalidTransition
        }
        state = .ready
    }

    mutating func interrupt(
        recordingID: UUID?,
        reason: CaptureInterruptionReason,
        source: CaptureInterruptionSource = .captureSession
    ) -> Bool {
        switch state {
        case .awaitingRecordingStart(let activeID),
             .recording(let activeID),
             .stopping(let activeID):
            guard recordingID == nil || recordingID == activeID else {
                return false
            }
            activeInterruptionSources = [source]
            interruptedRecordingWasFinalized = false
            state = .interrupted(recordingID: activeID, reason: reason)
            consumePrecedingEnd(for: source)
            return true
        case .ready, .configuring:
            activeInterruptionSources = [source]
            interruptedRecordingWasFinalized = true
            state = .interrupted(recordingID: nil, reason: reason)
            consumePrecedingEnd(for: source)
            return true
        case .interrupted(let activeID, _):
            guard recordingID == nil || activeID == nil || recordingID == activeID
            else {
                return false
            }
            let inserted = activeInterruptionSources.insert(source).inserted
            consumePrecedingEnd(for: source)
            return inserted
        case .recoveryRequired:
            guard recordingID == nil else {
                return false
            }
            activeInterruptionSources = [source]
            interruptedRecordingWasFinalized = true
            state = .interrupted(recordingID: nil, reason: reason)
            consumePrecedingEnd(for: source)
            return true
        default:
            return false
        }
    }

    mutating func endInterruption(
        source: CaptureInterruptionSource
    ) -> Bool {
        guard case .interrupted(_, let reason) = state else {
            switch state {
            case .ready, .awaitingRecordingStart, .recording, .stopping,
                 .configuring:
                endedSourcesAwaitingBegin.insert(source)
            default:
                break
            }
            return false
        }
        activeInterruptionSources.remove(source)
        guard
            activeInterruptionSources.isEmpty,
            interruptedRecordingWasFinalized
        else {
            return false
        }
        state = .recoveryRequired(reason: reason)
        return true
    }

    mutating func markInterruptedRecordingFinalized(
        recordingID: UUID
    ) throws {
        guard
            case .interrupted(let activeID, let reason) = state,
            activeID == recordingID
        else {
            throw CaptureError.staleCallback
        }
        interruptedRecordingWasFinalized = true
        if activeInterruptionSources.isEmpty {
            state = .recoveryRequired(reason: reason)
        } else {
            state = .interrupted(recordingID: nil, reason: reason)
        }
    }

    mutating func fail(_ error: CaptureError) {
        activeInterruptionSources.removeAll()
        endedSourcesAwaitingBegin.removeAll()
        interruptedRecordingWasFinalized = true
        state = .failed(error)
    }

    mutating func reset() {
        generation &+= 1
        activeInterruptionSources.removeAll()
        endedSourcesAwaitingBegin.removeAll()
        interruptedRecordingWasFinalized = true
        state = .idle
    }

    func permitsCameraSwitch() -> Bool {
        state == .ready
    }

    func permitsRecovery() -> Bool {
        switch state {
        case .recoveryRequired, .failed:
            true
        default:
            false
        }
    }

    private mutating func consumePrecedingEnd(
        for source: CaptureInterruptionSource
    ) {
        guard endedSourcesAwaitingBegin.remove(source) != nil else {
            return
        }
        activeInterruptionSources.remove(source)
        guard
            activeInterruptionSources.isEmpty,
            interruptedRecordingWasFinalized,
            case .interrupted(_, let reason) = state
        else {
            return
        }
        state = .recoveryRequired(reason: reason)
    }

    private var isTerminal: Bool {
        switch state {
        case .finished, .interrupted, .recoveryRequired, .failed:
            true
        default:
            false
        }
    }
}

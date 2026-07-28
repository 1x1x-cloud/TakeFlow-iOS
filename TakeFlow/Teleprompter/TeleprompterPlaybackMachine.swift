import Foundation

/// A deterministic playback state machine.
///
/// All time arguments are elapsed seconds from one monotonic clock origin.
/// The machine derives position from a run-segment origin instead of adding a
/// per-frame delta, so refresh rate does not change logical scroll distance.
struct TeleprompterPlaybackMachine: Equatable, Sendable {
    private(set) var state: TeleprompterState = .idle
    private(set) var scrollOffset = 0.0
    private(set) var maximumScrollOffset = 0.0
    private(set) var anchor = ScriptReadingAnchor(characterOffset: 0)

    private(set) var scrollSpeedPointsPerSecond: Double
    private var countdownDeadline: TimeInterval?
    private var runStartedAt: TimeInterval?
    private var runBaseOffset = 0.0

    init(scrollSpeedPointsPerSecond: Double) {
        self.scrollSpeedPointsPerSecond = scrollSpeedPointsPerSecond
    }

    mutating func configure(
        initialAnchor: ScriptReadingAnchor,
        initialOffset: Double = 0,
        maximumOffset: Double
    ) {
        anchor = initialAnchor
        maximumScrollOffset = max(0, maximumOffset)
        scrollOffset = clampOffset(initialOffset)
        runBaseOffset = scrollOffset
    }

    mutating func start(
        at now: TimeInterval,
        countdownSeconds: Int,
        hasReadableContent: Bool
    ) {
        guard hasReadableContent else {
            state = .error(.emptyScript)
            return
        }
        guard state != .running, !isCountingDown else {
            return
        }

        if countdownSeconds > 0 {
            countdownDeadline = now + TimeInterval(countdownSeconds)
            state = .countingDown(remainingSeconds: countdownSeconds)
        } else {
            beginRunning(at: now)
        }
    }

    mutating func cancelCountdown() {
        guard isCountingDown else {
            return
        }
        countdownDeadline = nil
        state = .idle
    }

    mutating func tick(at now: TimeInterval) {
        switch state {
        case .countingDown:
            guard let countdownDeadline else {
                state = .error(.invalidState)
                return
            }
            if now >= countdownDeadline {
                beginRunning(at: countdownDeadline)
                updateRunningPosition(at: now)
            } else {
                state = .countingDown(
                    remainingSeconds: max(
                        1,
                        Int(ceil(countdownDeadline - now))
                    )
                )
            }
        case .running:
            updateRunningPosition(at: now)
        default:
            break
        }
    }

    mutating func pause(at now: TimeInterval) {
        guard state == .running else {
            return
        }
        updateRunningPosition(at: now)
        guard state != .finished else {
            return
        }
        freezeRunSegment()
        state = .paused
    }

    mutating func resume(at now: TimeInterval) {
        guard state == .paused else {
            return
        }
        beginRunning(at: now)
    }

    mutating func beginDragging(at now: TimeInterval) {
        let resumesWhenReleased = state == .running
        if resumesWhenReleased {
            updateRunningPosition(at: now)
        }
        guard state != .error(.emptyScript) else {
            return
        }
        freezeRunSegment()
        countdownDeadline = nil
        state = .userDragging(
            resumesWhenReleased: resumesWhenReleased
        )
    }

    mutating func updateDrag(
        offset: Double,
        anchor newAnchor: ScriptReadingAnchor
    ) {
        guard case .userDragging = state else {
            return
        }
        scrollOffset = clampOffset(offset)
        runBaseOffset = scrollOffset
        anchor = newAnchor
    }

    mutating func endDragging(
        at now: TimeInterval,
        offset: Double,
        anchor newAnchor: ScriptReadingAnchor
    ) {
        guard case .userDragging(let resumesWhenReleased) = state else {
            return
        }
        scrollOffset = clampOffset(offset)
        runBaseOffset = scrollOffset
        anchor = newAnchor

        if scrollOffset >= maximumScrollOffset,
           maximumScrollOffset > 0 {
            state = .finished
        } else if resumesWhenReleased {
            beginRunning(at: now)
        } else {
            state = .paused
        }
    }

    mutating func restart() {
        countdownDeadline = nil
        runStartedAt = nil
        runBaseOffset = 0
        scrollOffset = 0
        anchor = ScriptReadingAnchor(characterOffset: 0)
        state = .idle
    }

    mutating func enterBackground(at now: TimeInterval) {
        switch state {
        case .running:
            pause(at: now)
        case .countingDown:
            countdownDeadline = nil
            state = .paused
        case .userDragging:
            freezeRunSegment()
            state = .paused
        default:
            break
        }
    }

    mutating func returnToForeground(at now: TimeInterval) {
        if state == .running {
            runStartedAt = now
            runBaseOffset = scrollOffset
        }
    }

    mutating func updateScrollSpeed(
        _ pointsPerSecond: Double,
        at now: TimeInterval
    ) {
        if state == .running {
            updateRunningPosition(at: now)
        }
        scrollSpeedPointsPerSecond = max(0, pointsPerSecond)
        if state == .running {
            runStartedAt = now
            runBaseOffset = scrollOffset
        }
    }

    mutating func updateLayout(
        maximumOffset: Double,
        restoredOffset: Double,
        anchor preservedAnchor: ScriptReadingAnchor
    ) {
        maximumScrollOffset = max(0, maximumOffset)
        scrollOffset = clampOffset(restoredOffset)
        runBaseOffset = scrollOffset
        anchor = preservedAnchor
    }

    mutating func updateVisibleAnchor(
        _ visibleAnchor: ScriptReadingAnchor
    ) {
        anchor = visibleAnchor
    }

    mutating func fail(_ error: AppError) {
        freezeRunSegment()
        countdownDeadline = nil
        state = .error(error)
    }

    private var isCountingDown: Bool {
        if case .countingDown = state {
            return true
        }
        return false
    }

    private mutating func beginRunning(at now: TimeInterval) {
        countdownDeadline = nil
        runStartedAt = now
        runBaseOffset = scrollOffset
        state = .running
    }

    private mutating func updateRunningPosition(at now: TimeInterval) {
        guard let runStartedAt else {
            state = .error(.invalidState)
            return
        }
        let elapsed = max(0, now - runStartedAt)
        scrollOffset = clampOffset(
            runBaseOffset + elapsed * scrollSpeedPointsPerSecond
        )
        if scrollOffset >= maximumScrollOffset,
           maximumScrollOffset > 0 {
            freezeRunSegment()
            state = .finished
        }
    }

    private mutating func freezeRunSegment() {
        runStartedAt = nil
        runBaseOffset = scrollOffset
    }

    private func clampOffset(_ offset: Double) -> Double {
        min(max(0, offset), maximumScrollOffset)
    }
}

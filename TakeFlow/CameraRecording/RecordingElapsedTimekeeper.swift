import Foundation

protocol RecordingMonotonicTimeProviding: Sendable {
    var uptimeNanoseconds: UInt64 { get }
}

struct SystemRecordingMonotonicTimeSource:
    RecordingMonotonicTimeProviding
{
    var uptimeNanoseconds: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

enum RecordingMediaPolicy {
    static let movieFragmentIntervalSeconds: TimeInterval = 2
    static let durationUpdateInterval = DispatchTimeInterval.milliseconds(250)
}

struct RecordingElapsedTimekeeper {
    private let timeSource: any RecordingMonotonicTimeProviding
    private var activeRecordingID: UUID?
    private var startNanoseconds: UInt64?

    init(
        timeSource: any RecordingMonotonicTimeProviding =
            SystemRecordingMonotonicTimeSource()
    ) {
        self.timeSource = timeSource
    }

    mutating func start(recordingID: UUID) -> Bool {
        guard activeRecordingID == nil else {
            return false
        }
        activeRecordingID = recordingID
        startNanoseconds = timeSource.uptimeNanoseconds
        return true
    }

    func elapsed(for recordingID: UUID) -> TimeInterval? {
        guard
            activeRecordingID == recordingID,
            let startNanoseconds
        else {
            return nil
        }
        let now = timeSource.uptimeNanoseconds
        let elapsedNanoseconds =
            now >= startNanoseconds ? now - startNanoseconds : 0
        let seconds = TimeInterval(elapsedNanoseconds) / 1_000_000_000
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    mutating func stop(recordingID: UUID) -> TimeInterval? {
        guard activeRecordingID == recordingID else {
            return nil
        }
        let elapsed = elapsed(for: recordingID)
        activeRecordingID = nil
        startNanoseconds = nil
        return elapsed
    }

    mutating func reset() {
        activeRecordingID = nil
        startNanoseconds = nil
    }
}

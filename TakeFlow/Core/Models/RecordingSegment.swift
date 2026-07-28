import Foundation

enum RecordingSegmentStatus: String, Codable, CaseIterable, Sendable {
    case recording
    case completed
    case discarded
    case failed
}

struct RecordingSegment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let projectID: UUID
    var sequence: Int
    let localFileURL: URL
    var startScriptPosition: Int
    var endScriptPosition: Int
    var duration: TimeInterval
    var status: RecordingSegmentStatus
    let createdAt: Date

    init(
        id: UUID = UUID(),
        projectID: UUID,
        sequence: Int,
        localFileURL: URL,
        startScriptPosition: Int = 0,
        endScriptPosition: Int = 0,
        duration: TimeInterval = 0,
        status: RecordingSegmentStatus = .recording,
        createdAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.sequence = sequence
        self.localFileURL = localFileURL
        self.startScriptPosition = startScriptPosition
        self.endScriptPosition = endScriptPosition
        self.duration = duration
        self.status = status
        self.createdAt = createdAt
    }
}

import Foundation

enum RecordingProjectStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case recording
    case needsRecovery
    case readyToExport
    case exporting
    case completed
    case failed
}

enum CaptureOrientation: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscapeLeft
    case landscapeRight
}

enum VideoResolution: String, Codable, CaseIterable, Sendable {
    case fullHD1080p
    case ultraHD4K
}

struct RecordingProject: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let scriptID: UUID
    let createdAt: Date
    var updatedAt: Date
    var status: RecordingProjectStatus
    var orientation: CaptureOrientation
    var resolution: VideoResolution
    var activeSegmentID: UUID?
    var finalVideoURL: URL?
    var captionFileURL: URL?

    init(
        id: UUID = UUID(),
        scriptID: UUID,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        status: RecordingProjectStatus = .draft,
        orientation: CaptureOrientation = .portrait,
        resolution: VideoResolution = .fullHD1080p,
        activeSegmentID: UUID? = nil,
        finalVideoURL: URL? = nil,
        captionFileURL: URL? = nil
    ) {
        self.id = id
        self.scriptID = scriptID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.status = status
        self.orientation = orientation
        self.resolution = resolution
        self.activeSegmentID = activeSegmentID
        self.finalVideoURL = finalVideoURL
        self.captionFileURL = captionFileURL
    }
}

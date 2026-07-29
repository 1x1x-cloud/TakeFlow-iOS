import Foundation

protocol CaptureSessionServicing: Sendable {
    func events() async -> AsyncStream<CaptureSessionEvent>
    func configure(
        position: CameraPosition,
        preferredResolution: VideoResolution
    ) async throws
    func startPreview() async throws
    func stopPreview() async
    func switchCamera() async throws
    func startRecording(
        recordingID: UUID,
        outputURL: URL,
        rotationAngle: Double
    ) async throws
    func stopRecording(recordingID: UUID) async throws
    func setFocusAndExposure(
        at point: NormalizedCapturePoint,
        locked: Bool
    ) async throws
    func handleApplicationBackgrounded() async
    func handleApplicationForegrounded() async
}

protocol RecordingFileStoring: Sendable {
    func createRecording(
        scriptID: UUID,
        orientation: CaptureOrientation,
        resolution: VideoResolution
    ) async throws -> PendingRecording
    func markRecordingStarted(_ recording: PendingRecording) async throws
    func completeRecording(
        _ recording: PendingRecording,
        duration: TimeInterval
    ) async throws -> CompletedRecording
    func preserveRecoverableRecording(
        _ recording: PendingRecording,
        reason: CaptureInterruptionReason
    ) async throws -> RecoverableRecording
    func recoverPendingRecordings() async -> [RecoverableRecording]
    func deleteProject(projectID: UUID) async throws
}

protocol StorageSpaceChecking: Sendable {
    func availableCapacityForImportantUsage() async throws -> Int64
}

protocol PhotoLibrarySaving: Sendable {
    func authorizationStatus() async -> PermissionState
    func saveVideo(at url: URL) async -> PhotoSaveResult
}

protocol AudioSessionServicing: Sendable {
    func currentInputRoute() async -> AudioInputRoute
    func activateForRecording() async throws
    func deactivateAfterRecording() async
    func events() async -> AsyncStream<AudioSessionEvent>
}

struct RecordingStoragePolicy: Equatable, Sendable {
    let minimumStartBytes: Int64
    let safeStopBytes: Int64
    let checkInterval: Duration

    static let production = RecordingStoragePolicy(
        minimumStartBytes: 500 * 1_024 * 1_024,
        safeStopBytes: 250 * 1_024 * 1_024,
        checkInterval: .seconds(5)
    )
}

struct PendingRecording: Codable, Equatable, Sendable {
    let projectID: UUID
    let recordingID: UUID
    let scriptID: UUID
    let temporaryURL: URL
    let finalURL: URL
    let createdAt: Date
    let orientation: CaptureOrientation
    let resolution: VideoResolution
}

struct CompletedRecording: Codable, Equatable, Sendable {
    let projectID: UUID
    let recordingID: UUID
    let fileURL: URL
    let duration: TimeInterval
    let completedAt: Date
}

struct RecoverableRecording: Codable, Equatable, Sendable {
    let projectID: UUID
    let recordingID: UUID
    let fileURL: URL
    let reason: CaptureInterruptionReason
    let discoveredAt: Date
}

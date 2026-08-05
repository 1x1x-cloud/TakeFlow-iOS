import Foundation

protocol CaptureSessionServicing: Sendable {
    /// Returns an event stream scoped to one visible camera-page lifecycle.
    /// Implementations must never deliver another lifecycle's events here.
    func events(
        for sessionID: UUID
    ) async -> AsyncStream<CaptureSessionEvent>
    func configure(
        sessionID: UUID,
        position: CameraPosition,
        preferredResolution: VideoResolution
    ) async throws
    func startPreview(sessionID: UUID) async throws
    func stopPreview(sessionID: UUID) async
    func switchCamera(sessionID: UUID) async throws
    func startRecording(
        sessionID: UUID,
        recordingID: UUID,
        outputURL: URL,
        rotationAngle: Double
    ) async throws
    func stopRecording(recordingID: UUID) async throws
    func setFocusAndExposurePoint(
        sessionID: UUID,
        at point: NormalizedCapturePoint
    ) async throws -> CapturePointAdjustmentResult
    func setFocusAndExposureLocked(
        sessionID: UUID,
        locked: Bool
    ) async throws -> CaptureFocusExposureLockState
    func handleApplicationBackgrounded(sessionID: UUID) async
    func handleApplicationForegrounded(sessionID: UUID) async
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
    /// Includes durable recoverables and atomically promotes non-empty orphan
    /// recordings found during launch/new-lifecycle recovery.
    func recoverPendingRecordings() async -> [RecoverableRecording]
    /// Returns only records whose recoverable/damaged manifest was already
    /// durably committed. This is safe for an active foreground reconciliation.
    func recoverCommittedRecordings() async -> [RecoverableRecording]
    func retainRecoverableRecording(
        _ recording: RecoverableRecording,
        duration: TimeInterval
    ) async throws -> CompletedRecording
    func markRecoverableRecordingDamaged(
        _ recording: RecoverableRecording
    ) async throws -> RecoverableRecording
    func deleteRecoverableRecording(
        projectID: UUID,
        recordingID: UUID
    ) async throws
    func deleteProject(projectID: UUID) async throws
}

protocol RecoverableMediaValidating: Sendable {
    func validate(
        _ recording: RecoverableRecording
    ) async -> RecoverableMediaValidationResult
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

struct RecordingBackgroundTaskToken: Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Grants only the finite execution time needed to finalize an interrupted
/// recording. It never authorizes recording to continue in the background.
@MainActor
protocol RecordingBackgroundTaskManaging: AnyObject {
    func beginRecordingFinalization(
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> RecordingBackgroundTaskToken?
    func endRecordingFinalization(_ token: RecordingBackgroundTaskToken)
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
    var origin: CompletedRecordingOrigin? = nil

    var isInterruptedRecovery: Bool {
        origin == .interruptedRecovery
    }
}

enum CompletedRecordingOrigin: String, Codable, Sendable {
    case interruptedRecovery
}

enum RecoverableRecordingDisposition: String, Codable, Sendable {
    case pendingReview
    case damaged
}

struct RecoverableRecording: Codable, Equatable, Sendable {
    let projectID: UUID
    let recordingID: UUID
    let fileURL: URL
    let reason: CaptureInterruptionReason
    let discoveredAt: Date
    var disposition: RecoverableRecordingDisposition = .pendingReview
}

struct RecoverableMediaInfo: Equatable, Sendable {
    let duration: TimeInterval
    let hasAudioTrack: Bool
}

enum RecoverableMediaValidationFailure: Equatable, Sendable {
    case fileMissing
    case containerUnrecognized
    case videoTrackMissing
    case durationInvalid
    case notPlayable
}

enum RecoverableMediaValidationResult: Equatable, Sendable {
    case playable(RecoverableMediaInfo)
    case invalid(RecoverableMediaValidationFailure)
}

enum RecoverableRecordingReviewState: Equatable, Sendable {
    case pending
    case validating
    case playable(RecoverableMediaInfo)
    case damaged(RecoverableMediaValidationFailure)
    case retaining(RecoverableMediaInfo)
    case retained(CompletedRecording, RecoverableMediaInfo)
    case deleting
    case operationFailed(String, RecoverableMediaInfo?)
}

struct RecoverableRecordingReviewItem: Identifiable, Equatable, Sendable {
    let recording: RecoverableRecording
    var state: RecoverableRecordingReviewState

    var id: UUID { recording.recordingID }
}

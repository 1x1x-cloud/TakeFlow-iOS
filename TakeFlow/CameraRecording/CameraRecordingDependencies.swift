import Foundation

@MainActor
struct CameraRecordingDependencies {
    let permissions: any PermissionAuthorizing
    let capture: any CaptureSessionServicing
    let files: any RecordingFileStoring
    let storage: any StorageSpaceChecking
    let photos: any PhotoLibrarySaving
    let audio: any AudioSessionServicing
    let storagePolicy: RecordingStoragePolicy
    let countdownSeconds: Int
    let countdownStep: Duration
#if DEBUG
    let isUITestFake: Bool
#endif

    static func production() throws -> CameraRecordingDependencies {
#if DEBUG
        CameraRecordingDependencies(
            permissions: SystemPermissionService(),
            capture: AVFoundationCaptureService(),
            files: try RecordingFileStore.production(),
            storage: try SystemStorageSpaceService.production(),
            photos: SystemPhotoLibraryService(),
            audio: SystemAudioSessionService(),
            storagePolicy: .production,
            countdownSeconds: 3,
            countdownStep: .seconds(1),
            isUITestFake: false
        )
#else
        CameraRecordingDependencies(
            permissions: SystemPermissionService(),
            capture: AVFoundationCaptureService(),
            files: try RecordingFileStore.production(),
            storage: try SystemStorageSpaceService.production(),
            photos: SystemPhotoLibraryService(),
            audio: SystemAudioSessionService(),
            storagePolicy: .production,
            countdownSeconds: 3,
            countdownStep: .seconds(1)
        )
#endif
    }

#if DEBUG
    static func uiTesting(
        arguments: [String]
    ) throws -> CameraRecordingDependencies {
        let mode = FakeCaptureMode(arguments: arguments)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TakeFlow-Capture-UITest-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        return CameraRecordingDependencies(
            permissions: FakePermissionService(mode: mode),
            capture: FakeCaptureSessionService(mode: mode),
            files: try RecordingFileStore(rootURL: directory),
            storage: FakeStorageSpaceService(
                availableBytes:
                    mode == .lowStorage ? 100 * 1_024 * 1_024 : Int64.max
            ),
            photos: FakePhotoLibraryService(),
            audio: FakeAudioSessionService(),
            storagePolicy: RecordingStoragePolicy(
                minimumStartBytes: 500 * 1_024 * 1_024,
                safeStopBytes: 250 * 1_024 * 1_024,
                checkInterval: .milliseconds(100)
            ),
            countdownSeconds: 3,
            countdownStep: .seconds(1),
            isUITestFake: true
        )
    }
#endif

    static func unavailable() -> CameraRecordingDependencies {
#if DEBUG
        CameraRecordingDependencies(
            permissions: UnavailableCapturePermissionService(),
            capture: UnavailableCaptureSessionService(),
            files: UnavailableRecordingFileStore(),
            storage: UnavailableStorageSpaceService(),
            photos: UnavailablePhotoLibraryService(),
            audio: UnavailableAudioSessionService(),
            storagePolicy: .production,
            countdownSeconds: 3,
            countdownStep: .seconds(1),
            isUITestFake: false
        )
#else
        CameraRecordingDependencies(
            permissions: UnavailableCapturePermissionService(),
            capture: UnavailableCaptureSessionService(),
            files: UnavailableRecordingFileStore(),
            storage: UnavailableStorageSpaceService(),
            photos: UnavailablePhotoLibraryService(),
            audio: UnavailableAudioSessionService(),
            storagePolicy: .production,
            countdownSeconds: 3,
            countdownStep: .seconds(1)
        )
#endif
    }
}

#if DEBUG
enum FakeCaptureMode: Equatable, Sendable {
    case allowed
    case cameraDenied
    case microphoneDenied
    case interrupted
    case lowStorage

    init(arguments: [String]) {
        if arguments.contains("-ui-testing-camera-denied") {
            self = .cameraDenied
        } else if arguments.contains("-ui-testing-microphone-denied") {
            self = .microphoneDenied
        } else if arguments.contains("-ui-testing-capture-interrupted") {
            self = .interrupted
        } else if arguments.contains("-ui-testing-low-storage") {
            self = .lowStorage
        } else {
            self = .allowed
        }
    }
}

@MainActor
final class FakePermissionService: PermissionAuthorizing {
    private let mode: FakeCaptureMode

    init(mode: FakeCaptureMode) {
        self.mode = mode
    }

    func status(for permission: PermissionKind) -> PermissionState {
        switch (mode, permission) {
        case (.cameraDenied, .camera):
            .denied
        case (.microphoneDenied, .microphone):
            .denied
        default:
            .authorized
        }
    }

    func request(_ permission: PermissionKind) async -> PermissionState {
        status(for: permission)
    }
}

actor FakeCaptureSessionService: CaptureSessionServicing {
    private let mode: FakeCaptureMode
    private let stream: AsyncStream<CaptureSessionEvent>
    private let continuation: AsyncStream<CaptureSessionEvent>.Continuation
    private var configuration: CaptureConfiguration?
    private var activeRecording: (id: UUID, url: URL)?
    private var lockedRotationAngle: Double?

    init(mode: FakeCaptureMode) {
        self.mode = mode
        let pair = AsyncStream<CaptureSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func events() async -> AsyncStream<CaptureSessionEvent> {
        stream
    }

    func configure(
        position: CameraPosition,
        preferredResolution: VideoResolution
    ) async throws {
        let format = CaptureFormatOption(
            resolution: preferredResolution,
            framesPerSecond: 30,
            codec:
                preferredResolution == .ultraHD4K ? .hevc : .h264
        )
        let configuration = CaptureConfiguration(
            position: position,
            format: format,
            previewMirrored: position == .front,
            outputMirrored: false
        )
        self.configuration = configuration
        continuation.yield(
            .sessionReady(
                source: nil,
                configuration: configuration,
                capabilities: CaptureCapabilities(
                    availableFormats: [
                        CaptureFormatOption(
                            resolution: .fullHD1080p,
                            framesPerSecond: 30,
                            codec: .h264
                        ),
                        CaptureFormatOption(
                            resolution: .ultraHD4K,
                            framesPerSecond: 30,
                            codec: .hevc
                        )
                    ],
                    supportsFocusPoint: true,
                    supportsExposurePoint: true,
                    supportsFocusLock: true,
                    supportsExposureLock: true,
                    supportsVideoStabilization: true
                )
            )
        )
    }

    func startPreview() async throws {}

    func stopPreview() async {}

    func switchCamera() async throws {
        guard activeRecording == nil else {
            throw CaptureError.cameraSwitchDuringRecording
        }
        let next: CameraPosition =
            configuration?.position == .front ? .back : .front
        try await configure(
            position: next,
            preferredResolution:
                configuration?.format.resolution ?? .fullHD1080p
        )
    }

    func startRecording(
        recordingID: UUID,
        outputURL: URL,
        rotationAngle: Double
    ) async throws {
        guard activeRecording == nil else {
            throw CaptureError.alreadyRecording
        }
        try Data("TakeFlow UI test capture".utf8).write(
            to: outputURL,
            options: .atomic
        )
        activeRecording = (recordingID, outputURL)
        lockedRotationAngle = rotationAngle
        continuation.yield(.duration(recordingID: recordingID, seconds: 0))

        if mode == .interrupted {
            Task {
                try? await Task.sleep(for: .seconds(3))
                interruptForUITest(recordingID: recordingID)
            }
        }
    }

    func stopRecording(recordingID: UUID) async throws {
        guard let activeRecording else {
            throw CaptureError.notRecording
        }
        guard activeRecording.id == recordingID else {
            throw CaptureError.staleCallback
        }
        self.activeRecording = nil
        continuation.yield(
            .recordingFinished(
                recordingID: recordingID,
                outputURL: activeRecording.url,
                duration: 1
            )
        )
    }

    func setFocusAndExposure(
        at point: NormalizedCapturePoint,
        locked: Bool
    ) async throws {}

    func handleApplicationBackgrounded() async {
        guard let activeRecording else {
            return
        }
        self.activeRecording = nil
        continuation.yield(
            .interrupted(
                recordingID: activeRecording.id,
                reason: .applicationBackgrounded,
                outputURL: activeRecording.url
            )
        )
        continuation.yield(
            .recordingFinished(
                recordingID: activeRecording.id,
                outputURL: activeRecording.url,
                duration: 1
            )
        )
    }

    func handleApplicationForegrounded() async {}

    func capturedRotationAngleForTesting() -> Double? {
        lockedRotationAngle
    }

    private func interruptForUITest(recordingID: UUID) {
        guard let activeRecording, activeRecording.id == recordingID else {
            return
        }
        self.activeRecording = nil
        continuation.yield(
            .interrupted(
                recordingID: recordingID,
                reason: .cameraUnavailable,
                outputURL: activeRecording.url
            )
        )
        continuation.yield(
            .recordingFinished(
                recordingID: recordingID,
                outputURL: activeRecording.url,
                duration: 1
            )
        )
    }
}

struct FakeStorageSpaceService: StorageSpaceChecking {
    let availableBytes: Int64

    func availableCapacityForImportantUsage() async throws -> Int64 {
        availableBytes
    }
}

struct FakePhotoLibraryService: PhotoLibrarySaving {
    func authorizationStatus() async -> PermissionState {
        .authorized
    }

    func saveVideo(at url: URL) async -> PhotoSaveResult {
        .saved
    }
}

struct FakeAudioSessionService: AudioSessionServicing {
    func currentInputRoute() async -> AudioInputRoute {
        AudioInputRoute(
            name: "UI 测试麦克风",
            isBluetooth: false,
            isAvailable: true
        )
    }

    func activateForRecording() async throws {}

    func deactivateAfterRecording() async {}

    func events() async -> AsyncStream<AudioSessionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
#endif

@MainActor
private final class UnavailableCapturePermissionService:
    PermissionAuthorizing
{
    func status(for permission: PermissionKind) -> PermissionState {
        .unavailable
    }

    func request(_ permission: PermissionKind) async -> PermissionState {
        .unavailable
    }
}

private actor UnavailableCaptureSessionService: CaptureSessionServicing {
    func events() async -> AsyncStream<CaptureSessionEvent> {
        AsyncStream { $0.finish() }
    }

    func configure(
        position: CameraPosition,
        preferredResolution: VideoResolution
    ) async throws {
        throw CaptureError.cameraUnavailable
    }

    func startPreview() async throws {
        throw CaptureError.cameraUnavailable
    }

    func stopPreview() async {}

    func switchCamera() async throws {
        throw CaptureError.cameraUnavailable
    }

    func startRecording(
        recordingID: UUID,
        outputURL: URL,
        rotationAngle: Double
    ) async throws {
        throw CaptureError.cameraUnavailable
    }

    func stopRecording(recordingID: UUID) async throws {
        throw CaptureError.notRecording
    }

    func setFocusAndExposure(
        at point: NormalizedCapturePoint,
        locked: Bool
    ) async throws {
        throw CaptureError.cameraUnavailable
    }

    func handleApplicationBackgrounded() async {}

    func handleApplicationForegrounded() async {}
}

private struct UnavailableRecordingFileStore: RecordingFileStoring {
    func createRecording(
        scriptID: UUID,
        orientation: CaptureOrientation,
        resolution: VideoResolution
    ) async throws -> PendingRecording {
        throw CaptureError.filePreparationFailed
    }

    func markRecordingStarted(_ recording: PendingRecording) async throws {
        throw CaptureError.filePreparationFailed
    }

    func completeRecording(
        _ recording: PendingRecording,
        duration: TimeInterval
    ) async throws -> CompletedRecording {
        throw CaptureError.fileFinalizationFailed
    }

    func preserveRecoverableRecording(
        _ recording: PendingRecording,
        reason: CaptureInterruptionReason
    ) async throws -> RecoverableRecording {
        throw CaptureError.fileFinalizationFailed
    }

    func recoverPendingRecordings() async -> [RecoverableRecording] {
        []
    }

    func deleteProject(projectID: UUID) async throws {}
}

private struct UnavailableStorageSpaceService: StorageSpaceChecking {
    func availableCapacityForImportantUsage() async throws -> Int64 {
        throw CaptureError.storageSpaceInsufficient
    }
}

private struct UnavailablePhotoLibraryService: PhotoLibrarySaving {
    func authorizationStatus() async -> PermissionState {
        .unavailable
    }

    func saveVideo(at url: URL) async -> PhotoSaveResult {
        .failed
    }
}

private struct UnavailableAudioSessionService: AudioSessionServicing {
    func currentInputRoute() async -> AudioInputRoute {
        .unavailable
    }

    func activateForRecording() async throws {
        throw CaptureError.microphoneUnavailable
    }

    func deactivateAfterRecording() async {}

    func events() async -> AsyncStream<AudioSessionEvent> {
        AsyncStream { $0.finish() }
    }
}

import Foundation
import UIKit

@MainActor
struct CameraRecordingDependencies {
    let permissions: any PermissionAuthorizing
    let capture: any CaptureSessionServicing
    let files: any RecordingFileStoring
    let recoverableMediaValidator: any RecoverableMediaValidating
    let storage: any StorageSpaceChecking
    let photos: any PhotoLibrarySaving
    let audio: any AudioSessionServicing
    let backgroundTasks: any RecordingBackgroundTaskManaging
    let storagePolicy: RecordingStoragePolicy
    let countdownSeconds: Int
    let countdownStep: Duration
    let preparationTimeout: Duration
    let recordingStartTimeout: Duration
#if DEBUG
    let isUITestFake: Bool
#endif

    static func production() throws -> CameraRecordingDependencies {
#if DEBUG
        CameraRecordingDependencies(
            permissions: SystemPermissionService(),
            capture: AVFoundationCaptureService(),
            files: try RecordingFileStore.production(),
            recoverableMediaValidator:
                AVFoundationRecoverableMediaValidator(),
            storage: try SystemStorageSpaceService.production(),
            photos: SystemPhotoLibraryService(),
            audio: SystemAudioSessionService(),
            backgroundTasks: ApplicationRecordingBackgroundTaskManager(),
            storagePolicy: .production,
            countdownSeconds: 3,
            countdownStep: .seconds(1),
            preparationTimeout: .seconds(12),
            recordingStartTimeout: .seconds(8),
            isUITestFake: false
        )
#else
        CameraRecordingDependencies(
            permissions: SystemPermissionService(),
            capture: AVFoundationCaptureService(),
            files: try RecordingFileStore.production(),
            recoverableMediaValidator:
                AVFoundationRecoverableMediaValidator(),
            storage: try SystemStorageSpaceService.production(),
            photos: SystemPhotoLibraryService(),
            audio: SystemAudioSessionService(),
            backgroundTasks: ApplicationRecordingBackgroundTaskManager(),
            storagePolicy: .production,
            countdownSeconds: 3,
            countdownStep: .seconds(1),
            preparationTimeout: .seconds(12),
            recordingStartTimeout: .seconds(8)
        )
#endif
    }

#if DEBUG
    static func uiTesting(
        arguments: [String]
    ) throws -> CameraRecordingDependencies {
        let mode = FakeCaptureMode(arguments: arguments)
        let skipsRecordingCountdown = arguments.contains(
            "-ui-testing-capture-skip-countdown"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TakeFlow-Capture-UITest-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        return CameraRecordingDependencies(
            permissions: FakePermissionService(mode: mode),
            capture: FakeCaptureSessionService(mode: mode),
            files: try RecordingFileStore(rootURL: directory),
            recoverableMediaValidator: FakeRecoverableMediaValidator(),
            storage: FakeStorageSpaceService(
                availableBytes:
                    mode == .lowStorage ? 100 * 1_024 * 1_024 : Int64.max
            ),
            photos: FakePhotoLibraryService(),
            audio: FakeAudioSessionService(),
            backgroundTasks: ApplicationRecordingBackgroundTaskManager(),
            storagePolicy: RecordingStoragePolicy(
                minimumStartBytes: 500 * 1_024 * 1_024,
                safeStopBytes: 250 * 1_024 * 1_024,
                checkInterval: .milliseconds(100)
            ),
            countdownSeconds: skipsRecordingCountdown ? 1 : 3,
            countdownStep:
                skipsRecordingCountdown ? .zero : .seconds(1),
            preparationTimeout:
                mode == .preparationTimesOutOnce
                ? .milliseconds(250) : .seconds(12),
            recordingStartTimeout: .seconds(8),
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
            recoverableMediaValidator:
                UnavailableRecoverableMediaValidator(),
            storage: UnavailableStorageSpaceService(),
            photos: UnavailablePhotoLibraryService(),
            audio: UnavailableAudioSessionService(),
            backgroundTasks: UnavailableRecordingBackgroundTaskManager(),
            storagePolicy: .production,
            countdownSeconds: 3,
            countdownStep: .seconds(1),
            preparationTimeout: .seconds(12),
            recordingStartTimeout: .seconds(8),
            isUITestFake: false
        )
#else
        CameraRecordingDependencies(
            permissions: UnavailableCapturePermissionService(),
            capture: UnavailableCaptureSessionService(),
            files: UnavailableRecordingFileStore(),
            recoverableMediaValidator:
                UnavailableRecoverableMediaValidator(),
            storage: UnavailableStorageSpaceService(),
            photos: UnavailablePhotoLibraryService(),
            audio: UnavailableAudioSessionService(),
            backgroundTasks: UnavailableRecordingBackgroundTaskManager(),
            storagePolicy: .production,
            countdownSeconds: 3,
            countdownStep: .seconds(1),
            preparationTimeout: .seconds(12),
            recordingStartTimeout: .seconds(8)
        )
#endif
    }
}

@MainActor
private final class ApplicationRecordingBackgroundTaskManager:
    RecordingBackgroundTaskManaging
{
    private var identifiers:
        [RecordingBackgroundTaskToken: UIBackgroundTaskIdentifier] = [:]

    func beginRecordingFinalization(
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> RecordingBackgroundTaskToken? {
        let token = RecordingBackgroundTaskToken()
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "TakeFlowRecordingFinalization"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    expirationHandler()
                    return
                }
                self.expire(token, expirationHandler: expirationHandler)
            }
        }
        guard identifier != .invalid else {
            return nil
        }
        identifiers[token] = identifier
        return token
    }

    func endRecordingFinalization(_ token: RecordingBackgroundTaskToken) {
        guard let identifier = identifiers.removeValue(forKey: token) else {
            return
        }
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func expire(
        _ token: RecordingBackgroundTaskToken,
        expirationHandler: @MainActor @Sendable () -> Void
    ) {
        endRecordingFinalization(token)
        expirationHandler()
    }
}

@MainActor
private final class UnavailableRecordingBackgroundTaskManager:
    RecordingBackgroundTaskManaging
{
    func beginRecordingFinalization(
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> RecordingBackgroundTaskToken? {
        nil
    }

    func endRecordingFinalization(_ token: RecordingBackgroundTaskToken) {}
}

#if DEBUG
protocol CaptureSessionUITestControlling: Sendable {
    func triggerInterruptionAndEndForUITesting() async -> Bool
}

enum FakeCaptureMode: Equatable, Sendable {
    case allowed
    case cameraDenied
    case microphoneDenied
    case interrupted
    case lowStorage
    case preparationTimesOutOnce
    case interruptionEnds

    init(arguments: [String]) {
        if arguments.contains("-ui-testing-capture-interruption-ends") {
            self = .interruptionEnds
        } else if arguments.contains("-ui-testing-capture-timeout-once") {
            self = .preparationTimesOutOnce
        } else if arguments.contains("-ui-testing-camera-denied") {
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

actor FakeCaptureSessionService:
    CaptureSessionServicing,
    CaptureSessionUITestControlling
{
    private let mode: FakeCaptureMode
    private var continuations:
        [UUID: AsyncStream<CaptureSessionEvent>.Continuation] = [:]
    private var activeSessionID: UUID?
    private var configuration: CaptureConfiguration?
    private var activeRecording: (id: UUID, url: URL, sessionID: UUID)?
    private var lockedRotationAngle: Double?
    private var previewStartCount = 0

    init(mode: FakeCaptureMode) {
        self.mode = mode
    }

    func events(
        for sessionID: UUID
    ) async -> AsyncStream<CaptureSessionEvent> {
        let pair = AsyncStream<CaptureSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        continuations.removeValue(forKey: sessionID)?.finish()
        continuations[sessionID] = pair.continuation
        return pair.stream
    }

    func configure(
        sessionID: UUID,
        position: CameraPosition,
        preferredResolution: VideoResolution
    ) async throws {
        guard activeRecording == nil else {
            throw CaptureError.alreadyRecording
        }
        if let previousSessionID = activeSessionID,
           previousSessionID != sessionID {
            continuations.removeValue(forKey: previousSessionID)?.finish()
        }
        activeSessionID = sessionID
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
    }

    func startPreview(sessionID: UUID) async throws {
        guard
            activeSessionID == sessionID,
            let configuration
        else {
            throw CaptureError.staleCallback
        }
        previewStartCount += 1
        if
            mode == .preparationTimesOutOnce,
            previewStartCount == 1
        {
            return
        }
        continuations[sessionID]?.yield(
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
                    supportsContinuousFocus: true,
                    supportsContinuousExposure: true,
                    supportsVideoStabilization: true
                )
            )
        )
    }

    func stopPreview(sessionID: UUID) async {
        guard activeSessionID == sessionID else {
            continuations.removeValue(forKey: sessionID)?.finish()
            return
        }
        if activeRecording != nil {
            return
        }
        activeSessionID = nil
        configuration = nil
        continuations.removeValue(forKey: sessionID)?.finish()
    }

    func switchCamera(sessionID: UUID) async throws {
        guard activeSessionID == sessionID else {
            throw CaptureError.staleCallback
        }
        guard activeRecording == nil else {
            throw CaptureError.cameraSwitchDuringRecording
        }
        let next: CameraPosition =
            configuration?.position == .front ? .back : .front
        try await configure(
            sessionID: sessionID,
            position: next,
            preferredResolution:
                configuration?.format.resolution ?? .fullHD1080p
        )
        guard let configuration else {
            throw CaptureError.cameraUnavailable
        }
        continuations[sessionID]?.yield(
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
                    supportsContinuousFocus: true,
                    supportsContinuousExposure: true,
                    supportsVideoStabilization: true
                )
            )
        )
    }

    func startRecording(
        sessionID: UUID,
        recordingID: UUID,
        outputURL: URL,
        rotationAngle: Double
    ) async throws {
        guard activeSessionID == sessionID else {
            throw CaptureError.staleCallback
        }
        guard activeRecording == nil else {
            throw CaptureError.alreadyRecording
        }
        try Data("TakeFlow UI test capture".utf8).write(
            to: outputURL,
            options: .atomic
        )
        activeRecording = (recordingID, outputURL, sessionID)
        lockedRotationAngle = rotationAngle
        continuations[sessionID]?.yield(
            .recordingStarted(recordingID: recordingID)
        )
        continuations[sessionID]?.yield(
            .duration(recordingID: recordingID, seconds: 0)
        )

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
        continuations[activeRecording.sessionID]?.yield(
            .recordingFinished(
                recordingID: recordingID,
                outputURL: activeRecording.url,
                duration: 1
            )
        )
    }

    func setFocusAndExposurePoint(
        sessionID: UUID,
        at point: NormalizedCapturePoint
    ) async throws -> CapturePointAdjustmentResult {
        guard activeSessionID == sessionID else {
            throw CaptureError.staleCallback
        }
        return CapturePointAdjustmentResult(
            focusApplied: true,
            exposureApplied: true
        )
    }

    func setFocusAndExposureLocked(
        sessionID: UUID,
        locked: Bool
    ) async throws -> CaptureFocusExposureLockState {
        guard activeSessionID == sessionID else {
            throw CaptureError.staleCallback
        }
        return CaptureFocusExposureLockState(
            focusLocked: locked,
            exposureLocked: locked
        )
    }

    func handleApplicationBackgrounded(sessionID: UUID) async {
        guard activeSessionID == sessionID else {
            return
        }
        guard let activeRecording else {
            return
        }
        self.activeRecording = nil
        continuations[sessionID]?.yield(
            .interrupted(
                recordingID: activeRecording.id,
                reason: .applicationBackgrounded,
                outputURL: activeRecording.url
            )
        )
        continuations[sessionID]?.yield(
            .recordingFinished(
                recordingID: activeRecording.id,
                outputURL: activeRecording.url,
                duration: 1
            )
        )
    }

    func handleApplicationForegrounded(sessionID: UUID) async {}

    func capturedRotationAngleForTesting() -> Double? {
        lockedRotationAngle
    }

    func triggerInterruptionAndEndForUITesting() async -> Bool {
        guard
            mode == .interruptionEnds,
            let activeRecording
        else {
            return false
        }
        interruptForUITest(recordingID: activeRecording.id)
        return true
    }

    private func interruptForUITest(recordingID: UUID) {
        guard let activeRecording, activeRecording.id == recordingID else {
            return
        }
        self.activeRecording = nil
        continuations[activeRecording.sessionID]?.yield(
            .interrupted(
                recordingID: recordingID,
                reason: .cameraUnavailable,
                outputURL: activeRecording.url
            )
        )
        continuations[activeRecording.sessionID]?.yield(
            .recordingFinished(
                recordingID: recordingID,
                outputURL: activeRecording.url,
                duration: 1
            )
        )
        if mode == .interruptionEnds {
            continuations[activeRecording.sessionID]?.yield(
                .interruptionEnded(reason: .cameraUnavailable)
            )
        }
    }
}

struct FakeStorageSpaceService: StorageSpaceChecking {
    let availableBytes: Int64

    func availableCapacityForImportantUsage() async throws -> Int64 {
        availableBytes
    }
}

struct FakeRecoverableMediaValidator: RecoverableMediaValidating {
    func validate(
        _ recording: RecoverableRecording
    ) async -> RecoverableMediaValidationResult {
        .playable(
            RecoverableMediaInfo(duration: 1, hasAudioTrack: true)
        )
    }
}

actor FakePhotoLibraryService: PhotoLibrarySaving {
    private var pendingContinuations:
        [
            (
                id: UUID,
                continuation:
                    CheckedContinuation<PhotoSaveResult, Never>
            )
        ] = []
    private var queuedResults: [PhotoSaveResult] = []

    func authorizationStatus() async -> PermissionState {
        .authorized
    }

    func saveVideo(at url: URL) async -> PhotoSaveResult {
        if !queuedResults.isEmpty {
            return queuedResults.removeFirst()
        }
        let operationID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failed)
                    return
                }
                pendingContinuations.append(
                    (operationID, continuation)
                )
            }
        } onCancel: {
            Task {
                await self.cancelSave(operationID: operationID)
            }
        }
    }

    func completeNextSave(with result: PhotoSaveResult) {
        guard !pendingContinuations.isEmpty else {
            queuedResults.append(result)
            return
        }
        pendingContinuations.removeFirst().continuation.resume(
            returning: result
        )
    }

    private func cancelSave(operationID: UUID) {
        guard
            let index = pendingContinuations.firstIndex(
                where: { $0.id == operationID }
            )
        else {
            return
        }
        pendingContinuations.remove(at: index).continuation.resume(
            returning: .failed
        )
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
    func events(
        for sessionID: UUID
    ) async -> AsyncStream<CaptureSessionEvent> {
        AsyncStream { $0.finish() }
    }

    func configure(
        sessionID: UUID,
        position: CameraPosition,
        preferredResolution: VideoResolution
    ) async throws {
        throw CaptureError.cameraUnavailable
    }

    func startPreview(sessionID: UUID) async throws {
        throw CaptureError.cameraUnavailable
    }

    func stopPreview(sessionID: UUID) async {}

    func switchCamera(sessionID: UUID) async throws {
        throw CaptureError.cameraUnavailable
    }

    func startRecording(
        sessionID: UUID,
        recordingID: UUID,
        outputURL: URL,
        rotationAngle: Double
    ) async throws {
        throw CaptureError.cameraUnavailable
    }

    func stopRecording(recordingID: UUID) async throws {
        throw CaptureError.notRecording
    }

    func setFocusAndExposurePoint(
        sessionID: UUID,
        at point: NormalizedCapturePoint
    ) async throws -> CapturePointAdjustmentResult {
        throw CaptureError.cameraUnavailable
    }

    func setFocusAndExposureLocked(
        sessionID: UUID,
        locked: Bool
    ) async throws -> CaptureFocusExposureLockState {
        throw CaptureError.cameraUnavailable
    }

    func handleApplicationBackgrounded(sessionID: UUID) async {}

    func handleApplicationForegrounded(sessionID: UUID) async {}
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

    func recoverCommittedRecordings() async -> [RecoverableRecording] {
        []
    }

    func retainRecoverableRecording(
        _ recording: RecoverableRecording,
        duration: TimeInterval
    ) async throws -> CompletedRecording {
        throw CaptureError.fileFinalizationFailed
    }

    func markRecoverableRecordingDamaged(
        _ recording: RecoverableRecording
    ) async throws -> RecoverableRecording {
        throw CaptureError.fileFinalizationFailed
    }

    func deleteRecoverableRecording(
        projectID: UUID,
        recordingID: UUID
    ) async throws {
        throw CaptureError.fileFinalizationFailed
    }

    func deleteProject(projectID: UUID) async throws {}
}

private struct UnavailableRecoverableMediaValidator:
    RecoverableMediaValidating
{
    func validate(
        _ recording: RecoverableRecording
    ) async -> RecoverableMediaValidationResult {
        .invalid(.fileMissing)
    }
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

import Foundation
import XCTest
@testable import TakeFlow

@MainActor
final class CameraRecordingViewModelTests: XCTestCase {
    func testAuthorizedPermissionsConfigureReadyPreview() async throws {
        let fixture = makeFixture()
        let viewModel = fixture.viewModel

        await viewModel.prepare()
        try await waitUntil { viewModel.state == .ready }

        XCTAssertEqual(
            viewModel.configuration?.format.resolution,
            .fullHD1080p
        )
        XCTAssertEqual(viewModel.configuration?.format.framesPerSecond, 30)
        XCTAssertTrue(
            viewModel.configuration?.previewMirrored == true
        )
        XCTAssertTrue(
            viewModel.configuration?.outputMirrored == false
        )
    }

    func testNotDeterminedPermissionsAreRequestedOnce() async throws {
        let permissions = TestCapturePermissions(
            camera: .notDetermined,
            microphone: .notDetermined,
            requestResults: [
                .camera: .authorized,
                .microphone: .authorized
            ]
        )
        let fixture = makeFixture(permissions: permissions)

        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        XCTAssertEqual(permissions.requested, [.camera, .microphone])
    }

    func testDeniedCameraDoesNotRepeatPermissionPrompt() async {
        let permissions = TestCapturePermissions(
            camera: .denied,
            microphone: .authorized
        )
        let fixture = makeFixture(permissions: permissions)

        await fixture.viewModel.prepare()
        await fixture.viewModel.prepare()

        XCTAssertEqual(permissions.requested, [])
        XCTAssertEqual(
            fixture.viewModel.state,
            .failed(.permissionDenied(.camera))
        )
    }

    func testRestrictedCameraFailsUnderstandably() async {
        let fixture = makeFixture(
            permissions: TestCapturePermissions(
                camera: .restricted,
                microphone: .authorized
            )
        )

        await fixture.viewModel.prepare()

        XCTAssertEqual(
            fixture.viewModel.state,
            .failed(.permissionRestricted(.camera))
        )
        XCTAssertNotNil(fixture.viewModel.errorMessage)
    }

    func testUnavailableCameraFailsWithoutConfiguringCapture() async {
        let capture = TestCaptureSession()
        let fixture = makeFixture(
            permissions: TestCapturePermissions(
                camera: .unavailable,
                microphone: .authorized
            ),
            capture: capture
        )

        await fixture.viewModel.prepare()

        XCTAssertEqual(
            fixture.viewModel.state,
            .failed(.permissionUnavailable(.camera))
        )
        let configureCount = await capture.configureCount
        XCTAssertEqual(configureCount, 0)
    }

    func testDeniedMicrophoneDoesNotStartSilentVideo() async {
        let capture = TestCaptureSession()
        let fixture = makeFixture(
            permissions: TestCapturePermissions(
                camera: .authorized,
                microphone: .denied
            ),
            capture: capture
        )

        await fixture.viewModel.prepare()

        XCTAssertEqual(
            fixture.viewModel.state,
            .failed(.permissionDenied(.microphone))
        )
        let startRecordingCount = await capture.startRecordingCount
        XCTAssertEqual(startRecordingCount, 0)
    }

    func testNotDeterminedMicrophoneIsRequestedAndCanBecomeReady()
        async throws
    {
        let permissions = TestCapturePermissions(
            camera: .authorized,
            microphone: .notDetermined,
            requestResults: [.microphone: .authorized]
        )
        let fixture = makeFixture(permissions: permissions)

        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        XCTAssertEqual(permissions.requested, [.microphone])
    }

    func testRestrictedMicrophoneFailsBeforeCaptureConfiguration()
        async
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(
            permissions: TestCapturePermissions(
                camera: .authorized,
                microphone: .restricted
            ),
            capture: capture
        )

        await fixture.viewModel.prepare()

        XCTAssertEqual(
            fixture.viewModel.state,
            .failed(.permissionRestricted(.microphone))
        )
        let configureCount = await capture.configureCount
        XCTAssertEqual(configureCount, 0)
    }

    func testLowStorageBlocksRecordingBeforeFileCreation() async throws {
        let files = TestRecordingFileStore()
        let fixture = makeFixture(
            files: files,
            storage: TestStorageSpace(
                capacities: [Int64(100 * 1_024 * 1_024)]
            )
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        fixture.viewModel.startRecording()
        try await waitUntil {
            fixture.viewModel.state
                == .failed(.storageSpaceInsufficient)
        }

        let createCount = await files.createCount
        XCTAssertEqual(createCount, 0)
        XCTAssertTrue(
            fixture.viewModel.errorMessage?.contains("存储空间不足")
                == true
        )
    }

    func testCountdownRecordingStopAndFinishCompletesExactlyOnce()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        let fixture = makeFixture(capture: capture, files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )
        fixture.viewModel.stopRecording()
        fixture.viewModel.stopRecording()
        try await waitUntil { await capture.stopRecordingCount == 1 }
        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            if case .finished = fixture.viewModel.state {
                return true
            }
            return false
        }

        let stopRecordingCount = await capture.stopRecordingCount
        let completeCount = await files.completeCount
        XCTAssertEqual(stopRecordingCount, 1)
        XCTAssertEqual(completeCount, 1)
        XCTAssertNotNil(fixture.viewModel.completedRecording)
    }

    func testCameraSwitchIsDisabledWhileRecording() async throws {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        try await waitUntil {
            if case .recording = fixture.viewModel.state {
                return true
            }
            return false
        }

        XCTAssertFalse(fixture.viewModel.canSwitchCamera)
        fixture.viewModel.switchCamera()
        try? await Task.sleep(for: .milliseconds(20))
        let switchCount = await capture.switchCount
        XCTAssertEqual(switchCount, 0)
    }

    func testInterruptionPreservesRecoverableFile() async throws {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        let fixture = makeFixture(capture: capture, files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        await capture.interrupt(
            recordingID: recordingID,
            reason: .cameraUnavailable
        )
        try await waitUntil {
            if case .interrupted = fixture.viewModel.state {
                return true
            }
            return false
        }
        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel.recoverableRecording != nil
        }

        let preserveCount = await files.preserveCount
        XCTAssertEqual(preserveCount, 1)
        XCTAssertNil(fixture.viewModel.completedRecording)
    }

    func testBackgroundStopsAndForegroundDoesNotAutoResume()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        _ = try await waitForRecordingID(viewModel: fixture.viewModel)

        fixture.viewModel.sceneDidEnterBackground()
        try await waitUntil { await capture.backgroundCount == 1 }
        fixture.viewModel.sceneDidBecomeActive()
        try await waitUntil { await capture.foregroundCount == 1 }

        let startRecordingCount = await capture.startRecordingCount
        XCTAssertEqual(startRecordingCount, 1)
        XCTAssertNotEqual(fixture.viewModel.state, .ready)
    }

    func testOldDelegateCallbackCannotPolluteActiveRecording()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let activeID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        await capture.finish(recordingID: UUID())
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(
            fixture.viewModel.state,
            .recording(recordingID: activeID)
        )
        XCTAssertNil(fixture.viewModel.completedRecording)
    }

    func testRecordingRotationAngleIsLockedAtStart() async throws {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.setCaptureRotationAngle(90)
        fixture.viewModel.startRecording()
        _ = try await waitForRecordingID(viewModel: fixture.viewModel)
        fixture.viewModel.setCaptureRotationAngle(0)

        let rotationAngle = await capture.lastStartRotationAngle
        XCTAssertEqual(rotationAngle, 90)
        XCTAssertEqual(fixture.viewModel.captureRotationAngle, 90)
    }

    func testOngoingStorageDropStopsAndPreservesRecording()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        let storage = TestStorageSpace(
            capacities: [
                Int64(1_000 * 1_024 * 1_024),
                Int64(100 * 1_024 * 1_024)
            ]
        )
        let fixture = makeFixture(
            capture: capture,
            files: files,
            storage: storage
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let id = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )
        try await waitUntil { await capture.stopRecordingCount == 1 }
        await capture.finish(recordingID: id)
        try await waitUntil {
            fixture.viewModel.recoverableRecording != nil
        }

        XCTAssertTrue(
            fixture.viewModel.noticeMessage?.contains("存储空间不足")
                == true
        )
    }

    func testUnsupported4KIsNotOffered() async throws {
        let capture = TestCaptureSession(
            availableFormats: [
                CaptureFormatOption(
                    resolution: .fullHD1080p,
                    framesPerSecond: 30,
                    codec: .h264
                )
            ]
        )
        let fixture = makeFixture(capture: capture)

        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        XCTAssertFalse(
            fixture.viewModel.capabilities.availableFormats.contains {
                $0.resolution == .ultraHD4K
            }
        )
        fixture.viewModel.selectResolution(.ultraHD4K)
        let configureCount = await capture.configureCount
        XCTAssertEqual(configureCount, 1)
    }

    func testUnsupportedFocusAndExposureIsHandledSafely()
        async throws
    {
        let capture = TestCaptureSession(focusError: .focusUnsupported)
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        fixture.viewModel.focus(at: NormalizedCapturePoint(x: 0.5, y: 0.5))
        try await waitUntil {
            fixture.viewModel.errorMessage?.contains("不支持点击对焦")
                == true
        }
    }

    func testAudioRouteChangeIsVisibleAndInterruptionStopsRecording()
        async throws
    {
        let audio = TestAudioSession()
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture, audio: audio)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        let bluetoothRoute = AudioInputRoute(
            name: "蓝牙麦克风",
            isBluetooth: true,
            isAvailable: true
        )
        await audio.emit(.routeChanged(bluetoothRoute))
        try await waitUntil {
            fixture.viewModel.audioRoute == bluetoothRoute
        }

        fixture.viewModel.startRecording()
        _ = try await waitForRecordingID(viewModel: fixture.viewModel)
        await audio.emit(.interruptionBegan)
        try await waitUntil {
            if case .interrupted(
                _,
                .audioSessionInterrupted
            ) = fixture.viewModel.state {
                return true
            }
            return false
        }
        try await waitUntil { await capture.stopRecordingCount == 1 }
    }

    func testPhotoSaveSuccessIsReported() async throws {
        let fixture = makeFixture(
            photos: TestPhotoLibrary(result: .saved)
        )
        try await finishOneRecording(
            in: fixture.viewModel,
            capture: fixture.capture
        )

        fixture.viewModel.saveToPhotos()
        try await waitUntil {
            fixture.viewModel.noticeMessage
                == CameraRecordingStrings.savedToPhotos
        }
    }

    func testPhotoPermissionDenialKeepsCompletedFileForSharing()
        async throws
    {
        let fixture = makeFixture(
            photos: TestPhotoLibrary(result: .permissionDenied)
        )
        try await finishOneRecording(
            in: fixture.viewModel,
            capture: fixture.capture
        )
        let completed = fixture.viewModel.completedRecording

        fixture.viewModel.saveToPhotos()
        try await waitUntil {
            fixture.viewModel.errorMessage?.contains("仍保留在 App 内")
                == true
        }

        XCTAssertEqual(fixture.viewModel.completedRecording, completed)
    }

    func testPhotoSaveFailureKeepsCompletedFile() async throws {
        let fixture = makeFixture(
            photos: TestPhotoLibrary(result: .failed)
        )
        try await finishOneRecording(
            in: fixture.viewModel,
            capture: fixture.capture
        )
        let completed = fixture.viewModel.completedRecording

        fixture.viewModel.saveToPhotos()
        try await waitUntil {
            fixture.viewModel.errorMessage?.contains("仍可从 App 内分享")
                == true
        }

        XCTAssertEqual(fixture.viewModel.completedRecording, completed)
    }

    private func makeFixture(
        permissions: TestCapturePermissions = TestCapturePermissions(),
        capture: TestCaptureSession = TestCaptureSession(),
        files: TestRecordingFileStore = TestRecordingFileStore(),
        storage: TestStorageSpace = TestStorageSpace(
            capacities: [Int64.max]
        ),
        photos: TestPhotoLibrary = TestPhotoLibrary(result: .saved),
        audio: TestAudioSession = TestAudioSession()
    ) -> (
        viewModel: CameraRecordingViewModel,
        capture: TestCaptureSession,
        files: TestRecordingFileStore
    ) {
        let dependencies = CameraRecordingDependencies(
            permissions: permissions,
            capture: capture,
            files: files,
            storage: storage,
            photos: photos,
            audio: audio,
            storagePolicy: RecordingStoragePolicy(
                minimumStartBytes: 500 * 1_024 * 1_024,
                safeStopBytes: 250 * 1_024 * 1_024,
                checkInterval: .milliseconds(5)
            ),
            countdownSeconds: 1,
            countdownStep: .milliseconds(5),
            isUITestFake: true
        )
        return (
            CameraRecordingViewModel(
                scriptID: UUID(),
                dependencies: dependencies
            ),
            capture,
            files
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for condition")
    }

    private func waitForRecordingID(
        viewModel: CameraRecordingViewModel
    ) async throws -> UUID {
        var result: UUID?
        try await waitUntil {
            if case .recording(let id) = viewModel.state {
                result = id
                return true
            }
            return false
        }
        return try XCTUnwrap(result)
    }

    private func finishOneRecording(
        in viewModel: CameraRecordingViewModel,
        capture: TestCaptureSession
    ) async throws {
        await viewModel.prepare()
        try await waitUntil { viewModel.state == .ready }
        viewModel.startRecording()
        let id = try await waitForRecordingID(viewModel: viewModel)
        viewModel.stopRecording()
        try await waitUntil {
            await capture.stopRecordingCount == 1
        }
        await capture.finish(recordingID: id)
        try await waitUntil {
            if case .finished = viewModel.state {
                return true
            }
            return false
        }
    }
}

@MainActor
private final class TestCapturePermissions: PermissionAuthorizing {
    private var states: [PermissionKind: PermissionState]
    private let requestResults: [PermissionKind: PermissionState]
    private(set) var requested: [PermissionKind] = []

    init(
        camera: PermissionState = .authorized,
        microphone: PermissionState = .authorized,
        requestResults: [PermissionKind: PermissionState] = [:]
    ) {
        states = [
            .camera: camera,
            .microphone: microphone,
            .photoLibraryAddOnly: .authorized
        ]
        self.requestResults = requestResults
    }

    func status(for permission: PermissionKind) -> PermissionState {
        states[permission] ?? .unavailable
    }

    func request(_ permission: PermissionKind) async -> PermissionState {
        requested.append(permission)
        let result = requestResults[permission] ?? .denied
        states[permission] = result
        return result
    }
}

private actor TestCaptureSession: CaptureSessionServicing {
    private let stream: AsyncStream<CaptureSessionEvent>
    private let continuation: AsyncStream<CaptureSessionEvent>.Continuation
    private let availableFormats: [CaptureFormatOption]
    private let focusError: CaptureError?
    private var active: (id: UUID, url: URL)?
    private(set) var configureCount = 0
    private(set) var startRecordingCount = 0
    private(set) var stopRecordingCount = 0
    private(set) var switchCount = 0
    private(set) var backgroundCount = 0
    private(set) var foregroundCount = 0
    private(set) var lastStartRotationAngle: Double?

    init(
        availableFormats: [CaptureFormatOption] = [
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
        focusError: CaptureError? = nil
    ) {
        self.availableFormats = availableFormats
        self.focusError = focusError
        let pair = AsyncStream<CaptureSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
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
        configureCount += 1
        let selected = availableFormats.first {
            $0.resolution == preferredResolution
        } ?? availableFormats[0]
        continuation.yield(
            .sessionReady(
                source: nil,
                configuration: CaptureConfiguration(
                    position: position,
                    format: selected,
                    previewMirrored: position == .front,
                    outputMirrored: false
                ),
                capabilities: CaptureCapabilities(
                    availableFormats: availableFormats,
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
        guard active == nil else {
            throw CaptureError.cameraSwitchDuringRecording
        }
        switchCount += 1
    }

    func startRecording(
        recordingID: UUID,
        outputURL: URL,
        rotationAngle: Double
    ) async throws {
        guard active == nil else {
            throw CaptureError.alreadyRecording
        }
        startRecordingCount += 1
        lastStartRotationAngle = rotationAngle
        active = (recordingID, outputURL)
    }

    func stopRecording(recordingID: UUID) async throws {
        guard active?.id == recordingID else {
            throw CaptureError.notRecording
        }
        stopRecordingCount += 1
    }

    func setFocusAndExposure(
        at point: NormalizedCapturePoint,
        locked: Bool
    ) async throws {
        if let focusError {
            throw focusError
        }
    }

    func handleApplicationBackgrounded() async {
        backgroundCount += 1
        if let active {
            continuation.yield(
                .interrupted(
                    recordingID: active.id,
                    reason: .applicationBackgrounded,
                    outputURL: active.url
                )
            )
        }
    }

    func handleApplicationForegrounded() async {
        foregroundCount += 1
    }

    func finish(recordingID: UUID) {
        let url: URL
        if active?.id == recordingID {
            url = active?.url ?? URL(fileURLWithPath: "/tmp/capture.mov")
            active = nil
        } else {
            url = URL(fileURLWithPath: "/tmp/stale.mov")
        }
        continuation.yield(
            .recordingFinished(
                recordingID: recordingID,
                outputURL: url,
                duration: 2
            )
        )
    }

    func interrupt(
        recordingID: UUID,
        reason: CaptureInterruptionReason
    ) {
        continuation.yield(
            .interrupted(
                recordingID: recordingID,
                reason: reason,
                outputURL: active?.url
            )
        )
    }
}

private actor TestRecordingFileStore: RecordingFileStoring {
    private(set) var createCount = 0
    private(set) var completeCount = 0
    private(set) var preserveCount = 0

    func createRecording(
        scriptID: UUID,
        orientation: CaptureOrientation,
        resolution: VideoResolution
    ) async throws -> PendingRecording {
        createCount += 1
        let projectID = UUID()
        let recordingID = UUID()
        return PendingRecording(
            projectID: projectID,
            recordingID: recordingID,
            scriptID: scriptID,
            temporaryURL: URL(
                fileURLWithPath: "/tmp/\(recordingID).recording.mov"
            ),
            finalURL: URL(fileURLWithPath: "/tmp/\(recordingID).mov"),
            createdAt: .now,
            orientation: orientation,
            resolution: resolution
        )
    }

    func markRecordingStarted(_ recording: PendingRecording) async throws {}

    func completeRecording(
        _ recording: PendingRecording,
        duration: TimeInterval
    ) async throws -> CompletedRecording {
        completeCount += 1
        return CompletedRecording(
            projectID: recording.projectID,
            recordingID: recording.recordingID,
            fileURL: recording.finalURL,
            duration: duration,
            completedAt: .now
        )
    }

    func preserveRecoverableRecording(
        _ recording: PendingRecording,
        reason: CaptureInterruptionReason
    ) async throws -> RecoverableRecording {
        preserveCount += 1
        return RecoverableRecording(
            projectID: recording.projectID,
            recordingID: recording.recordingID,
            fileURL: recording.temporaryURL,
            reason: reason,
            discoveredAt: .now
        )
    }

    func recoverPendingRecordings() async -> [RecoverableRecording] {
        []
    }

    func deleteProject(projectID: UUID) async throws {}
}

private actor TestStorageSpace: StorageSpaceChecking {
    private var capacities: [Int64]

    init(capacities: [Int64]) {
        self.capacities = capacities
    }

    func availableCapacityForImportantUsage() async throws -> Int64 {
        guard capacities.count > 1 else {
            return capacities.first ?? 0
        }
        return capacities.removeFirst()
    }
}

private struct TestPhotoLibrary: PhotoLibrarySaving {
    let result: PhotoSaveResult

    func authorizationStatus() async -> PermissionState {
        result == .permissionDenied ? .denied : .authorized
    }

    func saveVideo(at url: URL) async -> PhotoSaveResult {
        result
    }
}

private actor TestAudioSession: AudioSessionServicing {
    private let stream: AsyncStream<AudioSessionEvent>
    private let continuation: AsyncStream<AudioSessionEvent>.Continuation

    init() {
        let pair = AsyncStream<AudioSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func currentInputRoute() async -> AudioInputRoute {
        AudioInputRoute(
            name: "测试麦克风",
            isBluetooth: false,
            isAvailable: true
        )
    }

    func activateForRecording() async throws {}

    func deactivateAfterRecording() async {}

    func events() async -> AsyncStream<AudioSessionEvent> {
        stream
    }

    func emit(_ event: AudioSessionEvent) {
        continuation.yield(event)
    }
}

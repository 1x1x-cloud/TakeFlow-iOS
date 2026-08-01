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

    func testFirstEntryExitAndSecondEntryBothBecomeReady() async throws {
        let capture = TestCaptureSession()
        let first = makeFixture(capture: capture).viewModel
        await first.prepare()
        try await waitUntil { first.state == .ready }
        await first.viewDidDisappear()

        let second = makeFixture(capture: capture).viewModel
        await second.prepare()
        try await waitUntil { second.state == .ready }

        let configureCount = await capture.configureCount
        let startPreviewCount = await capture.startPreviewCount
        XCTAssertEqual(configureCount, 2)
        XCTAssertEqual(startPreviewCount, 2)
        XCTAssertEqual(second.configuration?.position, .front)
    }

    func testTwentyEntryExitCyclesRemainReadyAndStopExactlyOnce()
        async throws
    {
        let capture = TestCaptureSession()
        for _ in 0..<20 {
            let viewModel = makeFixture(capture: capture).viewModel
            await viewModel.prepare()
            try await waitUntil { viewModel.state == .ready }
            await viewModel.viewDidDisappear()
            await viewModel.viewDidDisappear()
        }

        let configureCount = await capture.configureCount
        let startPreviewCount = await capture.startPreviewCount
        let stopPreviewCount = await capture.stopPreviewCount
        XCTAssertEqual(configureCount, 20)
        XCTAssertEqual(startPreviewCount, 20)
        XCTAssertEqual(stopPreviewCount, 20)
    }

    func testExitDuringPreparationDoesNotBlockNextEntry()
        async throws
    {
        let capture = TestCaptureSession()
        await capture.setSuspendsPreview(true)
        let first = makeFixture(capture: capture).viewModel
        let firstPreparation = Task { await first.prepare() }
        try await waitUntil { await capture.startPreviewCount == 0 }
        try await waitUntil {
            await capture.configuredSessionIDs.count == 1
        }
        await first.viewDidDisappear()

        await capture.setSuspendsPreview(false)
        let second = makeFixture(capture: capture).viewModel
        await second.prepare()
        try await waitUntil { second.state == .ready }
        await capture.resumeSuspendedPreviews()
        await firstPreparation.value

        XCTAssertEqual(second.state, .ready)
        XCTAssertEqual(second.configuration?.position, .front)
    }

    func testRepeatedPrepareAndStopAreIdempotent() async throws {
        let capture = TestCaptureSession()
        let viewModel = makeFixture(capture: capture).viewModel

        await viewModel.prepare()
        try await waitUntil { viewModel.state == .ready }
        await viewModel.prepare()
        await viewModel.viewDidDisappear()
        await viewModel.viewDidDisappear()

        let configureCount = await capture.configureCount
        let startPreviewCount = await capture.startPreviewCount
        let stopPreviewCount = await capture.stopPreviewCount
        XCTAssertEqual(configureCount, 1)
        XCTAssertEqual(startPreviewCount, 1)
        XCTAssertEqual(stopPreviewCount, 1)
    }

    func testExitWhileRecordingFinalizesBeforeLifecycleEnds()
        async throws
    {
        let capture = TestCaptureSession(finishesWhenStopped: true)
        let files = TestRecordingFileStore()
        let fixture = makeFixture(capture: capture, files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        _ = try await waitForRecordingID(viewModel: fixture.viewModel)

        await fixture.viewModel.viewDidDisappear()

        let stopCount = await capture.stopRecordingCount
        let completeCount = await files.completeCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(completeCount, 1)
        XCTAssertNotNil(fixture.viewModel.completedRecording)
    }

    func testLateReadyEventFromFirstSessionCannotChangeSecondSession()
        async throws
    {
        let capture = TestCaptureSession()
        let first = makeFixture(capture: capture).viewModel
        await first.prepare()
        try await waitUntil { first.state == .ready }
        let configuredSessionIDs = await capture.configuredSessionIDs
        let firstSessionID = try XCTUnwrap(configuredSessionIDs.first)
        await first.viewDidDisappear()

        let second = makeFixture(capture: capture).viewModel
        await second.prepare()
        try await waitUntil { second.state == .ready }
        await capture.emitReadyForTesting(
            sessionID: firstSessionID,
            position: .back
        )
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(second.state, .ready)
        XCTAssertEqual(second.configuration?.position, .front)
    }

    func testPreparationTimeoutShowsRetryAndRetryRecovers()
        async throws
    {
        let capture = TestCaptureSession()
        await capture.setSuspendsPreview(true)
        let fixture = makeFixture(
            capture: capture,
            preparationTimeout: .milliseconds(30)
        )
        let firstPreparation = Task {
            await fixture.viewModel.prepare()
        }
        try await waitUntil {
            fixture.viewModel.state == .failed(.preparationTimedOut)
        }

        XCTAssertTrue(fixture.viewModel.canRetryPreparation)
        XCTAssertTrue(
            fixture.viewModel.errorMessage?.contains("准备超时") == true
        )

        await capture.setSuspendsPreview(false)
        await fixture.viewModel.retryPreparation()
        try await waitUntil { fixture.viewModel.state == .ready }
        await capture.resumeSuspendedPreviews()
        await firstPreparation.value

        XCTAssertEqual(fixture.viewModel.state, .ready)
        let configureCount = await capture.configureCount
        XCTAssertEqual(configureCount, 2)
    }

    func testBackgroundInterruptionThenReentryDoesNotRemainPreparing()
        async throws
    {
        let capture = TestCaptureSession()
        let first = makeFixture(capture: capture).viewModel
        await first.prepare()
        try await waitUntil { first.state == .ready }
        first.sceneDidEnterBackground()
        try await waitUntil {
            if case .interrupted = first.state {
                return true
            }
            return false
        }
        first.sceneDidBecomeActive()
        await first.viewDidDisappear()

        let second = makeFixture(capture: capture).viewModel
        await second.prepare()
        try await waitUntil { second.state == .ready }

        XCTAssertEqual(second.state, .ready)
        let configureCount = await capture.configureCount
        XCTAssertEqual(configureCount, 2)
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
        try await waitUntil { fixture.viewModel.state == .ready }

        let stopRecordingCount = await capture.stopRecordingCount
        let completeCount = await files.completeCount
        XCTAssertEqual(stopRecordingCount, 1)
        XCTAssertEqual(completeCount, 1)
        XCTAssertNotNil(fixture.viewModel.completedRecording)
        XCTAssertTrue(fixture.viewModel.canSwitchCamera)
        XCTAssertTrue(fixture.viewModel.canStartRecording)
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

    func testCompletedRecordingRemainsAvailableAfterReturningReady()
        async throws
    {
        let fixture = makeFixture()

        try await finishOneRecording(
            in: fixture.viewModel,
            capture: fixture.capture
        )

        XCTAssertEqual(fixture.viewModel.state, .ready)
        XCTAssertNotNil(fixture.viewModel.completedRecording)
        XCTAssertTrue(fixture.viewModel.canSwitchCamera)
        XCTAssertTrue(fixture.viewModel.canStartRecording)
    }

    func testCompletedRecordingCanSwitchCameraWithoutLeavingPage()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        try await finishOneRecording(
            in: fixture.viewModel,
            capture: capture
        )
        let completed = fixture.viewModel.completedRecording

        fixture.viewModel.switchCamera()
        try await waitUntil {
            fixture.viewModel.state == .ready
                && fixture.viewModel.configuration?.position == .back
        }

        let switchCount = await capture.switchCount
        XCTAssertEqual(switchCount, 1)
        XCTAssertEqual(fixture.viewModel.completedRecording, completed)
    }

    func testRepeatedCameraSwitchWhileReconfiguringRunsOnce()
        async throws
    {
        let capture = TestCaptureSession()
        await capture.setSuspendsCameraSwitch(true)
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        fixture.viewModel.switchCamera()
        fixture.viewModel.switchCamera()
        try await waitUntil { await capture.switchCount == 1 }

        XCTAssertEqual(fixture.viewModel.state, .configuring)
        XCTAssertFalse(fixture.viewModel.canSwitchCamera)

        await capture.resumeSuspendedCameraSwitches()
        try await waitUntil {
            fixture.viewModel.state == .ready
                && fixture.viewModel.configuration?.position == .back
        }
        let switchCount = await capture.switchCount
        XCTAssertEqual(switchCount, 1)
    }

    func testCameraSwitchFailureRequiresExistingRetryFlow()
        async throws
    {
        let capture = TestCaptureSession(
            switchError: .cameraUnavailable
        )
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        fixture.viewModel.switchCamera()
        try await waitUntil {
            fixture.viewModel.state == .failed(.cameraUnavailable)
        }

        XCTAssertFalse(fixture.viewModel.canSwitchCamera)
        XCTAssertTrue(fixture.viewModel.canRetryPreparation)
        XCTAssertNotNil(fixture.viewModel.errorMessage)

        await fixture.viewModel.retryPreparation()
        try await waitUntil { fixture.viewModel.state == .ready }
    }

    func testCameraSwitchRemainsDisabledDuringFileFinalization()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        await files.setSuspendsCompletion(true)
        let fixture = makeFixture(capture: capture, files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )
        fixture.viewModel.stopRecording()
        try await waitUntil { await capture.stopRecordingCount == 1 }
        await capture.finish(recordingID: recordingID)
        try await waitUntil { await files.completeCount == 1 }

        XCTAssertEqual(
            fixture.viewModel.state,
            .stopping(recordingID: recordingID)
        )
        XCTAssertFalse(fixture.viewModel.canSwitchCamera)
        fixture.viewModel.switchCamera()
        let switchCount = await capture.switchCount
        XCTAssertEqual(switchCount, 0)

        await files.resumeSuspendedCompletions()
        try await waitUntil { fixture.viewModel.state == .ready }
    }

    func testIdleInterruptionEndsWithExplicitCameraRecovery()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        await capture.interruptCurrentSession(
            reason: .videoDeviceInUseByAnotherClient
        )
        try await waitUntil {
            if case .interrupted = fixture.viewModel.state {
                return true
            }
            return false
        }
        XCTAssertFalse(fixture.viewModel.canSwitchCamera)
        XCTAssertFalse(fixture.viewModel.canRetryPreparation)

        await capture.endCurrentInterruption()
        try await waitUntil {
            fixture.viewModel.state
                == .recoveryRequired(
                    reason: .videoDeviceInUseByAnotherClient
                )
        }
        XCTAssertTrue(fixture.viewModel.canRetryPreparation)
        XCTAssertFalse(fixture.viewModel.canSwitchCamera)

        await fixture.viewModel.prepare()
        XCTAssertEqual(
            fixture.viewModel.state,
            .recoveryRequired(
                reason: .videoDeviceInUseByAnotherClient
            )
        )

        await fixture.viewModel.retryPreparation()
        try await waitUntil { fixture.viewModel.state == .ready }
    }

    func testRecordingInterruptionFinalizesBeforeRecoveryIsAvailable()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        await capture.interrupt(
            recordingID: recordingID,
            reason: .audioDeviceInUseByAnotherClient
        )
        try await waitUntil {
            if case .interrupted = fixture.viewModel.state {
                return true
            }
            return false
        }
        await capture.endCurrentInterruption()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(fixture.viewModel.canRetryPreparation)

        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel.state
                == .recoveryRequired(
                    reason: .audioDeviceInUseByAnotherClient
                )
        }
        XCTAssertNotNil(fixture.viewModel.recoverableRecording)
        XCTAssertTrue(fixture.viewModel.canRetryPreparation)
    }

    func testOldSessionInterruptionCannotPolluteNewLifecycle()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        let configuredSessionIDs = await capture.configuredSessionIDs
        let firstSessionID = try XCTUnwrap(configuredSessionIDs.first)

        await fixture.viewModel.viewDidDisappear()
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        await capture.emitInterruption(
            to: firstSessionID,
            recordingID: nil,
            reason: .videoDeviceInUseByAnotherClient
        )
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(fixture.viewModel.state, .ready)
        XCTAssertTrue(fixture.viewModel.canSwitchCamera)
    }

    func testOldAudioInterruptionCannotPolluteNewLifecycle()
        async throws
    {
        let audio = TestAudioSession()
        let fixture = makeFixture(audio: audio)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        let firstSubscriptions = await audio.subscriptionIDs
        let firstSubscriptionID = try XCTUnwrap(firstSubscriptions.first)

        await fixture.viewModel.viewDidDisappear()
        await fixture.viewModel.prepare()
        try await waitUntil {
            let subscriptionCount = await audio.subscriptionCount()
            return fixture.viewModel.state == .ready
                && subscriptionCount >= 2
        }

        await audio.emit(
            .interruptionBegan,
            to: firstSubscriptionID
        )
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(fixture.viewModel.state, .ready)
        XCTAssertTrue(fixture.viewModel.canSwitchCamera)
    }

    func testFiftyCompletedRecordingAndCameraSwitchCyclesStayReady()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        for cycle in 1...50 {
            fixture.viewModel.startRecording()
            let recordingID = try await waitForRecordingID(
                viewModel: fixture.viewModel
            )
            fixture.viewModel.stopRecording()
            try await waitUntil {
                await capture.stopRecordingCount == cycle
            }
            await capture.finish(recordingID: recordingID)
            try await waitUntil {
                fixture.viewModel.state == .ready
                    && fixture.viewModel.completedRecording?.recordingID
                        == recordingID
            }

            fixture.viewModel.switchCamera()
            try await waitUntil {
                let switchCount = await capture.switchCount
                return fixture.viewModel.state == .ready
                    && switchCount == cycle
            }
            XCTAssertTrue(fixture.viewModel.canStartRecording)
            XCTAssertTrue(fixture.viewModel.canSwitchCamera)
        }

        let completed = await fixture.files.completedRecordings
        XCTAssertEqual(completed.count, 50)
        XCTAssertEqual(Set(completed.map(\.recordingID)).count, 50)
        XCTAssertEqual(Set(completed.map(\.fileURL)).count, 50)
    }

    func testFirstRecordingSurvivesSwitchAndSecondRecording()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        let fixture = makeFixture(capture: capture, files: files)

        try await finishOneRecording(
            in: fixture.viewModel,
            capture: capture
        )
        let first = try XCTUnwrap(fixture.viewModel.completedRecording)

        fixture.viewModel.switchCamera()
        try await waitUntil {
            fixture.viewModel.state == .ready
                && fixture.viewModel.configuration?.position == .back
        }

        fixture.viewModel.startRecording()
        let secondID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )
        fixture.viewModel.stopRecording()
        try await waitUntil { await capture.stopRecordingCount == 2 }
        await capture.finish(recordingID: secondID)
        try await waitUntil {
            fixture.viewModel.state == .ready
                && fixture.viewModel.completedRecording?.recordingID
                    == secondID
        }
        let second = try XCTUnwrap(fixture.viewModel.completedRecording)
        let completed = await files.completedRecordings
        let deletedProjects = await files.deletedProjectIDs

        XCTAssertNotEqual(first.recordingID, second.recordingID)
        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertEqual(completed.map(\.recordingID), [
            first.recordingID,
            second.recordingID
        ])
        XCTAssertFalse(deletedProjects.contains(first.projectID))
        XCTAssertFalse(deletedProjects.contains(second.projectID))
    }

    func testExitDuringCompletionDoesNotRestoreReady()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        let exitTask = Task {
            await fixture.viewModel.viewDidDisappear()
        }
        try await waitUntil { await capture.stopRecordingCount == 1 }
        await capture.finish(recordingID: recordingID)
        await exitTask.value

        XCTAssertNotEqual(fixture.viewModel.state, .ready)
        XCTAssertNotNil(fixture.viewModel.completedRecording)
        XCTAssertFalse(fixture.viewModel.canSwitchCamera)
    }

    func testOldCompletionCannotRestoreNewGenerationReady()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        try await finishOneRecording(
            in: fixture.viewModel,
            capture: capture
        )
        let oldRecordingID = try XCTUnwrap(
            fixture.viewModel.completedRecording?.recordingID
        )
        await fixture.viewModel.viewDidDisappear()

        await capture.setSuspendsPreview(true)
        let preparation = Task {
            await fixture.viewModel.prepare()
        }
        try await waitUntil { fixture.viewModel.state == .configuring }
        await capture.finish(recordingID: oldRecordingID)
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(fixture.viewModel.state, .configuring)
        XCTAssertNil(fixture.viewModel.completedRecording)

        await capture.setSuspendsPreview(false)
        await capture.resumeSuspendedPreviews()
        await preparation.value
        try await waitUntil { fixture.viewModel.state == .ready }
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
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        fixture.viewModel.sceneDidEnterBackground()
        try await waitUntil { await capture.backgroundCount == 1 }
        fixture.viewModel.sceneDidBecomeActive()
        try await waitUntil { await capture.foregroundCount == 1 }
        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel.canRetryPreparation
        }

        let startRecordingCount = await capture.startRecordingCount
        XCTAssertEqual(startRecordingCount, 1)
        XCTAssertFalse(fixture.viewModel.canStartRecording)
        XCTAssertFalse(fixture.viewModel.canSwitchCamera)
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

        let didApply = await fixture.viewModel.focus(
            at: NormalizedCapturePoint(x: 0.5, y: 0.5)
        )

        XCTAssertFalse(didApply)
        XCTAssertTrue(
            fixture.viewModel.errorMessage?.contains("不支持点击对焦")
                == true
        )
    }

    func testReadyAndRecordingFocusForwardExactDevicePoints()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        let nearPoint = NormalizedCapturePoint(x: 0.22, y: 0.73)
        let readyApplied = await fixture.viewModel.focus(at: nearPoint)
        XCTAssertTrue(readyApplied)

        fixture.viewModel.startRecording()
        _ = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )
        let farPoint = NormalizedCapturePoint(x: 0.81, y: 0.19)
        let recordingApplied = await fixture.viewModel.focus(at: farPoint)
        XCTAssertTrue(recordingApplied)

        let requests = await capture.focusRequests
        XCTAssertEqual(requests, [nearPoint, farPoint])
    }

    func testFocusIsRejectedOutsideReadyAndRecordingStates()
        async throws
    {
        let idleCapture = TestCaptureSession()
        let idle = makeFixture(capture: idleCapture).viewModel
        let idleApplied = await idle.focus(
            at: NormalizedCapturePoint(x: 0.5, y: 0.5)
        )
        XCTAssertFalse(idleApplied)

        let configuringCapture = TestCaptureSession()
        await configuringCapture.setSuspendsPreview(true)
        let configuring = makeFixture(capture: configuringCapture).viewModel
        let preparation = Task {
            await configuring.prepare()
        }
        try await waitUntil { configuring.state == .configuring }
        let configuringApplied = await configuring.focus(
            at: NormalizedCapturePoint(x: 0.5, y: 0.5)
        )
        XCTAssertFalse(configuringApplied)
        await configuringCapture.resumeSuspendedPreviews()
        await preparation.value

        let stoppingCapture = TestCaptureSession()
        let stopping = makeFixture(capture: stoppingCapture).viewModel
        await stopping.prepare()
        try await waitUntil { stopping.state == .ready }
        stopping.startRecording()
        _ = try await waitForRecordingID(viewModel: stopping)
        stopping.stopRecording()
        try await waitUntil {
            if case .stopping = stopping.state {
                return true
            }
            return false
        }
        let stoppingApplied = await stopping.focus(
            at: NormalizedCapturePoint(x: 0.5, y: 0.5)
        )
        XCTAssertFalse(stoppingApplied)

        let interruptedCapture = TestCaptureSession()
        let interrupted = makeFixture(
            capture: interruptedCapture
        ).viewModel
        await interrupted.prepare()
        try await waitUntil { interrupted.state == .ready }
        await interruptedCapture.interruptCurrentSession(
            reason: .videoDeviceInUseByAnotherClient
        )
        try await waitUntil {
            if case .interrupted = interrupted.state {
                return true
            }
            return false
        }
        let interruptedApplied = await interrupted.focus(
            at: NormalizedCapturePoint(x: 0.5, y: 0.5)
        )
        XCTAssertFalse(interruptedApplied)

        let failed = makeFixture(
            permissions: TestCapturePermissions(
                camera: .denied,
                microphone: .authorized
            )
        ).viewModel
        await failed.prepare()
        let failedApplied = await failed.focus(
            at: NormalizedCapturePoint(x: 0.5, y: 0.5)
        )
        XCTAssertFalse(failedApplied)

        let closedCapture = TestCaptureSession()
        let closed = makeFixture(capture: closedCapture).viewModel
        await closed.prepare()
        try await waitUntil { closed.state == .ready }
        await closed.viewDidDisappear()
        let closedApplied = await closed.focus(
            at: NormalizedCapturePoint(x: 0.5, y: 0.5)
        )
        XCTAssertFalse(closedApplied)
    }

    func testFocusLockUsesDeviceOperationAndUpdatesOnlyAfterSuccess()
        async throws
    {
        let capture = TestCaptureSession()
        await capture.setSuspendsFocusLock(true)
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        let operation = Task {
            await fixture.viewModel.toggleFocusAndExposureLock()
        }
        try await waitUntil { await capture.lockRequests == [true] }

        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertFalse(fixture.viewModel.canToggleFocusAndExposureLock)

        await capture.resumeSuspendedFocusLocks()
        await operation.value

        XCTAssertTrue(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertEqual(
            fixture.viewModel.focusAndExposureNoticeMessage,
            CameraRecordingStrings.focusAndExposureLocked
        )
    }

    func testFocusLockFailureNeverShowsFalseLockedState()
        async throws
    {
        let capture = TestCaptureSession(lockError: .focusUnsupported)
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        await fixture.viewModel.toggleFocusAndExposureLock()

        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertNotNil(fixture.viewModel.errorMessage)
    }

    func testLateFocusLockCompletionCannotChangeClosedLifecycle()
        async throws
    {
        let capture = TestCaptureSession()
        await capture.setSuspendsFocusLock(true)
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        let operation = Task {
            await fixture.viewModel.toggleFocusAndExposureLock()
        }
        try await waitUntil { await capture.lockRequests == [true] }
        await fixture.viewModel.viewDidDisappear()
        await capture.resumeSuspendedFocusLocks()
        await operation.value

        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertFalse(fixture.viewModel.canAdjustFocusAndExposure)
        XCTAssertNil(fixture.viewModel.focusAndExposureNoticeMessage)
    }

    func testFocusUnlockRestoresContinuousDeviceModes()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        await fixture.viewModel.toggleFocusAndExposureLock()
        await fixture.viewModel.toggleFocusAndExposureLock()

        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        let requests = await capture.lockRequests
        XCTAssertEqual(requests, [true, false])
    }

    func testCameraSwitchResetsFocusLockForNewDevice()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        await fixture.viewModel.toggleFocusAndExposureLock()
        XCTAssertTrue(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertEqual(
            fixture.viewModel.focusAndExposureNoticeMessage,
            CameraRecordingStrings.focusAndExposureLocked
        )
        let feedbackGeneration =
            fixture.viewModel.focusAndExposureFeedbackGeneration
        await capture.setSuspendsCameraSwitch(true)

        fixture.viewModel.switchCamera()
        XCTAssertEqual(fixture.viewModel.state, .configuring)
        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertNil(fixture.viewModel.focusAndExposureNoticeMessage)
        XCTAssertGreaterThan(
            fixture.viewModel.focusAndExposureFeedbackGeneration,
            feedbackGeneration
        )

        await capture.resumeSuspendedCameraSwitches()
        try await waitUntil {
            fixture.viewModel.state == .ready
                && fixture.viewModel.configuration?.position == .back
        }

        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertNil(fixture.viewModel.focusAndExposureNoticeMessage)
        XCTAssertTrue(fixture.viewModel.canToggleFocusAndExposureLock)
    }

    func testLateOldCameraLockCannotRestoreFeedbackAfterSwitch()
        async throws
    {
        let capture = TestCaptureSession()
        await capture.setSuspendsFocusLock(true)
        await capture.setSuspendsCameraSwitch(true)
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        let oldLock = Task {
            await fixture.viewModel.toggleFocusAndExposureLock()
        }
        try await waitUntil { await capture.lockRequests == [true] }
        fixture.viewModel.switchCamera()
        XCTAssertEqual(fixture.viewModel.state, .configuring)

        await capture.resumeSuspendedFocusLocks()
        await oldLock.value
        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertNil(fixture.viewModel.focusAndExposureNoticeMessage)

        await capture.resumeSuspendedCameraSwitches()
        try await waitUntil {
            fixture.viewModel.state == .ready
                && fixture.viewModel.configuration?.position == .back
        }
        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertNil(fixture.viewModel.focusAndExposureNoticeMessage)
    }

    func testResolutionSwitchClearsFocusFeedback()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        await fixture.viewModel.toggleFocusAndExposureLock()
        XCTAssertNotNil(
            fixture.viewModel.focusAndExposureNoticeMessage
        )

        fixture.viewModel.selectResolution(.ultraHD4K)

        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertNil(fixture.viewModel.focusAndExposureNoticeMessage)
    }

    func testInterruptionAndNewLifecycleDoNotRetainFocusFeedback()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        await fixture.viewModel.toggleFocusAndExposureLock()

        await capture.interruptCurrentSession(
            reason: .videoDeviceInUseByAnotherClient
        )
        try await waitUntil {
            if case .interrupted = fixture.viewModel.state {
                return true
            }
            return false
        }
        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertNil(fixture.viewModel.focusAndExposureNoticeMessage)
        XCTAssertNotNil(fixture.viewModel.noticeMessage)

        await fixture.viewModel.viewDidDisappear()
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertNil(fixture.viewModel.focusAndExposureNoticeMessage)
    }

    func testUnsupportedPointAndLockCapabilitiesAreDisabled()
        async throws
    {
        let capabilities = CaptureCapabilities(
            availableFormats: [
                CaptureFormatOption(
                    resolution: .fullHD1080p,
                    framesPerSecond: 30,
                    codec: .h264
                )
            ],
            supportsFocusPoint: false,
            supportsExposurePoint: false,
            supportsFocusLock: false,
            supportsExposureLock: false,
            supportsContinuousFocus: false,
            supportsContinuousExposure: false,
            supportsVideoStabilization: true
        )
        let capture = TestCaptureSession(capabilities: capabilities)
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        XCTAssertFalse(fixture.viewModel.canAdjustFocusAndExposure)
        XCTAssertFalse(fixture.viewModel.canToggleFocusAndExposureLock)
        let didApply = await fixture.viewModel.focus(
            at: NormalizedCapturePoint(x: 0.5, y: 0.5)
        )
        XCTAssertFalse(didApply)
        await fixture.viewModel.toggleFocusAndExposureLock()

        let focusRequests = await capture.focusRequests
        let lockRequests = await capture.lockRequests
        XCTAssertEqual(focusRequests, [])
        XCTAssertEqual(lockRequests, [])
    }

    func testExposureOnlyDeviceStillAppliesSupportedAdjustment()
        async throws
    {
        let capabilities = CaptureCapabilities(
            availableFormats: [
                CaptureFormatOption(
                    resolution: .fullHD1080p,
                    framesPerSecond: 30,
                    codec: .h264
                )
            ],
            supportsFocusPoint: false,
            supportsExposurePoint: true,
            supportsFocusLock: false,
            supportsExposureLock: true,
            supportsContinuousFocus: false,
            supportsContinuousExposure: true,
            supportsVideoStabilization: true
        )
        let capture = TestCaptureSession(capabilities: capabilities)
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        let didApply = await fixture.viewModel.focus(
            at: NormalizedCapturePoint(x: 0.35, y: 0.65)
        )

        XCTAssertTrue(didApply)
        XCTAssertEqual(
            fixture.viewModel.focusAndExposureNoticeMessage,
            CameraRecordingStrings.exposureSet
        )
        XCTAssertFalse(fixture.viewModel.canToggleFocusAndExposureLock)
    }

    func testStartRequestDoesNotAdvanceDurationBeforeDelegateConfirmation()
        async throws
    {
        let capture = TestCaptureSession(
            finishesWhenStopped: true,
            automaticallyStartsRecording: false
        )
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        fixture.viewModel.startRecording()
        try await waitUntil {
            if case .awaitingRecordingStart =
                fixture.viewModel.state {
                return true
            }
            return false
        }
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(fixture.viewModel.recordingDuration, 0)
        let markStartedCount = await fixture.files.markStartedCount
        XCTAssertEqual(markStartedCount, 0)
        await fixture.viewModel.viewDidDisappear()
    }

    func testDelegateConfirmationBeginsRecordingAtZero() async throws {
        let capture = TestCaptureSession(
            finishesWhenStopped: true,
            automaticallyStartsRecording: false
        )
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRequestedRecordingID(
            viewModel: fixture.viewModel
        )

        await capture.emitRecordingStarted(recordingID: recordingID)

        try await waitUntil {
            fixture.viewModel.state
                == .recording(recordingID: recordingID)
        }
        XCTAssertEqual(fixture.viewModel.recordingDuration, 0)
        let markStartedCount = await fixture.files.markStartedCount
        XCTAssertEqual(markStartedCount, 1)
        await fixture.viewModel.viewDidDisappear()
    }

    func testDuplicateDelegateStartCannotRestartRecordingBoundary()
        async throws
    {
        let capture = TestCaptureSession(
            finishesWhenStopped: true,
            automaticallyStartsRecording: false
        )
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRequestedRecordingID(
            viewModel: fixture.viewModel
        )

        await capture.emitRecordingStarted(recordingID: recordingID)
        await capture.emitRecordingStarted(recordingID: recordingID)

        try await waitUntil {
            fixture.viewModel.state
                == .recording(recordingID: recordingID)
        }
        try await Task.sleep(for: .milliseconds(20))
        let markStartedCount = await fixture.files.markStartedCount
        XCTAssertEqual(markStartedCount, 1)
        await fixture.viewModel.viewDidDisappear()
    }

    func testFinalMediaDurationOverridesLiveEstimate() async throws {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )
        await capture.emitDuration(
            recordingID: recordingID,
            seconds: 0.75
        )
        try await waitUntil {
            fixture.viewModel.recordingDuration == 0.75
        }
        fixture.viewModel.stopRecording()
        try await waitUntil {
            await capture.stopRecordingCount == 1
        }
        await capture.finish(recordingID: recordingID, duration: 12.4)

        try await waitUntil { fixture.viewModel.state == .ready }

        XCTAssertEqual(fixture.viewModel.recordingDuration, 12.4)
        XCTAssertEqual(
            fixture.viewModel.completedRecording?.duration,
            12.4
        )
    }

    func testRecordingStartTimeoutFailsWithoutEnteringRecording()
        async throws
    {
        let capture = TestCaptureSession(
            finishesWhenStopped: true,
            automaticallyStartsRecording: false
        )
        let fixture = makeFixture(
            capture: capture,
            recordingStartTimeout: .milliseconds(30)
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        fixture.viewModel.startRecording()

        try await waitUntil {
            fixture.viewModel.state
                == .failed(.recordingStartTimedOut)
        }
        XCTAssertEqual(fixture.viewModel.recordingDuration, 0)
        let stopRecordingCount = await capture.stopRecordingCount
        XCTAssertEqual(stopRecordingCount, 1)
        try await waitUntil {
            await fixture.files.deletedProjectIDs.count == 1
        }
    }

    func testBackgroundBeforeDelegateStartNeverEntersRecording()
        async throws
    {
        let capture = TestCaptureSession(
            finishesWhenStopped: true,
            automaticallyStartsRecording: false
        )
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRequestedRecordingID(
            viewModel: fixture.viewModel
        )

        fixture.viewModel.sceneDidEnterBackground()
        try await waitUntil {
            await fixture.files.deletedProjectIDs.count == 1
        }
        let backgroundCount = await capture.backgroundCount
        XCTAssertEqual(backgroundCount, 1)

        await capture.emitRecordingStarted(recordingID: recordingID)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNotEqual(
            fixture.viewModel.state,
            .recording(recordingID: recordingID)
        )
    }

    func testExitBeforeDelegateStartCleansPendingWithoutRecording()
        async throws
    {
        let capture = TestCaptureSession(
            finishesWhenStopped: true,
            automaticallyStartsRecording: false
        )
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        _ = try await waitForRequestedRecordingID(
            viewModel: fixture.viewModel
        )

        await fixture.viewModel.viewDidDisappear()

        try await waitUntil {
            await fixture.files.deletedProjectIDs.count == 1
        }
        XCTAssertFalse(fixture.viewModel.state.isActivelyRecording)
        let markStartedCount = await fixture.files.markStartedCount
        let deletedProjectCount =
            await fixture.files.deletedProjectIDs.count
        XCTAssertEqual(markStartedCount, 0)
        XCTAssertEqual(deletedProjectCount, 1)
    }

    func testLateStartFromOldLifecycleCannotConfirmNewRecording()
        async throws
    {
        let capture = TestCaptureSession(
            finishesWhenStopped: true,
            automaticallyStartsRecording: false
        )
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        let configuredSessionIDs = await capture.configuredSessionIDs
        let firstSessionID = try XCTUnwrap(configuredSessionIDs.first)
        fixture.viewModel.startRecording()
        let firstRecordingID = try await waitForRequestedRecordingID(
            viewModel: fixture.viewModel
        )
        await fixture.viewModel.viewDidDisappear()

        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let secondRecordingID = try await waitForRequestedRecordingID(
            viewModel: fixture.viewModel
        )

        await capture.emitRecordingStarted(
            to: firstSessionID,
            recordingID: firstRecordingID
        )
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            fixture.viewModel.state,
            .awaitingRecordingStart(recordingID: secondRecordingID)
        )

        await capture.emitRecordingStarted(
            recordingID: secondRecordingID
        )
        try await waitUntil {
            fixture.viewModel.state
                == .recording(recordingID: secondRecordingID)
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

    private func makeFixture(
        permissions: TestCapturePermissions = TestCapturePermissions(),
        capture: TestCaptureSession = TestCaptureSession(),
        files: TestRecordingFileStore = TestRecordingFileStore(),
        storage: TestStorageSpace = TestStorageSpace(
            capacities: [Int64.max]
        ),
        photos: TestPhotoLibrary = TestPhotoLibrary(result: .saved),
        audio: TestAudioSession = TestAudioSession(),
        preparationTimeout: Duration = .seconds(1),
        recordingStartTimeout: Duration = .seconds(1)
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
            preparationTimeout: preparationTimeout,
            recordingStartTimeout: recordingStartTimeout,
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

    private func waitForRequestedRecordingID(
        viewModel: CameraRecordingViewModel
    ) async throws -> UUID {
        var result: UUID?
        try await waitUntil {
            if case .awaitingRecordingStart(let id) = viewModel.state {
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
        try await waitUntil { viewModel.state == .ready }
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
    private var continuations:
        [UUID: AsyncStream<CaptureSessionEvent>.Continuation] = [:]
    private let availableFormats: [CaptureFormatOption]
    private let reportedCapabilities: CaptureCapabilities
    private let focusError: CaptureError?
    private let lockError: CaptureError?
    private let switchError: CaptureError?
    private let finishesWhenStopped: Bool
    private let automaticallyStartsRecording: Bool
    private var activeSessionID: UUID?
    private var configuration: CaptureConfiguration?
    private var active: (id: UUID, url: URL, sessionID: UUID)?
    private var suspendsPreview = false
    private var suspendedPreviewContinuations:
        [UUID: CheckedContinuation<Void, Never>] = [:]
    private var suspendsCameraSwitch = false
    private var suspendedCameraSwitchContinuations:
        [CheckedContinuation<Void, Never>] = []
    private var suspendsFocusLock = false
    private var suspendedFocusLockContinuations:
        [CheckedContinuation<Void, Never>] = []
    private(set) var configuredSessionIDs: [UUID] = []
    private(set) var configureCount = 0
    private(set) var startPreviewCount = 0
    private(set) var stopPreviewCount = 0
    private(set) var startRecordingCount = 0
    private(set) var stopRecordingCount = 0
    private(set) var switchCount = 0
    private(set) var backgroundCount = 0
    private(set) var foregroundCount = 0
    private(set) var lastStartRotationAngle: Double?
    private(set) var focusRequests: [NormalizedCapturePoint] = []
    private(set) var lockRequests: [Bool] = []

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
        focusError: CaptureError? = nil,
        lockError: CaptureError? = nil,
        switchError: CaptureError? = nil,
        finishesWhenStopped: Bool = false,
        automaticallyStartsRecording: Bool = true,
        capabilities: CaptureCapabilities? = nil
    ) {
        self.availableFormats = availableFormats
        reportedCapabilities = capabilities ?? CaptureCapabilities(
            availableFormats: availableFormats,
            supportsFocusPoint: true,
            supportsExposurePoint: true,
            supportsFocusLock: true,
            supportsExposureLock: true,
            supportsContinuousFocus: true,
            supportsContinuousExposure: true,
            supportsVideoStabilization: true
        )
        self.focusError = focusError
        self.lockError = lockError
        self.switchError = switchError
        self.finishesWhenStopped = finishesWhenStopped
        self.automaticallyStartsRecording = automaticallyStartsRecording
    }

    func events(
        for sessionID: UUID
    ) async -> AsyncStream<CaptureSessionEvent> {
        let pair = AsyncStream<CaptureSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
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
        configureCount += 1
        configuredSessionIDs.append(sessionID)
        // Keep historical continuations alive in this test double so tests can
        // inject the late callback that a real delegate/notification may have
        // already queued. The cancelled ViewModel observation task must reject
        // it by lifecycle generation.
        activeSessionID = sessionID
        let selected = availableFormats.first {
            $0.resolution == preferredResolution
        } ?? availableFormats[0]
        configuration = CaptureConfiguration(
            position: position,
            format: selected,
            previewMirrored: position == .front,
            outputMirrored: false
        )
    }

    func startPreview(sessionID: UUID) async throws {
        if suspendsPreview {
            await withCheckedContinuation { continuation in
                suspendedPreviewContinuations[sessionID] = continuation
            }
        }
        guard
            activeSessionID == sessionID,
            let configuration
        else {
            throw CaptureError.staleCallback
        }
        startPreviewCount += 1
        continuations[sessionID]?.yield(
            .sessionReady(
                source: nil,
                configuration: configuration,
                capabilities: reportedCapabilities
            )
        )
    }

    func stopPreview(sessionID: UUID) async {
        stopPreviewCount += 1
        guard activeSessionID == sessionID else {
            return
        }
        if active == nil {
            activeSessionID = nil
            configuration = nil
        }
    }

    func setSuspendsPreview(_ suspends: Bool) {
        suspendsPreview = suspends
    }

    func resumeSuspendedPreviews() {
        let continuations = Array(suspendedPreviewContinuations.values)
        suspendedPreviewContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func setSuspendsCameraSwitch(_ suspends: Bool) {
        suspendsCameraSwitch = suspends
    }

    func resumeSuspendedCameraSwitches() {
        suspendsCameraSwitch = false
        let continuations = suspendedCameraSwitchContinuations
        suspendedCameraSwitchContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func setSuspendsFocusLock(_ suspends: Bool) {
        suspendsFocusLock = suspends
    }

    func resumeSuspendedFocusLocks() {
        suspendsFocusLock = false
        let continuations = suspendedFocusLockContinuations
        suspendedFocusLockContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func emitReadyForTesting(
        sessionID: UUID,
        position: CameraPosition = .back
    ) {
        let selected = availableFormats[0]
        continuations[sessionID]?.yield(
            .sessionReady(
                source: nil,
                configuration: CaptureConfiguration(
                    position: position,
                    format: selected,
                    previewMirrored: position == .front,
                    outputMirrored: false
                ),
                capabilities: reportedCapabilities
            )
        )
    }

    func switchCamera(sessionID: UUID) async throws {
        guard activeSessionID == sessionID else {
            throw CaptureError.staleCallback
        }
        guard active == nil else {
            throw CaptureError.cameraSwitchDuringRecording
        }
        switchCount += 1
        if let switchError {
            throw switchError
        }
        if suspendsCameraSwitch {
            await withCheckedContinuation { continuation in
                suspendedCameraSwitchContinuations.append(continuation)
            }
        }
        guard
            activeSessionID == sessionID,
            active == nil,
            let current = configuration
        else {
            throw CaptureError.staleCallback
        }
        let position: CameraPosition =
            current.position == .front ? .back : .front
        let updated = CaptureConfiguration(
            position: position,
            format: current.format,
            previewMirrored: position == .front,
            outputMirrored: false
        )
        configuration = updated
        continuations[sessionID]?.yield(
            .sessionReady(
                source: nil,
                configuration: updated,
                capabilities: reportedCapabilities
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
        guard active == nil else {
            throw CaptureError.alreadyRecording
        }
        startRecordingCount += 1
        lastStartRotationAngle = rotationAngle
        active = (recordingID, outputURL, sessionID)
        if automaticallyStartsRecording {
            continuations[sessionID]?.yield(
                .recordingStarted(recordingID: recordingID)
            )
        }
    }

    func stopRecording(recordingID: UUID) async throws {
        guard let recording = active, recording.id == recordingID else {
            throw CaptureError.notRecording
        }
        stopRecordingCount += 1
        if finishesWhenStopped {
            active = nil
            continuations[recording.sessionID]?.yield(
                .recordingFinished(
                    recordingID: recording.id,
                    outputURL: recording.url,
                    duration: 2
                )
            )
        }
    }

    func emitRecordingStarted(recordingID: UUID) {
        guard
            let active,
            active.id == recordingID
        else {
            return
        }
        continuations[active.sessionID]?.yield(
            .recordingStarted(recordingID: recordingID)
        )
    }

    func emitRecordingStarted(
        to sessionID: UUID,
        recordingID: UUID
    ) {
        continuations[sessionID]?.yield(
            .recordingStarted(recordingID: recordingID)
        )
    }

    func setFocusAndExposurePoint(
        sessionID: UUID,
        at point: NormalizedCapturePoint
    ) async throws -> CapturePointAdjustmentResult {
        guard activeSessionID == sessionID else {
            throw CaptureError.staleCallback
        }
        if let focusError {
            throw focusError
        }
        focusRequests.append(point)
        return CapturePointAdjustmentResult(
            focusApplied: reportedCapabilities.supportsFocusPoint,
            exposureApplied: reportedCapabilities.supportsExposurePoint
        )
    }

    func setFocusAndExposureLocked(
        sessionID: UUID,
        locked: Bool
    ) async throws -> CaptureFocusExposureLockState {
        guard activeSessionID == sessionID else {
            throw CaptureError.staleCallback
        }
        if let lockError {
            throw lockError
        }
        lockRequests.append(locked)
        if suspendsFocusLock {
            await withCheckedContinuation { continuation in
                suspendedFocusLockContinuations.append(continuation)
            }
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
        backgroundCount += 1
        if let active {
            continuations[sessionID]?.yield(
                .interrupted(
                    recordingID: active.id,
                    reason: .applicationBackgrounded,
                    outputURL: active.url
                )
            )
            if finishesWhenStopped {
                self.active = nil
                continuations[sessionID]?.yield(
                    .recordingFinished(
                        recordingID: active.id,
                        outputURL: active.url,
                        duration: 0
                    )
                )
            }
        } else {
            continuations[sessionID]?.yield(
                .interrupted(
                    recordingID: nil,
                    reason: .applicationBackgrounded,
                    outputURL: nil
                )
            )
        }
    }

    func handleApplicationForegrounded(sessionID: UUID) async {
        guard activeSessionID == sessionID else {
            return
        }
        foregroundCount += 1
    }

    func emitDuration(
        recordingID: UUID,
        seconds: TimeInterval
    ) {
        guard let sessionID = active?.sessionID else {
            return
        }
        continuations[sessionID]?.yield(
            .duration(recordingID: recordingID, seconds: seconds)
        )
    }

    func finish(
        recordingID: UUID,
        duration: TimeInterval = 2
    ) {
        let url: URL
        if active?.id == recordingID {
            url = active?.url ?? URL(fileURLWithPath: "/tmp/capture.mov")
            active = nil
        } else {
            url = URL(fileURLWithPath: "/tmp/stale.mov")
        }
        let sessionID = active?.sessionID ?? activeSessionID
        if let sessionID {
            continuations[sessionID]?.yield(
            .recordingFinished(
                recordingID: recordingID,
                outputURL: url,
                duration: duration
            )
            )
        }
    }

    func interrupt(
        recordingID: UUID,
        reason: CaptureInterruptionReason
    ) {
        guard let sessionID = active?.sessionID ?? activeSessionID else {
            return
        }
        continuations[sessionID]?.yield(
            .interrupted(
                recordingID: recordingID,
                reason: reason,
                outputURL: active?.url
            )
        )
    }

    func interruptCurrentSession(reason: CaptureInterruptionReason) {
        guard let sessionID = activeSessionID else {
            return
        }
        continuations[sessionID]?.yield(
            .interrupted(
                recordingID: active?.id,
                reason: reason,
                outputURL: active?.url
            )
        )
    }

    func endCurrentInterruption() {
        guard let sessionID = activeSessionID else {
            return
        }
        continuations[sessionID]?.yield(
            .interruptionEnded(reason: nil)
        )
    }

    func emitInterruption(
        to sessionID: UUID,
        recordingID: UUID?,
        reason: CaptureInterruptionReason
    ) {
        continuations[sessionID]?.yield(
            .interrupted(
                recordingID: recordingID,
                reason: reason,
                outputURL: nil
            )
        )
    }
}

private actor TestRecordingFileStore: RecordingFileStoring {
    private(set) var createCount = 0
    private(set) var completeCount = 0
    private(set) var markStartedCount = 0
    private(set) var preserveCount = 0
    private(set) var completedRecordings: [CompletedRecording] = []
    private(set) var deletedProjectIDs: [UUID] = []
    private var suspendsCompletion = false
    private var completionContinuations:
        [CheckedContinuation<Void, Never>] = []

    func setSuspendsCompletion(_ suspends: Bool) {
        suspendsCompletion = suspends
    }

    func resumeSuspendedCompletions() {
        suspendsCompletion = false
        let continuations = completionContinuations
        completionContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

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

    func markRecordingStarted(_ recording: PendingRecording) async throws {
        markStartedCount += 1
    }

    func completeRecording(
        _ recording: PendingRecording,
        duration: TimeInterval
    ) async throws -> CompletedRecording {
        completeCount += 1
        if suspendsCompletion {
            await withCheckedContinuation { continuation in
                completionContinuations.append(continuation)
            }
        }
        let completed = CompletedRecording(
            projectID: recording.projectID,
            recordingID: recording.recordingID,
            fileURL: recording.finalURL,
            duration: duration,
            completedAt: .now
        )
        completedRecordings.append(completed)
        return completed
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

    func deleteProject(projectID: UUID) async throws {
        deletedProjectIDs.append(projectID)
    }
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
    private var continuations:
        [UUID: AsyncStream<AudioSessionEvent>.Continuation] = [:]
    private(set) var subscriptionIDs: [UUID] = []

    init() {}

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
        let pair = AsyncStream<AudioSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        let subscriptionID = UUID()
        continuations[subscriptionID] = pair.continuation
        subscriptionIDs.append(subscriptionID)
        return pair.stream
    }

    func emit(_ event: AudioSessionEvent) {
        continuations.values.forEach { $0.yield(event) }
    }

    func emit(
        _ event: AudioSessionEvent,
        to subscriptionID: UUID
    ) {
        continuations[subscriptionID]?.yield(event)
    }

    func subscriptionCount() -> Int {
        subscriptionIDs.count
    }
}

@preconcurrency import AVFAudio
import Foundation
import XCTest
@testable import TakeFlow

@MainActor
final class CameraRecordingViewModelTests: XCTestCase {
    private func makeRecoverable(
        projectID: UUID = UUID(),
        recordingID: UUID = UUID(),
        discoveredAt: Date = Date(),
        disposition: RecoverableRecordingDisposition = .pendingReview
    ) -> RecoverableRecording {
        RecoverableRecording(
            projectID: projectID,
            recordingID: recordingID,
            fileURL: URL(fileURLWithPath: "/tmp/\(recordingID).recording.mov"),
            reason: .unknown,
            discoveredAt: discoveredAt,
            disposition: disposition
        )
    }

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
        await firstPreparation.value

        XCTAssertEqual(fixture.viewModel.state, .ready)
        let configureCount = await capture.configureCount
        XCTAssertEqual(configureCount, 2)
        let configuredSessionIDs = await capture.configuredSessionIDs
        XCTAssertEqual(Set(configuredSessionIDs).count, 2)
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
            first.state
                == .recoveryRequired(reason: .applicationBackgrounded)
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
        let preserveCount = await files.preserveCount
        XCTAssertEqual(stopRecordingCount, 1)
        XCTAssertEqual(completeCount, 1)
        XCTAssertEqual(preserveCount, 0)
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
            fixture.viewModel.state
                == .recoveryRequired(
                    reason: .videoDeviceInUseByAnotherClient
                )
        }
        XCTAssertFalse(fixture.viewModel.canSwitchCamera)
        XCTAssertTrue(fixture.viewModel.canRetryPreparation)
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)

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
            .interruptionBegan(.unspecified),
            to: firstSubscriptionID
        )
        await audio.emit(
            .mediaServicesWereLost,
            to: firstSubscriptionID
        )
        await audio.emit(
            .mediaServicesWereReset,
            to: firstSubscriptionID
        )
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(fixture.viewModel.state, .ready)
        XCTAssertTrue(fixture.viewModel.canSwitchCamera)
        XCTAssertNil(fixture.viewModel.interruptionEpisode)
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

    func testRecoveryScanExposesEveryPendingRecording() async throws {
        let files = TestRecordingFileStore()
        let recordings = [makeRecoverable(), makeRecoverable(), makeRecoverable()]
        await files.setPendingRecoverables(recordings)
        let fixture = makeFixture(files: files)

        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        XCTAssertEqual(
            Set(fixture.viewModel.recoverableReviewItems.map(\.id)),
            Set(recordings.map(\.recordingID))
        )
    }

    func testPlayableRecoveryValidationPublishesDurationAndAudio()
        async throws
    {
        let files = TestRecordingFileStore()
        let validator = TestRecoverableMediaValidator()
        let recording = makeRecoverable()
        await files.setPendingRecoverables([recording])
        await validator.setResult(
            .playable(
                RecoverableMediaInfo(duration: 4.5, hasAudioTrack: true)
            ),
            for: recording.recordingID
        )
        let fixture = makeFixture(
            files: files,
            recoverableMediaValidator: validator
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        let result = await fixture.viewModel.validateRecoverableRecording(
            recordingID: recording.recordingID
        )

        XCTAssertTrue(result)
        XCTAssertEqual(
            fixture.viewModel.recoverableReviewItems.first?.state,
            .playable(
                RecoverableMediaInfo(duration: 4.5, hasAudioTrack: true)
            )
        )
    }

    func testRecoveryWithoutAudioRemainsPlayableWithExplicitMetadata()
        async throws
    {
        let files = TestRecordingFileStore()
        let validator = TestRecoverableMediaValidator()
        let recording = makeRecoverable()
        await files.setPendingRecoverables([recording])
        await validator.setResult(
            .playable(
                RecoverableMediaInfo(duration: 2, hasAudioTrack: false)
            ),
            for: recording.recordingID
        )
        let fixture = makeFixture(
            files: files,
            recoverableMediaValidator: validator
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        let validated = await fixture.viewModel.validateRecoverableRecording(
            recordingID: recording.recordingID
        )
        XCTAssertTrue(validated)
        XCTAssertEqual(
            fixture.viewModel.recoverableReviewItems.first?.state,
            .playable(
                RecoverableMediaInfo(duration: 2, hasAudioTrack: false)
            )
        )
    }

    func testDamagedAndZeroDurationRecoveriesAreNotPlayable()
        async throws
    {
        for failure in [
            RecoverableMediaValidationFailure.containerUnrecognized,
            .durationInvalid
        ] {
            let files = TestRecordingFileStore()
            let validator = TestRecoverableMediaValidator()
            let recording = makeRecoverable()
            await files.setPendingRecoverables([recording])
            await validator.setResult(
                .invalid(failure),
                for: recording.recordingID
            )
            let fixture = makeFixture(
                files: files,
                recoverableMediaValidator: validator
            )
            await fixture.viewModel.prepare()
            try await waitUntil { fixture.viewModel.state == .ready }

            let validated = await fixture.viewModel
                .validateRecoverableRecording(
                    recordingID: recording.recordingID
                )
            XCTAssertFalse(validated)
            XCTAssertEqual(
                fixture.viewModel.recoverableReviewItems.first?.state,
                .damaged(failure)
            )
        }
    }

    func testRepeatedValidationRequestRunsOnlyOnce() async throws {
        let files = TestRecordingFileStore()
        let validator = TestRecoverableMediaValidator()
        let recording = makeRecoverable()
        await files.setPendingRecoverables([recording])
        await validator.setSuspended(true, for: recording.recordingID)
        let fixture = makeFixture(
            files: files,
            recoverableMediaValidator: validator
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        let first = Task {
            await fixture.viewModel.validateRecoverableRecording(
                recordingID: recording.recordingID
            )
        }
        try await waitUntil {
            fixture.viewModel.recoverableReviewItems.first?.state
                == .validating
        }
        let second = await fixture.viewModel.validateRecoverableRecording(
            recordingID: recording.recordingID
        )
        await validator.setSuspended(false, for: recording.recordingID)
        _ = await first.value

        XCTAssertFalse(second)
        let validationCount = await validator.validationCount(
            for: recording.recordingID
        )
        XCTAssertEqual(validationCount, 1)
    }

    func testRetainingRecoveryWritesMediaDurationAndInterruptedOrigin()
        async throws
    {
        let files = TestRecordingFileStore()
        let recording = makeRecoverable()
        await files.setPendingRecoverables([recording])
        let fixture = makeFixture(files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        let validated = await fixture.viewModel.validateRecoverableRecording(
            recordingID: recording.recordingID
        )
        XCTAssertTrue(validated)

        let retained = await fixture.viewModel.retainRecoverableRecording(
            recordingID: recording.recordingID
        )
        XCTAssertTrue(retained)

        XCTAssertEqual(
            fixture.viewModel.completedRecording?.origin,
            .interruptedRecovery
        )
        XCTAssertEqual(fixture.viewModel.completedRecording?.duration, 2)
        let retainedIDs = await files.retainedIDs()
        XCTAssertEqual(retainedIDs, [recording.recordingID])
    }

    func testRetainFailureKeepsRecoveryAvailable() async throws {
        let files = TestRecordingFileStore()
        let recording = makeRecoverable()
        await files.setPendingRecoverables([recording])
        await files.setShouldFailRetain(true)
        let fixture = makeFixture(files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        _ = await fixture.viewModel.validateRecoverableRecording(
            recordingID: recording.recordingID
        )

        let retained = await fixture.viewModel.retainRecoverableRecording(
            recordingID: recording.recordingID
        )
        XCTAssertFalse(retained)
        XCTAssertNotNil(
            fixture.viewModel.recoverableItem(
                recordingID: recording.recordingID
            )
        )
        let retainedIDs = await files.retainedIDs()
        XCTAssertTrue(retainedIDs.isEmpty)
    }

    func testDeleteRecoveryTargetsOnlySelectedRecordingAndCanRetry()
        async throws
    {
        let files = TestRecordingFileStore()
        let first = makeRecoverable()
        let second = makeRecoverable()
        await files.setPendingRecoverables([first, second])
        let fixture = makeFixture(files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        await files.setShouldFailDelete(true)

        let firstDeletion = await fixture.viewModel
            .deleteRecoverableRecording(recordingID: first.recordingID)
        XCTAssertFalse(firstDeletion)
        XCTAssertEqual(fixture.viewModel.recoverableReviewItems.count, 2)

        await files.setShouldFailDelete(false)
        let secondDeletion = await fixture.viewModel
            .deleteRecoverableRecording(recordingID: first.recordingID)
        XCTAssertTrue(secondDeletion)
        XCTAssertEqual(
            fixture.viewModel.recoverableReviewItems.map(\.id),
            [second.recordingID]
        )
    }

    func testLateValidationFromOldLifecycleCannotOverwriteNewScan()
        async throws
    {
        let files = TestRecordingFileStore()
        let validator = TestRecoverableMediaValidator()
        let recording = makeRecoverable()
        await files.setPendingRecoverables([recording])
        await validator.setSuspended(true, for: recording.recordingID)
        let fixture = makeFixture(
            files: files,
            recoverableMediaValidator: validator
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        let oldValidation = Task {
            await fixture.viewModel.validateRecoverableRecording(
                recordingID: recording.recordingID
            )
        }
        try await waitUntil {
            fixture.viewModel.recoverableReviewItems.first?.state
                == .validating
        }

        await fixture.viewModel.viewDidDisappear()
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        await validator.setSuspended(false, for: recording.recordingID)
        let oldResult = await oldValidation.value
        XCTAssertFalse(oldResult)

        XCTAssertEqual(
            fixture.viewModel.recoverableReviewItems.first?.state,
            .pending
        )
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
            interrupted.state
                == .recoveryRequired(
                    reason: .videoDeviceInUseByAnotherClient
                )
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
        let audio = TestAudioSession()
        let fixture = makeFixture(capture: capture, audio: audio)
        recordLifecycleTestStage(
            "first_prepare_begin",
            viewModel: fixture.viewModel
        )
        await fixture.viewModel.prepare()
        recordLifecycleTestStage(
            "first_prepare_returned",
            viewModel: fixture.viewModel
        )
        try await waitUntil { fixture.viewModel.state == .ready }
        await fixture.viewModel.toggleFocusAndExposureLock()

        await capture.interruptCurrentSession(
            reason: .videoDeviceInUseByAnotherClient
        )
        recordLifecycleTestStage(
            "waiting_for_recovery_required",
            viewModel: fixture.viewModel
        )
        try await waitUntil {
            fixture.viewModel.state
                == .recoveryRequired(
                    reason: .videoDeviceInUseByAnotherClient
                )
        }
        recordLifecycleTestStage(
            "recovery_required_reached",
            viewModel: fixture.viewModel
        )
        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertNil(fixture.viewModel.focusAndExposureNoticeMessage)
        XCTAssertNotNil(fixture.viewModel.interruptionNoticeMessage)

        recordLifecycleTestStage(
            "view_did_disappear_begin",
            viewModel: fixture.viewModel
        )
        await fixture.viewModel.viewDidDisappear()
        recordLifecycleTestStage(
            "view_did_disappear_returned",
            viewModel: fixture.viewModel
        )
        let closedCaptureStreamCount =
            await capture.activeEventStreamCount()
        let closedAudioStreamCount = await audio.activeEventStreamCount()
        XCTAssertEqual(closedCaptureStreamCount, 0)
        XCTAssertEqual(closedAudioStreamCount, 0)

        recordLifecycleTestStage(
            "second_prepare_begin",
            viewModel: fixture.viewModel
        )
        await fixture.viewModel.prepare()
        recordLifecycleTestStage(
            "second_prepare_returned",
            viewModel: fixture.viewModel
        )
        try await waitUntil { fixture.viewModel.state == .ready }
        recordLifecycleTestStage(
            "second_session_ready",
            viewModel: fixture.viewModel
        )

        XCTAssertFalse(fixture.viewModel.isFocusAndExposureLocked)
        XCTAssertNil(fixture.viewModel.focusAndExposureNoticeMessage)
        let newCaptureStreamCount = await capture.activeEventStreamCount()
        let newAudioStreamCount = await audio.activeEventStreamCount()
        XCTAssertEqual(newCaptureStreamCount, 1)
        XCTAssertEqual(newAudioStreamCount, 1)
        let configuredSessionIDs = await capture.configuredSessionIDs
        XCTAssertEqual(configuredSessionIDs.count, 2)
        XCTAssertNotEqual(
            configuredSessionIDs.first,
            configuredSessionIDs.last
        )
    }

    func testExitDuringSuspendedPreparationDrainsOldLifecycle()
        async throws
    {
        let capture = TestCaptureSession()
        await capture.setSuspendsPreview(true)
        let audio = TestAudioSession()
        let fixture = makeFixture(capture: capture, audio: audio)

        let firstPreparation = Task {
            await fixture.viewModel.prepare()
        }
        try await waitUntil {
            await capture.suspendedPreviewCount() == 1
        }

        await fixture.viewModel.viewDidDisappear()
        await firstPreparation.value
        let closedCaptureStreamCount =
            await capture.activeEventStreamCount()
        let closedAudioStreamCount = await audio.activeEventStreamCount()
        XCTAssertEqual(closedCaptureStreamCount, 0)
        XCTAssertEqual(closedAudioStreamCount, 0)

        await capture.setSuspendsPreview(false)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        let configureCount = await capture.configureCount
        XCTAssertEqual(configureCount, 2)
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
        let capture = TestCaptureSession(
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
        await audio.emit(.interruptionBegan(.unspecified))
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

    func testRapidCallEpisodeFinalizesAndPublishesExactlyOnce()
        async throws
    {
        let audio = TestAudioSession()
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        let fixture = makeFixture(
            capture: capture,
            files: files,
            audio: audio
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        await audio.emit(.interruptionBegan(.unspecified))
        await capture.interrupt(
            recordingID: recordingID,
            reason: .audioDeviceInUseByAnotherClient
        )
        await audio.emit(.interruptionEnded(.unspecified))
        try await waitUntil { await capture.stopRecordingCount == 1 }
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
        XCTAssertFalse(fixture.viewModel.canRetryPreparation)

        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel.state
                == .recoveryRequired(
                    reason: .audioDeviceInUseByAnotherClient
                )
        }

        let preserveCount = await files.preserveCount
        XCTAssertEqual(preserveCount, 1)
        XCTAssertEqual(fixture.viewModel.recoverableReviewItems.count, 1)
        XCTAssertTrue(fixture.viewModel.requiresManualReprepare)
        XCTAssertTrue(fixture.viewModel.canRetryPreparation)
    }

    func testInterruptionEndBeforeDidFinishCannotRestoreReady()
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
            reason: .videoDeviceInUseByAnotherClient
        )
        await capture.endCurrentInterruption()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertNotEqual(fixture.viewModel.state, .ready)
        XCTAssertFalse(fixture.viewModel.canRetryPreparation)
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)

        await capture.finish(recordingID: recordingID)
        try await waitUntil { fixture.viewModel.canRetryPreparation }
        XCTAssertEqual(fixture.viewModel.recoverableReviewItems.count, 1)
    }

    func testInterruptionBeforeDidStartWaitsForAVFinishWithoutRecovery()
        async throws
    {
        let audio = TestAudioSession()
        let capture = TestCaptureSession(
            automaticallyStartsRecording: false
        )
        let files = TestRecordingFileStore()
        let fixture = makeFixture(
            capture: capture,
            files: files,
            audio: audio
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRequestedRecordingID(
            viewModel: fixture.viewModel
        )
        XCTAssertEqual(
            fixture.viewModel.state,
            .awaitingRecordingStart(recordingID: recordingID)
        )

        await audio.emit(.interruptionBegan(.unspecified))
        try await waitUntil { await capture.stopRecordingCount == 1 }
        XCTAssertFalse(fixture.viewModel.canRetryPreparation)

        await capture.finish(recordingID: recordingID)
        try await waitUntil { fixture.viewModel.canRetryPreparation }

        let preserveCount = await files.preserveCount
        XCTAssertEqual(preserveCount, 0)
        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)
        XCTAssertTrue(fixture.viewModel.requiresManualReprepare)
    }

    func testRecoverableIsPublishedAfterDelayedManifestCommit()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        await files.setSuspendsPreservation(true)
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
        await capture.finish(recordingID: recordingID)
        try await waitUntil { await files.preserveCount == 1 }
        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)
        XCTAssertFalse(fixture.viewModel.canRetryPreparation)

        await files.resumeSuspendedPreservations()
        try await waitUntil {
            fixture.viewModel.recoverableReviewItems.map(\.id)
                == [recordingID]
        }
        XCTAssertTrue(fixture.viewModel.canRetryPreparation)
    }

    func testBackgroundReasonWinsLaterSuspendedAudioNotification()
        async throws
    {
        let capture = TestCaptureSession()
        let audio = TestAudioSession()
        let fixture = makeFixture(capture: capture, audio: audio)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        fixture.viewModel.sceneDidEnterBackground()
        await audio.emit(
            .interruptionBegan(
                AudioInterruptionDetails(
                    rawType: 1,
                    rawReason: 1,
                    wasSuspended: true
                )
            )
        )
        try await waitUntil {
            fixture.viewModel.interruptionEpisode?.sources.contains(
                .audioSession
            ) == true
        }

        XCTAssertEqual(
            fixture.viewModel.interruptionEpisode?.primaryReason,
            .applicationBackgrounded
        )
        XCTAssertTrue(
            fixture.viewModel.interruptionNoticeMessage?.contains("后台")
                == true
        )
        XCTAssertFalse(
            fixture.viewModel.interruptionNoticeMessage?.contains("麦克风")
                == true
        )
    }

    func testReviewRetainAndDeleteNeverClearManualReprepareLatch()
        async throws
    {
        let files = TestRecordingFileStore()
        let retained = makeRecoverable()
        let deleted = makeRecoverable()
        await files.setPendingRecoverables([retained, deleted])
        let fixture = makeFixture(files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        await fixture.capture.interruptCurrentSession(
            reason: .videoDeviceInUseByAnotherClient
        )
        try await waitUntil {
            fixture.viewModel.requiresManualReprepare
        }

        _ = await fixture.viewModel.validateRecoverableRecording(
            recordingID: retained.recordingID
        )
        XCTAssertTrue(fixture.viewModel.requiresManualReprepare)
        _ = await fixture.viewModel.retainRecoverableRecording(
            recordingID: retained.recordingID
        )
        XCTAssertTrue(fixture.viewModel.requiresManualReprepare)
        _ = await fixture.viewModel.deleteRecoverableRecording(
            recordingID: deleted.recordingID
        )
        XCTAssertTrue(fixture.viewModel.requiresManualReprepare)
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
    }

    func testExplicitReprepareIsOnlyPathBackToReadyAfterSystemUse()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        await capture.interruptCurrentSession(
            reason: .videoDeviceInUseByAnotherClient
        )
        await capture.endCurrentInterruption()
        try await waitUntil { fixture.viewModel.canRetryPreparation }
        XCTAssertNotEqual(fixture.viewModel.state, .ready)
        XCTAssertTrue(fixture.viewModel.requiresManualReprepare)

        await fixture.viewModel.retryPreparation()
        try await waitUntil { fixture.viewModel.state == .ready }
        XCTAssertFalse(fixture.viewModel.requiresManualReprepare)
        XCTAssertFalse(fixture.viewModel.shouldShowManualReprepare)
    }

    func testOldLifecycleInterruptionEndCannotChangeNewReadySession()
        async throws
    {
        let capture = TestCaptureSession()
        let fixture = makeFixture(capture: capture)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        let initialSessionIDs = await capture.configuredSessionIDs
        let oldSessionID = try XCTUnwrap(initialSessionIDs.first)

        await capture.interruptCurrentSession(reason: .cameraUnavailable)
        try await waitUntil {
            fixture.viewModel.requiresManualReprepare
        }
        await fixture.viewModel.retryPreparation()
        try await waitUntil { fixture.viewModel.state == .ready }
        let reconfiguredSessionIDs = await capture.configuredSessionIDs
        let newSessionID = try XCTUnwrap(reconfiguredSessionIDs.last)
        XCTAssertNotEqual(oldSessionID, newSessionID)

        await capture.emitInterruptionEnded(to: oldSessionID)
        await capture.emitInterruption(
            to: oldSessionID,
            recordingID: nil,
            reason: .audioDeviceInUseByAnotherClient
        )
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(fixture.viewModel.state, .ready)
        XCTAssertFalse(fixture.viewModel.requiresManualReprepare)
        XCTAssertNil(fixture.viewModel.interruptionEpisode)
    }

    func testMultipleSourcesShareOneEpisodeOneStopAndOneRecovery()
        async throws
    {
        let capture = TestCaptureSession()
        let audio = TestAudioSession()
        let files = TestRecordingFileStore()
        let fixture = makeFixture(
            capture: capture,
            files: files,
            audio: audio
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        fixture.viewModel.sceneDidEnterBackground()
        let episodeID = try XCTUnwrap(
            fixture.viewModel.interruptionEpisode?.id
        )
        await audio.emit(.interruptionBegan(.unspecified))
        await capture.interrupt(
            recordingID: recordingID,
            reason: .videoDeviceInUseByAnotherClient
        )
        try await waitUntil { await capture.stopRecordingCount == 1 }

        XCTAssertEqual(fixture.viewModel.interruptionEpisode?.id, episodeID)
        XCTAssertEqual(
            fixture.viewModel.interruptionEpisode?.sources,
            Set([
                .applicationBackgrounded,
                .audioSession,
                .cameraInUseByAnotherClient
            ])
        )

        await capture.finish(recordingID: recordingID)
        try await waitUntil { fixture.viewModel.canRetryPreparation }
        let preserveCount = await files.preserveCount
        XCTAssertEqual(preserveCount, 1)
        XCTAssertEqual(fixture.viewModel.recoverableReviewItems.count, 1)
    }

    func testRecoveryCommitFailureNeverPublishesFalseSuccess()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        await files.setShouldFailPreserve(true)
        let fixture = makeFixture(capture: capture, files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        await capture.interrupt(
            recordingID: recordingID,
            reason: .applicationBackgrounded
        )
        await capture.finish(recordingID: recordingID)
        try await waitUntil { fixture.viewModel.canRetryPreparation }

        let preserveCount = await files.preserveCount
        XCTAssertEqual(preserveCount, 1)
        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)
        XCTAssertFalse(
            fixture.viewModel.interruptionNoticeMessage?.contains("已保留")
                == true
        )
        XCTAssertTrue(
            fixture.viewModel.interruptionNoticeMessage?.contains("未能")
                == true
        )
        XCTAssertTrue(fixture.viewModel.requiresManualReprepare)
        XCTAssertTrue(
            fixture.viewModel.interruptionEpisode?
                .didFinishAVFoundationFinalization == true
        )
        XCTAssertTrue(
            fixture.viewModel.interruptionEpisode?
                .didResolveRecoveryManifest == true
        )
        XCTAssertFalse(
            fixture.viewModel.interruptionEpisode?
                .didCommitRecoveryManifest == true
        )

        await fixture.viewModel.retryPreparation()
        try await waitUntil { fixture.viewModel.state == .ready }
    }

    func testIdleInterruptionCreatesNoRecoveryAndDoesNotInventCameraUse()
        async throws
    {
        let audio = TestAudioSession()
        let fixture = makeFixture(audio: audio)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }

        await audio.emit(.interruptionBegan(.unspecified))
        try await waitUntil { fixture.viewModel.requiresManualReprepare }

        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)
        XCTAssertNil(fixture.viewModel.interruptionEpisode?.recordingID)
        XCTAssertEqual(
            fixture.viewModel.interruptionEpisode?.sources,
            Set([.audioSession])
        )
        XCTAssertEqual(
            fixture.viewModel.interruptionEpisode?.primaryReason,
            .audioSessionInterrupted
        )
        XCTAssertFalse(
            fixture.viewModel.interruptionNoticeMessage?.contains("摄像头被")
                == true
        )
    }

    func testSystemAudioServiceMapsMediaServicesLostNotification()
        async throws
    {
        let service = SystemAudioSessionService()
        let stream = await service.events()
        let received = expectation(description: "收到媒体服务丢失事件")
        var event: AudioSessionEvent?
        let observer = Task { @MainActor in
            for await next in stream {
                event = next
                received.fulfill()
                return
            }
        }

        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance()
        )
        await fulfillment(of: [received], timeout: 1)
        observer.cancel()

        XCTAssertEqual(event, .mediaServicesWereLost)
    }

    func testSystemAudioServiceMapsMediaServicesResetNotification()
        async throws
    {
        let service = SystemAudioSessionService()
        let stream = await service.events()
        let received = expectation(description: "收到媒体服务重置事件")
        var event: AudioSessionEvent?
        let observer = Task { @MainActor in
            for await next in stream {
                event = next
                received.fulfill()
                return
            }
        }

        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
        await fulfillment(of: [received], timeout: 1)
        observer.cancel()

        XCTAssertEqual(event, .mediaServicesWereReset)
    }

    func testMediaServicesLostThenResetUsesOneEpisodeAndOneStop()
        async throws
    {
        let capture = TestCaptureSession()
        let audio = TestAudioSession()
        let files = TestRecordingFileStore()
        let fixture = makeFixture(
            capture: capture,
            files: files,
            audio: audio
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        await audio.emit(.mediaServicesWereLost)
        try await waitUntil { await capture.stopRecordingCount == 1 }
        let episodeID = try XCTUnwrap(
            fixture.viewModel.interruptionEpisode?.id
        )
        await audio.emit(.mediaServicesWereReset)
        try await waitUntil {
            fixture.viewModel.interruptionEpisode?.reasons.contains(
                .mediaServicesReset
            ) == true
        }

        let stopCount = await capture.stopRecordingCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(fixture.viewModel.interruptionEpisode?.id, episodeID)
        XCTAssertEqual(
            fixture.viewModel.interruptionEpisode?.primaryReason,
            .mediaServicesLost
        )
        XCTAssertTrue(fixture.viewModel.requiresManualReprepare)
        XCTAssertTrue(
            fixture.viewModel.interruptionNoticeMessage?.contains(
                "已经恢复"
            ) == true
        )

        await capture.finish(recordingID: recordingID)
        try await waitUntil { fixture.viewModel.canRetryPreparation }
        let preserveCount = await files.preserveCount
        XCTAssertEqual(preserveCount, 1)
        XCTAssertEqual(fixture.viewModel.recoverableReviewItems.count, 1)

        await fixture.viewModel.retryPreparation()
        try await waitUntil { fixture.viewModel.state == .ready }
        let configureCount = await capture.configureCount
        let activationCount = await audio.activationCount
        let deactivationCount = await audio.deactivationCount
        XCTAssertEqual(configureCount, 2)
        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(deactivationCount, 1)
        XCTAssertFalse(fixture.viewModel.requiresManualReprepare)
    }

    func testBackgroundDelayedDidFinishCompletesWithinFiniteTask()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        let backgroundTasks = TestRecordingBackgroundTaskManager()
        let fixture = makeFixture(
            capture: capture,
            files: files,
            backgroundTasks: backgroundTasks
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        fixture.viewModel.sceneDidEnterBackground()
        try await waitUntil {
            let stopCount = await capture.stopRecordingCount
            return backgroundTasks.activeCount == 1 && stopCount == 1
        }
        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)

        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel.recoverableReviewItems.map(\.id)
                == [recordingID]
                && backgroundTasks.activeCount == 0
        }

        XCTAssertEqual(backgroundTasks.beginCount, 1)
        XCTAssertEqual(backgroundTasks.endCount, 1)
        XCTAssertEqual(backgroundTasks.activeCount, 0)
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
    }

    func testDidFinishBeforeBackgroundLinksAndPublishesRecoveryOnce()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        let backgroundTasks = TestRecordingBackgroundTaskManager()
        let fixture = makeFixture(
            capture: capture,
            files: files,
            backgroundTasks: backgroundTasks
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel
                .finalizedRecordingsAwaitingDispositionForTesting
                .contains(recordingID)
        }
        let preInterruptionCompleteCount = await files.completeCount
        let preInterruptionPreserveCount = await files.preserveCount
        XCTAssertEqual(preInterruptionCompleteCount, 0)
        XCTAssertEqual(preInterruptionPreserveCount, 0)

        fixture.viewModel.sceneDidEnterBackground()
        try await waitUntil {
            fixture.viewModel.recoverableReviewItems.map(\.id)
                == [recordingID]
        }

        let completeCount = await files.completeCount
        let preserveCount = await files.preserveCount
        XCTAssertEqual(completeCount, 0)
        XCTAssertEqual(preserveCount, 1)
        XCTAssertEqual(backgroundTasks.beginCount, 1)
        XCTAssertEqual(backgroundTasks.endCount, 1)
        XCTAssertEqual(
            fixture.viewModel.interruptionEpisode?.recordingID,
            recordingID
        )
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
    }

    func testDidFinishThenForegroundThenBackgroundStillReconciles()
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

        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel
                .finalizedRecordingsAwaitingDispositionForTesting
                .contains(recordingID)
        }
        fixture.viewModel.sceneDidBecomeActive()
        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)

        fixture.viewModel.sceneDidEnterBackground()
        try await waitUntil {
            fixture.viewModel.recoverableReviewItems.map(\.id)
                == [recordingID]
        }

        let preserveCount = await files.preserveCount
        let completeCount = await files.completeCount
        XCTAssertEqual(preserveCount, 1)
        XCTAssertEqual(completeCount, 0)
    }

    func testDuplicateDidFinishCannotCommitOrPublishTwice()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        await files.setSuspendsPreservation(true)
        let fixture = makeFixture(capture: capture, files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        fixture.viewModel.sceneDidEnterBackground()
        await capture.finish(recordingID: recordingID)
        try await waitUntil { await files.preserveCount == 1 }
        await capture.reemitLastFinished()
        await files.resumeSuspendedPreservations()

        try await waitUntil {
            fixture.viewModel.recoverableReviewItems.map(\.id)
                == [recordingID]
        }
        try await waitUntil {
            fixture.viewModel.ignoredFinalizationCallbackCountForTesting == 1
        }
        let preserveCount = await files.preserveCount
        XCTAssertEqual(preserveCount, 1)
        XCTAssertEqual(fixture.viewModel.recoverableReviewItems.count, 1)
    }

    func testNormalStopBeforeBackgroundRemainsNormalCompletion()
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
        try await waitUntil { await capture.stopRecordingCount == 1 }
        fixture.viewModel.sceneDidEnterBackground()
        await capture.finish(recordingID: recordingID)
        try await waitUntil { await files.completeCount == 1 }

        let preserveCount = await files.preserveCount
        XCTAssertEqual(preserveCount, 0)
        XCTAssertEqual(
            fixture.viewModel.completedRecording?.recordingID,
            recordingID
        )
        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
    }

    func testDidFinishBeforeExplicitStopStillCompletesNormally()
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

        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel
                .finalizedRecordingsAwaitingDispositionForTesting
                .contains(recordingID)
        }

        fixture.viewModel.stopRecording()
        try await waitUntil { await files.completeCount == 1 }

        let captureStopCount = await capture.stopRecordingCount
        let preserveCount = await files.preserveCount
        XCTAssertEqual(captureStopCount, 0)
        XCTAssertEqual(preserveCount, 0)
        XCTAssertEqual(
            fixture.viewModel.completedRecording?.recordingID,
            recordingID
        )
        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)
    }

    func testBackgroundExpiryBeforeDidFinishDoesNotPublishFalseCard()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        let backgroundTasks = TestRecordingBackgroundTaskManager()
        let fixture = makeFixture(
            capture: capture,
            files: files,
            backgroundTasks: backgroundTasks
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        fixture.viewModel.sceneDidEnterBackground()
        try await waitUntil { backgroundTasks.activeCount == 1 }
        backgroundTasks.expireActiveTask()
        await capture.finish(recordingID: recordingID)
        try await waitUntil { fixture.viewModel.canRetryPreparation }

        let preserveCount = await files.preserveCount
        XCTAssertEqual(preserveCount, 0)
        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
    }

    func testBackgroundDidFinishAfterForegroundStillPublishesOnce()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        let backgroundTasks = TestRecordingBackgroundTaskManager()
        let fixture = makeFixture(
            capture: capture,
            files: files,
            backgroundTasks: backgroundTasks
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        fixture.viewModel.sceneDidEnterBackground()
        try await waitUntil { backgroundTasks.activeCount == 1 }
        fixture.viewModel.sceneDidBecomeActive()
        try await waitUntil {
            let foregroundCount = await capture.foregroundCount
            let recoverCount = await files.recoverCount
            return foregroundCount == 1 && recoverCount >= 2
        }
        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)

        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel.recoverableReviewItems.map(\.id)
                == [recordingID]
                && backgroundTasks.activeCount == 0
        }

        XCTAssertEqual(fixture.viewModel.recoverableReviewItems.count, 1)
        XCTAssertEqual(backgroundTasks.activeCount, 0)
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
    }

    func testBackgroundTaskExpiryBeforeManifestNeverPublishesFalseSuccess()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        await files.setSuspendsPreservation(true)
        let backgroundTasks = TestRecordingBackgroundTaskManager()
        let fixture = makeFixture(
            capture: capture,
            files: files,
            backgroundTasks: backgroundTasks
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        fixture.viewModel.sceneDidEnterBackground()
        await capture.finish(recordingID: recordingID)
        try await waitUntil { await files.preserveCount == 1 }
        backgroundTasks.expireActiveTask()

        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
        XCTAssertTrue(
            fixture.viewModel.interruptionNoticeMessage?.contains(
                "尚不能确认恢复片段"
            ) == true
        )

        await files.resumeSuspendedPreservations()
        try await waitUntil {
            fixture.viewModel.recoverableReviewItems.map(\.id)
                == [recordingID]
        }
        XCTAssertEqual(fixture.viewModel.recoverableReviewItems.count, 1)
    }

    func testForegroundRescanDoesNotDuplicateCommittedRecoveryCard()
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

        fixture.viewModel.sceneDidEnterBackground()
        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel.recoverableReviewItems.count == 1
        }
        fixture.viewModel.sceneDidBecomeActive()
        try await waitUntil { await files.recoverCount >= 3 }

        XCTAssertEqual(
            fixture.viewModel.recoverableReviewItems.map(\.id),
            [recordingID]
        )
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
    }

    func testBackgroundManifestFailureKeepsRetryWithoutSuccessCard()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        await files.setShouldFailPreserve(true)
        let fixture = makeFixture(capture: capture, files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        fixture.viewModel.sceneDidEnterBackground()
        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel.canRetryPreparation
                && fixture.viewModel.shouldShowManualReprepare
                && fixture.viewModel.interruptionNoticeMessage?.contains(
                    "无法确认"
                ) == true
        }

        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
        XCTAssertFalse(
            fixture.viewModel.noticeMessage?.contains("发现中断录制片段")
                == true
        )
    }

    func testInvalidFinalizedFileNeverPublishesRecoveryCard()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        await files.setRejectsInvalidTemporaryFile(true)
        let fixture = makeFixture(capture: capture, files: files)
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        fixture.viewModel.sceneDidEnterBackground()
        await capture.finish(recordingID: recordingID)
        try await waitUntil {
            fixture.viewModel.canRetryPreparation
                && fixture.viewModel.shouldShowManualReprepare
                && fixture.viewModel.interruptionNoticeMessage?.contains(
                    "无法确认"
                ) == true
        }

        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
        XCTAssertTrue(
            fixture.viewModel.interruptionNoticeMessage?.contains(
                "无法确认"
            ) == true
        )
    }

    func testOldBackgroundExpirationCannotPolluteNewLifecycle()
        async throws
    {
        let capture = TestCaptureSession()
        let backgroundTasks = TestRecordingBackgroundTaskManager()
        let fixture = makeFixture(
            capture: capture,
            backgroundTasks: backgroundTasks
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        let recordingID = try await waitForRecordingID(
            viewModel: fixture.viewModel
        )

        fixture.viewModel.sceneDidEnterBackground()
        await capture.finish(recordingID: recordingID)
        try await waitUntil { fixture.viewModel.canRetryPreparation }
        await fixture.viewModel.retryPreparation()
        try await waitUntil { fixture.viewModel.state == .ready }

        backgroundTasks.invokeLastEndedExpirationForTesting()

        XCTAssertEqual(fixture.viewModel.state, .ready)
        XCTAssertFalse(fixture.viewModel.requiresManualReprepare)
        XCTAssertNil(fixture.viewModel.interruptionEpisode)
    }

    func testForegroundScanWithoutCommittedCardKeepsManualReprepare()
        async throws
    {
        let capture = TestCaptureSession()
        let files = TestRecordingFileStore()
        let backgroundTasks = TestRecordingBackgroundTaskManager()
        let fixture = makeFixture(
            capture: capture,
            files: files,
            backgroundTasks: backgroundTasks
        )
        await fixture.viewModel.prepare()
        try await waitUntil { fixture.viewModel.state == .ready }
        fixture.viewModel.startRecording()
        _ = try await waitForRecordingID(viewModel: fixture.viewModel)

        fixture.viewModel.sceneDidEnterBackground()
        try await waitUntil { backgroundTasks.activeCount == 1 }
        backgroundTasks.expireActiveTask()
        fixture.viewModel.sceneDidBecomeActive()
        try await waitUntil { await files.recoverCount >= 2 }

        XCTAssertTrue(fixture.viewModel.recoverableReviewItems.isEmpty)
        XCTAssertTrue(fixture.viewModel.shouldShowManualReprepare)
        XCTAssertTrue(fixture.viewModel.canRetryPreparation)
    }

    private func makeFixture(
        permissions: TestCapturePermissions = TestCapturePermissions(),
        capture: TestCaptureSession = TestCaptureSession(),
        files: TestRecordingFileStore = TestRecordingFileStore(),
        recoverableMediaValidator: TestRecoverableMediaValidator =
            TestRecoverableMediaValidator(),
        storage: TestStorageSpace = TestStorageSpace(
            capacities: [Int64.max]
        ),
        photos: TestPhotoLibrary = TestPhotoLibrary(result: .saved),
        audio: TestAudioSession = TestAudioSession(),
        backgroundTasks: TestRecordingBackgroundTaskManager =
            TestRecordingBackgroundTaskManager(),
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
            recoverableMediaValidator: recoverableMediaValidator,
            storage: storage,
            photos: photos,
            audio: audio,
            backgroundTasks: backgroundTasks,
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

    private func recordLifecycleTestStage(
        _ stage: String,
        viewModel: CameraRecordingViewModel
    ) {
        #if DEBUG
        print(
            "TAKEFLOW_LIFECYCLE_TEST_STAGE name=\(stage) "
                + "state=\(viewModel.state)"
        )
        #endif
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
private final class TestRecordingBackgroundTaskManager:
    RecordingBackgroundTaskManaging
{
    private var expirationHandlers:
        [RecordingBackgroundTaskToken: @MainActor @Sendable () -> Void] = [:]
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private var lastEndedExpirationHandler:
        (@MainActor @Sendable () -> Void)?

    func beginRecordingFinalization(
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> RecordingBackgroundTaskToken? {
        beginCount += 1
        let token = RecordingBackgroundTaskToken()
        expirationHandlers[token] = expirationHandler
        return token
    }

    func endRecordingFinalization(_ token: RecordingBackgroundTaskToken) {
        guard let handler = expirationHandlers.removeValue(forKey: token) else {
            return
        }
        lastEndedExpirationHandler = handler
        endCount += 1
    }

    func expireActiveTask() {
        guard let (token, handler) = expirationHandlers.first else {
            return
        }
        expirationHandlers.removeValue(forKey: token)
        endCount += 1
        handler()
    }

    var activeCount: Int {
        expirationHandlers.count
    }

    func invokeLastEndedExpirationForTesting() {
        lastEndedExpirationHandler?()
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
    private var lastFinished:
        (id: UUID, url: URL, sessionID: UUID, duration: TimeInterval)?
    private var sessionsPendingStopAfterRecording: Set<UUID> = []
    private var suspendsPreview = false
    private var suspendedPreviewContinuations:
        [UUID: CheckedContinuation<Void, Never>] = [:]
    private var suspendsCameraSwitch = false
    private var suspendedCameraSwitchContinuations:
        [(
            sessionID: UUID,
            continuation: CheckedContinuation<Void, Never>
        )] = []
    private var suspendsFocusLock = false
    private var suspendedFocusLockContinuations:
        [(
            sessionID: UUID,
            continuation: CheckedContinuation<Void, Never>
        )] = []
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
            finishEvents(for: sessionID)
            return
        }
        guard active == nil else {
            sessionsPendingStopAfterRecording.insert(sessionID)
            return
        }
        completeSessionStop(sessionID: sessionID)
    }

    func setSuspendsPreview(_ suspends: Bool) {
        suspendsPreview = suspends
        if !suspends {
            resumeSuspendedPreviews()
        }
    }

    func suspendedPreviewCount() -> Int {
        suspendedPreviewContinuations.count
    }

    func resumeSuspendedPreviews() {
        suspendsPreview = false
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
        continuations.forEach { $0.continuation.resume() }
    }

    func setSuspendsFocusLock(_ suspends: Bool) {
        suspendsFocusLock = suspends
    }

    func resumeSuspendedFocusLocks() {
        suspendsFocusLock = false
        let continuations = suspendedFocusLockContinuations
        suspendedFocusLockContinuations.removeAll()
        continuations.forEach { $0.continuation.resume() }
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
                suspendedCameraSwitchContinuations.append(
                    (sessionID, continuation)
                )
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
            if sessionsPendingStopAfterRecording.contains(
                recording.sessionID
            ) {
                completeSessionStop(sessionID: recording.sessionID)
            }
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
                suspendedFocusLockContinuations.append(
                    (sessionID, continuation)
                )
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
        let recording = active
        let url: URL
        if recording?.id == recordingID {
            url = recording?.url
                ?? URL(fileURLWithPath: "/tmp/capture.mov")
            active = nil
        } else {
            url = URL(fileURLWithPath: "/tmp/stale.mov")
        }
        let sessionID = recording?.sessionID ?? activeSessionID
        if let sessionID {
            lastFinished = (recordingID, url, sessionID, duration)
            continuations[sessionID]?.yield(
                .recordingFinished(
                    recordingID: recordingID,
                    outputURL: url,
                    duration: duration
                )
            )
            if sessionsPendingStopAfterRecording.contains(sessionID) {
                completeSessionStop(sessionID: sessionID)
            }
        }
    }

    func reemitLastFinished() {
        guard let lastFinished else {
            return
        }
        continuations[lastFinished.sessionID]?.yield(
            .recordingFinished(
                recordingID: lastFinished.id,
                outputURL: lastFinished.url,
                duration: lastFinished.duration
            )
        )
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

    func emitInterruptionEnded(to sessionID: UUID) {
        continuations[sessionID]?.yield(
            .interruptionEnded(reason: .unknown)
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

    func activeEventStreamCount() -> Int {
        continuations.count
    }

    private func completeSessionStop(sessionID: UUID) {
        sessionsPendingStopAfterRecording.remove(sessionID)
        if activeSessionID == sessionID {
            activeSessionID = nil
            configuration = nil
        }
        suspendedPreviewContinuations.removeValue(
            forKey: sessionID
        )?.resume()
        let cameraSwitches = suspendedCameraSwitchContinuations.filter {
            $0.sessionID == sessionID
        }
        suspendedCameraSwitchContinuations.removeAll {
            $0.sessionID == sessionID
        }
        cameraSwitches.forEach { $0.continuation.resume() }
        let focusLocks = suspendedFocusLockContinuations.filter {
            $0.sessionID == sessionID
        }
        suspendedFocusLockContinuations.removeAll {
            $0.sessionID == sessionID
        }
        focusLocks.forEach { $0.continuation.resume() }
        finishEvents(for: sessionID)
    }

    private func finishEvents(for sessionID: UUID) {
        continuations.removeValue(forKey: sessionID)?.finish()
    }

}

private actor TestRecordingFileStore: RecordingFileStoring {
    private(set) var createCount = 0
    private(set) var completeCount = 0
    private(set) var markStartedCount = 0
    private(set) var preserveCount = 0
    private(set) var recoverCount = 0
    private(set) var completedRecordings: [CompletedRecording] = []
    private(set) var deletedProjectIDs: [UUID] = []
    private(set) var retainedRecoverableIDs: [UUID] = []
    private(set) var deletedRecoverableIDs: [UUID] = []
    private var pendingRecoverables: [RecoverableRecording] = []
    private var shouldFailRetain = false
    private var shouldFailDelete = false
    private var shouldFailPreserve = false
    private var rejectsInvalidTemporaryFile = false
    private var suspendsCompletion = false
    private var completionContinuations:
        [CheckedContinuation<Void, Never>] = []
    private var suspendsPreservation = false
    private var preservationContinuations:
        [CheckedContinuation<Void, Never>] = []

    func setSuspendsCompletion(_ suspends: Bool) {
        suspendsCompletion = suspends
    }

    func retainedIDs() -> [UUID] {
        retainedRecoverableIDs
    }

    func resumeSuspendedCompletions() {
        suspendsCompletion = false
        let continuations = completionContinuations
        completionContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func setSuspendsPreservation(_ suspends: Bool) {
        suspendsPreservation = suspends
    }

    func resumeSuspendedPreservations() {
        suspendsPreservation = false
        let continuations = preservationContinuations
        preservationContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func setShouldFailPreserve(_ shouldFail: Bool) {
        shouldFailPreserve = shouldFail
    }

    func setRejectsInvalidTemporaryFile(_ rejects: Bool) {
        rejectsInvalidTemporaryFile = rejects
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
        if suspendsPreservation {
            await withCheckedContinuation { continuation in
                preservationContinuations.append(continuation)
            }
        }
        if shouldFailPreserve || rejectsInvalidTemporaryFile {
            throw CaptureError.fileFinalizationFailed
        }
        let recovered = RecoverableRecording(
            projectID: recording.projectID,
            recordingID: recording.recordingID,
            fileURL: recording.temporaryURL,
            reason: reason,
            discoveredAt: .now
        )
        pendingRecoverables.append(recovered)
        return recovered
    }

    func recoverPendingRecordings() async -> [RecoverableRecording] {
        recoverCount += 1
        return pendingRecoverables
    }

    func recoverCommittedRecordings() async -> [RecoverableRecording] {
        recoverCount += 1
        return pendingRecoverables
    }

    func setPendingRecoverables(_ recordings: [RecoverableRecording]) {
        pendingRecoverables = recordings
    }

    func setShouldFailRetain(_ shouldFail: Bool) {
        shouldFailRetain = shouldFail
    }

    func setShouldFailDelete(_ shouldFail: Bool) {
        shouldFailDelete = shouldFail
    }

    func retainRecoverableRecording(
        _ recording: RecoverableRecording,
        duration: TimeInterval
    ) async throws -> CompletedRecording {
        if shouldFailRetain {
            throw CaptureError.fileFinalizationFailed
        }
        retainedRecoverableIDs.append(recording.recordingID)
        pendingRecoverables.removeAll {
            $0.recordingID == recording.recordingID
        }
        return CompletedRecording(
            projectID: recording.projectID,
            recordingID: recording.recordingID,
            fileURL: URL(fileURLWithPath: "/tmp/retained-\(recording.recordingID).mov"),
            duration: duration,
            completedAt: .now,
            origin: .interruptedRecovery
        )
    }

    func markRecoverableRecordingDamaged(
        _ recording: RecoverableRecording
    ) async throws -> RecoverableRecording {
        var damaged = recording
        damaged.disposition = .damaged
        if let index = pendingRecoverables.firstIndex(where: {
            $0.recordingID == recording.recordingID
        }) {
            pendingRecoverables[index] = damaged
        }
        return damaged
    }

    func deleteRecoverableRecording(
        projectID: UUID,
        recordingID: UUID
    ) async throws {
        if shouldFailDelete {
            throw CaptureError.fileFinalizationFailed
        }
        guard pendingRecoverables.contains(where: {
            $0.projectID == projectID && $0.recordingID == recordingID
        }) else {
            throw CaptureError.fileFinalizationFailed
        }
        deletedRecoverableIDs.append(recordingID)
        pendingRecoverables.removeAll {
            $0.projectID == projectID && $0.recordingID == recordingID
        }
    }

    func deleteProject(projectID: UUID) async throws {
        deletedProjectIDs.append(projectID)
    }
}

private actor TestRecoverableMediaValidator: RecoverableMediaValidating {
    private var results: [UUID: RecoverableMediaValidationResult] = [:]
    private(set) var validationCounts: [UUID: Int] = [:]
    private var suspendedIDs: Set<UUID> = []
    private var continuations:
        [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func setResult(
        _ result: RecoverableMediaValidationResult,
        for recordingID: UUID
    ) {
        results[recordingID] = result
    }

    func validationCount(for recordingID: UUID) -> Int {
        validationCounts[recordingID, default: 0]
    }

    func setSuspended(_ suspended: Bool, for recordingID: UUID) {
        if suspended {
            suspendedIDs.insert(recordingID)
        } else {
            suspendedIDs.remove(recordingID)
            let waiting = continuations.removeValue(forKey: recordingID) ?? []
            waiting.forEach { $0.resume() }
        }
    }

    func validate(
        _ recording: RecoverableRecording
    ) async -> RecoverableMediaValidationResult {
        validationCounts[recording.recordingID, default: 0] += 1
        if suspendedIDs.contains(recording.recordingID) {
            await withCheckedContinuation { continuation in
                continuations[recording.recordingID, default: []]
                    .append(continuation)
            }
        }
        return results[recording.recordingID]
            ?? .playable(
                RecoverableMediaInfo(duration: 2, hasAudioTrack: true)
            )
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
    private(set) var activationCount = 0
    private(set) var deactivationCount = 0

    init() {}

    func currentInputRoute() async -> AudioInputRoute {
        AudioInputRoute(
            name: "测试麦克风",
            isBluetooth: false,
            isAvailable: true
        )
    }

    func activateForRecording() async throws {
        activationCount += 1
    }

    func deactivateAfterRecording() async {
        deactivationCount += 1
        let activeContinuations = Array(continuations.values)
        continuations.removeAll()
        activeContinuations.forEach { $0.finish() }
    }

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

    func activeEventStreamCount() -> Int {
        continuations.count
    }

}

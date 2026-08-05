import AVFoundation
import XCTest
@testable import TakeFlow

@MainActor
final class LocalRecordingPlayerControllerTests: XCTestCase {
    func testRecoverablePreviewRefreshKeepsSinglePlayerSession() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)
        let recordingID = UUID()
        let url = URL(fileURLWithPath: "/tmp/recoverable.recording.mov")

        controller.open(recordingID: recordingID, fileURL: url)
        controller.open(recordingID: recordingID, fileURL: url)
        controller.open(recordingID: recordingID, fileURL: url)

        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(factory.activeSessionCount, 1)
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
    }

    func testRecoverableMoveReleasesTemporaryPlayerBeforeFinalPlayer() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)
        let recordingID = UUID()
        controller.open(
            recordingID: recordingID,
            fileURL: URL(fileURLWithPath: "/tmp/item.recording.mov")
        )
        let temporarySession = factory.sessions[0]

        controller.close()
        controller.open(
            recordingID: recordingID,
            fileURL: URL(fileURLWithPath: "/tmp/item.mov")
        )

        XCTAssertTrue(temporarySession.isReleased)
        XCTAssertFalse(temporarySession.hasCurrentMedia)
        XCTAssertEqual(factory.activeSessionCount, 1)
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
    }

    func testSameRecordingRefreshKeepsSinglePlayerSession() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)
        let recording = makeRecording()

        controller.open(recording)
        let originalSession = factory.sessions.first
        controller.open(recording)
        controller.open(recording)

        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertTrue(factory.sessions.first === originalSession)
        XCTAssertEqual(controller.activeSessionCount, 1)
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
    }

    func testExternalActionPausesRealSessionAndDoesNotAutoResume() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)
        let recording = makeRecording()
        controller.open(recording)
        controller.togglePlayback()
        XCTAssertEqual(controller.playbackState, .playing)

        controller.pauseForExternalAction()
        controller.open(recording)

        let session = factory.sessions[0]
        XCTAssertEqual(session.pauseCount, 1)
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(controller.playbackState, .paused)
        XCTAssertEqual(factory.sessions.count, 1)
    }

    func testSameRecordingStateRefreshesDoNotReplacePlayer() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)
        let recording = makeRecording()
        controller.open(recording)

        for _ in 0..<3 {
            controller.pauseForExternalAction()
            controller.open(recording)
        }

        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(controller.sessionCreationCount, 1)
        XCTAssertEqual(controller.activeSessionCount, 1)
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
    }

    func testRepeatedExternalPausesDoNotAccumulatePlayers() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)
        controller.open(makeRecording())
        controller.togglePlayback()

        for _ in 0..<10 {
            controller.pauseForExternalAction()
        }

        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(factory.sessions[0].pauseCount, 10)
        XCTAssertEqual(factory.activeSessionCount, 1)
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
    }

    func testClosingPreviewStopsAndReleasesCurrentMedia() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)
        controller.open(makeRecording())
        controller.togglePlayback()
        let session = factory.sessions[0]

        controller.close()

        XCTAssertTrue(session.isReleased)
        XCTAssertFalse(session.hasCurrentMedia)
        XCTAssertEqual(session.releaseCount, 1)
        XCTAssertGreaterThanOrEqual(session.pauseCount, 1)
        XCTAssertEqual(controller.activeSessionCount, 0)
        XCTAssertEqual(controller.playbackState, .inactive)
    }

    func testReopeningAfterCloseCreatesExactlyOneNewSession() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)
        let recording = makeRecording()
        controller.open(recording)
        controller.close()

        controller.open(recording)

        XCTAssertEqual(factory.sessions.count, 2)
        XCTAssertTrue(factory.sessions[0].isReleased)
        XCTAssertFalse(factory.sessions[1].isReleased)
        XCTAssertEqual(factory.activeSessionCount, 1)
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
    }

    func testSwitchingRecordingReleasesOldPlayerBeforeCreatingNewOne() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)
        let first = makeRecording()
        let second = makeRecording(
            recordingID: UUID(),
            fileName: "second.mov"
        )
        controller.open(first)
        let firstSession = factory.sessions[0]
        controller.togglePlayback()

        controller.open(second)

        XCTAssertTrue(firstSession.isReleased)
        XCTAssertFalse(firstSession.hasCurrentMedia)
        XCTAssertEqual(controller.recordingID, second.recordingID)
        XCTAssertEqual(factory.activeSessionCount, 1)
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
    }

    func testSharePresentationPausesWithoutReplacingPlayer() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)
        let recording = makeRecording()
        controller.open(recording)
        controller.togglePlayback()

        controller.pauseForExternalAction()
        controller.open(recording)
        controller.pauseForExternalAction()

        XCTAssertEqual(controller.playbackState, .paused)
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(factory.activeSessionCount, 1)
    }

    func testLateEventFromReleasedPlayerCannotChangeNewPlayerState() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)
        controller.open(makeRecording())
        let oldSession = factory.sessions[0]
        controller.open(
            makeRecording(
                recordingID: UUID(),
                fileName: "replacement.mov"
            )
        )
        XCTAssertEqual(controller.playbackState, .paused)

        oldSession.emitRetiredState(.playing)

        XCTAssertEqual(controller.playbackState, .paused)
        XCTAssertEqual(factory.activeSessionCount, 1)
    }

    func testRepeatedOpenCloseAndReplacementNeverExceedsOneSession() {
        let factory = TestLocalRecordingPlayerFactory()
        let controller = LocalRecordingPlayerController(factory: factory)

        for index in 0..<20 {
            controller.open(
                makeRecording(
                    recordingID: UUID(),
                    fileName: "\(index).mov"
                )
            )
            controller.togglePlayback()
            controller.pauseForExternalAction()
            if index.isMultiple(of: 2) {
                controller.close()
            }
        }

        XCTAssertLessThanOrEqual(factory.activeSessionCount, 1)
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
    }

    func testPhotoSaveStartsInSavingState() async throws {
        let fixture = makePhotoSaveFixture()

        fixture.controller.saveToPhotos()

        XCTAssertEqual(fixture.controller.photoSaveState, .saving)
        XCTAssertFalse(fixture.controller.canSaveToPhotos)
        try await waitForSaveCalls(1, photos: fixture.photos)
    }

    func testRepeatedSaveWhileSavingCreatesOneRequest() async throws {
        let fixture = makePhotoSaveFixture()

        for _ in 0..<10 {
            fixture.controller.saveToPhotos()
        }

        try await waitForSaveCalls(1, photos: fixture.photos)
        let saveCallCount = await fixture.photos.saveCallCount
        XCTAssertEqual(saveCallCount, 1)
        XCTAssertFalse(fixture.controller.canSaveToPhotos)
    }

    func testSuccessfulSaveIsOwnedByCurrentPreview() async throws {
        let fixture = makePhotoSaveFixture()

        fixture.controller.saveToPhotos()
        try await waitForSaveCalls(1, photos: fixture.photos)
        await fixture.photos.completeNext(with: .saved)
        try await waitForPhotoState(.saved, controller: fixture.controller)

        XCTAssertEqual(
            fixture.controller.photoSaveState.statusMessage,
            CameraRecordingStrings.savedToPhotos
        )
        XCTAssertEqual(
            fixture.controller.photoSaveState.buttonTitle,
            CameraRecordingStrings.saved
        )
        XCTAssertFalse(fixture.controller.canSaveToPhotos)
    }

    func testSuccessfulSaveKeepsOnlyPlayerPaused() async throws {
        let fixture = makePhotoSaveFixture()
        let session = fixture.factory.sessions[0]
        fixture.controller.togglePlayback()
        XCTAssertEqual(fixture.controller.playbackState, .playing)

        fixture.controller.saveToPhotos()
        try await waitForSaveCalls(1, photos: fixture.photos)
        XCTAssertEqual(fixture.controller.playbackState, .paused)
        await fixture.photos.completeNext(with: .saved)
        try await waitForPhotoState(.saved, controller: fixture.controller)

        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(fixture.controller.playbackState, .paused)
        XCTAssertEqual(fixture.factory.sessions.count, 1)
        XCTAssertEqual(fixture.factory.maximumActiveSessionCount, 1)
    }

    func testPermissionDenialShowsErrorAndAllowsRetry() async throws {
        let fixture = makePhotoSaveFixture()

        fixture.controller.saveToPhotos()
        try await waitForSaveCalls(1, photos: fixture.photos)
        await fixture.photos.completeNext(with: .permissionDenied)
        try await waitForPhotoState(
            .permissionDenied,
            controller: fixture.controller
        )

        XCTAssertNotEqual(
            fixture.controller.photoSaveState.statusMessage,
            CameraRecordingStrings.savedToPhotos
        )
        XCTAssertTrue(
            fixture.controller.photoSaveState.statusMessage?
                .contains("仍保留在 App 内") == true
        )
        XCTAssertTrue(fixture.controller.canSaveToPhotos)
        XCTAssertTrue(fixture.controller.canControlPlayback)
    }

    func testNonPermissionPhotoWriteFailureKeepsRecordingPreviewShareAndRetryAvailable()
        async throws
    {
        let fixture = makePhotoSaveFixture()
        let fileURL = fixture.recording.fileURL
        try Data("recording-source".utf8).write(
            to: fileURL,
            options: .atomic
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fixture.controller.togglePlayback()
        XCTAssertEqual(fixture.controller.playbackState, .playing)

        fixture.controller.saveToPhotos()
        try await waitForSaveCalls(1, photos: fixture.photos)
        await fixture.photos.completeNext(with: .failed)
        try await waitForPhotoState(.failed, controller: fixture.controller)

        XCTAssertNotEqual(
            fixture.controller.photoSaveState.statusMessage,
            CameraRecordingStrings.savedToPhotos
        )
        XCTAssertTrue(
            fixture.controller.photoSaveState.statusMessage?
                .contains("仍可从 App 内分享") == true
        )
        XCTAssertTrue(fixture.controller.canSaveToPhotos)
        XCTAssertTrue(fixture.controller.canControlPlayback)
        XCTAssertEqual(
            fixture.controller.fileURL,
            fileURL.standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(fixture.factory.sessions.count, 1)
        XCTAssertEqual(fixture.factory.activeSessionCount, 1)
        XCTAssertEqual(fixture.factory.maximumActiveSessionCount, 1)

        fixture.controller.togglePlayback()
        XCTAssertEqual(fixture.controller.playbackState, .playing)
        fixture.controller.pauseForExternalAction()
        XCTAssertEqual(fixture.controller.playbackState, .paused)

        fixture.controller.saveToPhotos()
        fixture.controller.saveToPhotos()
        try await waitForSaveCalls(2, photos: fixture.photos)
        let saveCallCount = await fixture.photos.saveCallCount
        XCTAssertEqual(saveCallCount, 2)
        XCTAssertEqual(fixture.controller.photoSaveState, .saving)
        XCTAssertFalse(fixture.controller.canSaveToPhotos)
        XCTAssertEqual(fixture.factory.sessions.count, 1)
        XCTAssertEqual(fixture.factory.maximumActiveSessionCount, 1)

        await fixture.photos.completeNext(with: .saved)
        try await waitForPhotoState(.saved, controller: fixture.controller)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(fixture.factory.activeSessionCount, 1)
    }

    func testPermissionRepairCanRetryAndReachSaved() async throws {
        let fixture = makePhotoSaveFixture()

        fixture.controller.saveToPhotos()
        try await waitForSaveCalls(1, photos: fixture.photos)
        await fixture.photos.completeNext(with: .permissionDenied)
        try await waitForPhotoState(
            .permissionDenied,
            controller: fixture.controller
        )

        fixture.controller.saveToPhotos()
        try await waitForSaveCalls(2, photos: fixture.photos)
        await fixture.photos.completeNext(with: .saved)
        try await waitForPhotoState(.saved, controller: fixture.controller)

        let saveCallCount = await fixture.photos.saveCallCount
        XCTAssertEqual(saveCallCount, 2)
        XCTAssertEqual(fixture.factory.sessions.count, 1)
    }

    func testCloseRejectsLatePhotoSaveResultAfterReopen() async throws {
        let fixture = makePhotoSaveFixture()
        let recording = fixture.recording
        fixture.controller.saveToPhotos()
        try await waitForSaveCalls(1, photos: fixture.photos)

        fixture.controller.close()
        fixture.controller.open(recording)
        await fixture.photos.completeNext(with: .saved)
        await Task.yield()

        XCTAssertEqual(fixture.controller.photoSaveState, .idle)
        XCTAssertEqual(fixture.controller.recordingID, recording.recordingID)
        XCTAssertEqual(fixture.factory.activeSessionCount, 1)
    }

    func testRecordingSwitchRejectsOldPhotoSaveResult() async throws {
        let fixture = makePhotoSaveFixture()
        fixture.controller.saveToPhotos()
        try await waitForSaveCalls(1, photos: fixture.photos)
        let replacement = makeRecording(
            recordingID: UUID(),
            fileName: "new-preview.mov"
        )

        fixture.controller.open(replacement)
        await fixture.photos.completeNext(with: .saved)
        await Task.yield()

        XCTAssertEqual(fixture.controller.recordingID, replacement.recordingID)
        XCTAssertEqual(fixture.controller.photoSaveState, .idle)
        XCTAssertEqual(fixture.factory.activeSessionCount, 1)
        XCTAssertEqual(fixture.factory.maximumActiveSessionCount, 1)
    }

    func testPhotoStateChangesNeverCreateSecondPlayer() async throws {
        let fixture = makePhotoSaveFixture()
        let recording = fixture.recording

        fixture.controller.saveToPhotos()
        fixture.controller.open(recording)
        try await waitForSaveCalls(1, photos: fixture.photos)
        await fixture.photos.completeNext(with: .failed)
        try await waitForPhotoState(.failed, controller: fixture.controller)
        fixture.controller.open(recording)

        XCTAssertEqual(fixture.factory.sessions.count, 1)
        XCTAssertEqual(fixture.factory.activeSessionCount, 1)
        XCTAssertEqual(fixture.factory.maximumActiveSessionCount, 1)
    }

    func testSavedPreviewRejectsDuplicateSave() async throws {
        let fixture = makePhotoSaveFixture()
        fixture.controller.saveToPhotos()
        try await waitForSaveCalls(1, photos: fixture.photos)
        await fixture.photos.completeNext(with: .saved)
        try await waitForPhotoState(.saved, controller: fixture.controller)

        fixture.controller.saveToPhotos()
        await Task.yield()

        let saveCallCount = await fixture.photos.saveCallCount
        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(fixture.controller.photoSaveState, .saved)
    }

    func testPhotoStatesExposeVoiceOverReadableMessages() {
        XCTAssertEqual(
            LocalRecordingPhotoSaveState.saving.statusMessage,
            CameraRecordingStrings.savingToPhotos
        )
        XCTAssertEqual(
            LocalRecordingPhotoSaveState.saved.statusMessage,
            CameraRecordingStrings.savedToPhotos
        )
        XCTAssertTrue(
            LocalRecordingPhotoSaveState.permissionDenied.statusMessage?
                .contains("添加到照片") == true
        )
        XCTAssertTrue(
            LocalRecordingPhotoSaveState.failed.statusMessage?
                .contains("保存到照片") == true
        )
    }

    private func makePhotoSaveFixture() -> PhotoSaveFixture {
        let factory = TestLocalRecordingPlayerFactory()
        let photos = ControllablePhotoLibrary()
        let controller = LocalRecordingPlayerController(
            factory: factory,
            photos: photos
        )
        let recording = makeRecording()
        controller.open(recording)
        return PhotoSaveFixture(
            controller: controller,
            factory: factory,
            photos: photos,
            recording: recording
        )
    }

    private func waitForSaveCalls(
        _ expected: Int,
        photos: ControllablePhotoLibrary
    ) async throws {
        for _ in 0..<200 {
            if await photos.saveCallCount == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("照片保存服务调用次数未达到 \(expected)")
    }

    private func waitForPhotoState(
        _ expected: LocalRecordingPhotoSaveState,
        controller: LocalRecordingPlayerController
    ) async throws {
        for _ in 0..<200 {
            if controller.photoSaveState == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("照片保存状态未进入 \(expected)")
    }

    private func makeRecording(
        recordingID: UUID = UUID(),
        fileName: String = "recording.mov"
    ) -> CompletedRecording {
        CompletedRecording(
            projectID: UUID(),
            recordingID: recordingID,
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName),
            duration: 5,
            completedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

@MainActor
private struct PhotoSaveFixture {
    let controller: LocalRecordingPlayerController
    let factory: TestLocalRecordingPlayerFactory
    let photos: ControllablePhotoLibrary
    let recording: CompletedRecording
}

private actor ControllablePhotoLibrary: PhotoLibrarySaving {
    private(set) var saveCallCount = 0
    private var pendingContinuations:
        [CheckedContinuation<PhotoSaveResult, Never>] = []

    func authorizationStatus() async -> PermissionState {
        .authorized
    }

    func saveVideo(at url: URL) async -> PhotoSaveResult {
        saveCallCount += 1
        return await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    func completeNext(with result: PhotoSaveResult) {
        guard !pendingContinuations.isEmpty else {
            return
        }
        pendingContinuations.removeFirst().resume(returning: result)
    }
}

@MainActor
private final class TestLocalRecordingPlayerFactory:
    LocalRecordingPlayerCreating
{
    private(set) var sessions: [TestLocalRecordingPlaybackSession] = []
    private(set) var maximumActiveSessionCount = 0

    var activeSessionCount: Int {
        sessions.filter { !$0.isReleased }.count
    }

    func makeSession(
        for fileURL: URL
    ) -> any LocalRecordingPlaybackSession {
        let session = TestLocalRecordingPlaybackSession()
        sessions.append(session)
        maximumActiveSessionCount = max(
            maximumActiveSessionCount,
            activeSessionCount
        )
        return session
    }
}

@MainActor
private final class TestLocalRecordingPlaybackSession:
    LocalRecordingPlaybackSession
{
    let player: AVPlayer? = nil
    private(set) var state: LocalRecordingPlaybackState = .paused
    var stateDidChange:
        ((LocalRecordingPlaybackState) -> Void)? {
        didSet {
            if let stateDidChange {
                retiredStateHandler = stateDidChange
            }
        }
    }
    private var retiredStateHandler:
        ((LocalRecordingPlaybackState) -> Void)?
    private(set) var pauseCount = 0
    private(set) var releaseCount = 0
    private(set) var isReleased = false
    private(set) var hasCurrentMedia = true

    func play() {
        guard !isReleased else {
            return
        }
        publish(.playing)
    }

    func pause() {
        guard !isReleased else {
            return
        }
        pauseCount += 1
        publish(.paused)
    }

    func release() {
        guard !isReleased else {
            return
        }
        isReleased = true
        hasCurrentMedia = false
        releaseCount += 1
        state = .inactive
        stateDidChange?(.inactive)
        stateDidChange = nil
    }

    func emitRetiredState(_ state: LocalRecordingPlaybackState) {
        retiredStateHandler?(state)
    }

    private func publish(_ newState: LocalRecordingPlaybackState) {
        state = newState
        stateDidChange?(newState)
    }
}

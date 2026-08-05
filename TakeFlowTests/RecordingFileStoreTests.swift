import Foundation
import XCTest
@testable import TakeFlow

final class RecordingFileStoreTests: XCTestCase {
    func testCreateUsesUniqueProjectAndRecordingPaths() async throws {
        let fixture = try makeFixture()
        let first = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        let second = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )

        XCTAssertNotEqual(first.projectID, second.projectID)
        XCTAssertNotEqual(first.recordingID, second.recordingID)
        XCTAssertNotEqual(first.temporaryURL, second.temporaryURL)
        XCTAssertTrue(
            first.temporaryURL.lastPathComponent.hasSuffix(
                ".recording.mov"
            )
        )
    }

    func testManifestExistsBeforeRecordingStarts() async throws {
        let fixture = try makeFixture()
        let pending = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .landscapeLeft,
            resolution: .ultraHD4K
        )
        let manifestURL = pending.temporaryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("recording.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testCompletedFileMovesFromTemporaryOnlyAfterFinish() async throws {
        let fixture = try makeFixture()
        let pending = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        try Data("video".utf8).write(to: pending.temporaryURL)
        try await fixture.store.markRecordingStarted(pending)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pending.finalURL.path)
        )
        let completed = try await fixture.store.completeRecording(
            pending,
            duration: 4.5
        )

        XCTAssertEqual(completed.fileURL, pending.finalURL)
        XCTAssertEqual(completed.duration, 4.5)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pending.finalURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pending.temporaryURL.path)
        )
    }

    func testCompletingSecondRecordingKeepsFirstFileIntact()
        async throws
    {
        let fixture = try makeFixture()
        let scriptID = UUID()
        let first = try await fixture.store.createRecording(
            scriptID: scriptID,
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        try Data("first-video".utf8).write(to: first.temporaryURL)
        try await fixture.store.markRecordingStarted(first)
        let firstCompleted = try await fixture.store.completeRecording(
            first,
            duration: 5
        )

        let second = try await fixture.store.createRecording(
            scriptID: scriptID,
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        try Data("second-video".utf8).write(to: second.temporaryURL)
        try await fixture.store.markRecordingStarted(second)
        let secondCompleted = try await fixture.store.completeRecording(
            second,
            duration: 5
        )

        XCTAssertNotEqual(firstCompleted.projectID, secondCompleted.projectID)
        XCTAssertNotEqual(
            firstCompleted.recordingID,
            secondCompleted.recordingID
        )
        XCTAssertNotEqual(firstCompleted.fileURL, secondCompleted.fileURL)
        XCTAssertEqual(
            try Data(contentsOf: firstCompleted.fileURL),
            Data("first-video".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: secondCompleted.fileURL),
            Data("second-video".utf8)
        )
    }

    func testInterruptedFileIsRecoverableAfterStoreRecreation()
        async throws
    {
        let fixture = try makeFixture()
        let pending = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        try Data("partial".utf8).write(to: pending.temporaryURL)
        try await fixture.store.markRecordingStarted(pending)
        _ = try await fixture.store.preserveRecoverableRecording(
            pending,
            reason: .applicationBackgrounded
        )

        let recreated = try RecordingFileStore(rootURL: fixture.root)
        let recovered = await recreated.recoverPendingRecordings()

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.recordingID, pending.recordingID)
        XCTAssertEqual(
            recovered.first?.reason,
            .applicationBackgrounded
        )
    }

    func testIncompleteRecordingIsDiscoveredOnNextLaunch() async throws {
        let fixture = try makeFixture()
        let pending = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        try Data("orphan".utf8).write(to: pending.temporaryURL)
        try await fixture.store.markRecordingStarted(pending)

        let recreated = try RecordingFileStore(rootURL: fixture.root)
        let recovered = await recreated.recoverPendingRecordings()

        XCTAssertEqual(recovered.map(\.recordingID), [pending.recordingID])
        XCTAssertEqual(recovered.first?.reason, .unknown)
    }

    func testForegroundCommittedScanDoesNotPublishOpenOrphan()
        async throws
    {
        let fixture = try makeFixture()
        let pending = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        try Data("open-orphan".utf8).write(to: pending.temporaryURL)
        try await fixture.store.markRecordingStarted(pending)

        let beforePromotion =
            await fixture.store.recoverCommittedRecordings()
        XCTAssertTrue(beforePromotion.isEmpty)

        let startupRecovery = await fixture.store.recoverPendingRecordings()
        XCTAssertEqual(startupRecovery.map(\.recordingID), [pending.recordingID])

        let afterPromotion =
            await fixture.store.recoverCommittedRecordings()
        XCTAssertEqual(afterPromotion.map(\.recordingID), [pending.recordingID])
    }

    func testMultipleRecoverableRecordingsAreAllDiscovered() async throws {
        let fixture = try makeFixture()
        var expected: [UUID] = []
        for reason in [
            CaptureInterruptionReason.applicationBackgrounded,
            .audioSessionInterrupted,
            .mediaServicesReset
        ] {
            let pending = try await fixture.store.createRecording(
                scriptID: UUID(),
                orientation: .portrait,
                resolution: .fullHD1080p
            )
            try Data("partial".utf8).write(to: pending.temporaryURL)
            _ = try await fixture.store.preserveRecoverableRecording(
                pending,
                reason: reason
            )
            expected.append(pending.recordingID)
        }

        let recovered = await fixture.store.recoverPendingRecordings()

        XCTAssertEqual(Set(recovered.map(\.recordingID)), Set(expected))
    }

    func testVersionOneRecoverableManifestRemainsDiscoverable()
        async throws
    {
        let fixture = try makeFixture()
        let pending = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        try Data("legacy-partial".utf8).write(to: pending.temporaryURL)
        _ = try await fixture.store.preserveRecoverableRecording(
            pending,
            reason: .mediaServicesReset
        )
        let manifestURL = pending.temporaryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("recording.json")
        let manifestData = try Data(contentsOf: manifestURL)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any]
        )
        manifest["schemaVersion"] = 1
        let legacyData = try JSONSerialization.data(withJSONObject: manifest)
        try legacyData.write(to: manifestURL, options: .atomic)

        let recreated = try RecordingFileStore(rootURL: fixture.root)
        let recovered = await recreated.recoverPendingRecordings()

        XCTAssertEqual(recovered.map(\.recordingID), [pending.recordingID])
        XCTAssertEqual(recovered.first?.reason, .mediaServicesReset)
        XCTAssertEqual(recovered.first?.disposition, .pendingReview)
    }

    func testRetainingRecoverableMovesFileAndMarksInterruptedOrigin()
        async throws
    {
        let fixture = try makeFixture()
        let pending = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        let contents = Data("recoverable-video".utf8)
        try contents.write(to: pending.temporaryURL)
        let recoverable = try await fixture.store
            .preserveRecoverableRecording(
                pending,
                reason: .applicationBackgrounded
            )

        let retained = try await fixture.store.retainRecoverableRecording(
            recoverable,
            duration: 3.25
        )

        XCTAssertEqual(retained.origin, .interruptedRecovery)
        XCTAssertEqual(retained.duration, 3.25)
        XCTAssertEqual(retained.fileURL, pending.finalURL)
        XCTAssertEqual(try Data(contentsOf: retained.fileURL), contents)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pending.temporaryURL.path)
        )
        let remaining = await fixture.store.recoverPendingRecordings()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRetainFailureKeepsOriginalRecoverableFile() async throws {
        let fixture = try makeFixture()
        let pending = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        try Data("source".utf8).write(to: pending.temporaryURL)
        try Data("collision".utf8).write(to: pending.finalURL)
        let recoverable = try await fixture.store
            .preserveRecoverableRecording(
                pending,
                reason: .unknown
            )

        do {
            _ = try await fixture.store.retainRecoverableRecording(
                recoverable,
                duration: 1
            )
            XCTFail("Expected retention to fail on an existing destination")
        } catch {}

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pending.temporaryURL.path)
        )
        XCTAssertEqual(
            try Data(contentsOf: pending.temporaryURL),
            Data("source".utf8)
        )
        let remaining = await fixture.store.recoverPendingRecordings()
        XCTAssertEqual(remaining.count, 1)
    }

    func testDamagedStatePersistsAndCanStillBeDeleted() async throws {
        let fixture = try makeFixture()
        let pending = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        try Data("damaged".utf8).write(to: pending.temporaryURL)
        let recoverable = try await fixture.store
            .preserveRecoverableRecording(pending, reason: .unknown)
        _ = try await fixture.store.markRecoverableRecordingDamaged(
            recoverable
        )

        let recreated = try RecordingFileStore(rootURL: fixture.root)
        let recovered = await recreated.recoverPendingRecordings()
        XCTAssertEqual(recovered.first?.disposition, .damaged)

        try await recreated.deleteRecoverableRecording(
            projectID: pending.projectID,
            recordingID: pending.recordingID
        )
        let remaining = await recreated.recoverPendingRecordings()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCorruptManifestDoesNotCrashRecovery() async throws {
        let fixture = try makeFixture()
        let corruptDirectory = fixture.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: corruptDirectory,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(
            to: corruptDirectory.appendingPathComponent("recording.json")
        )

        let recovered = await fixture.store.recoverPendingRecordings()

        XCTAssertTrue(recovered.isEmpty)
    }

    func testDeletingOneProjectDoesNotDeleteAnother() async throws {
        let fixture = try makeFixture()
        let first = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )
        let second = try await fixture.store.createRecording(
            scriptID: UUID(),
            orientation: .portrait,
            resolution: .fullHD1080p
        )

        try await fixture.store.deleteProject(projectID: first.projectID)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    first.temporaryURL.deletingLastPathComponent()
                        .deletingLastPathComponent().path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    second.temporaryURL.deletingLastPathComponent()
                        .deletingLastPathComponent().path
            )
        )
    }

    func testDeleteUnknownProjectIsSafeNoOp() async throws {
        let fixture = try makeFixture()

        try await fixture.store.deleteProject(projectID: UUID())

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    private func makeFixture() throws -> (
        root: URL,
        store: RecordingFileStore
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TakeFlow-RecordingTests-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (root, try RecordingFileStore(rootURL: root))
    }
}

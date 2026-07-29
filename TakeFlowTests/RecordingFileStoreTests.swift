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

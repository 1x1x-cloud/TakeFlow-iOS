import Foundation

actor RecordingFileStore: RecordingFileStoring {
    private enum ManifestState: String, Codable {
        case prepared
        case recording
        case completed
        case recoverable
        case retaining
        case retainedInterrupted
        case damaged
    }

    private struct Manifest: Codable {
        var schemaVersion: Int
        let projectID: UUID
        let recordingID: UUID
        let scriptID: UUID
        let createdAt: Date
        var updatedAt: Date
        let orientation: CaptureOrientation
        let resolution: VideoResolution
        let temporaryFileName: String
        let finalFileName: String
        var state: ManifestState
        var duration: TimeInterval
        var interruptionReason: CaptureInterruptionReason?
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { .now }
    ) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
        try Self.prepareDirectory(
            at: self.rootURL,
            fileManager: fileManager
        )
    }

    static func production() throws -> RecordingFileStore {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try RecordingFileStore(
            rootURL: applicationSupportURL
                .appendingPathComponent("TakeFlow", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
        )
    }

    func createRecording(
        scriptID: UUID,
        orientation: CaptureOrientation,
        resolution: VideoResolution
    ) async throws -> PendingRecording {
        let projectID = UUID()
        let recordingID = UUID()
        let directory = try prepareProjectDirectory(projectID: projectID)
        let temporaryURL = directory.temporary.appendingPathComponent(
            "\(recordingID.uuidString).recording.mov",
            isDirectory: false
        )
        let finalURL = directory.segments.appendingPathComponent(
            "\(recordingID.uuidString).mov",
            isDirectory: false
        )
        let createdAt = now()
        let manifest = Manifest(
            schemaVersion: 2,
            projectID: projectID,
            recordingID: recordingID,
            scriptID: scriptID,
            createdAt: createdAt,
            updatedAt: createdAt,
            orientation: orientation,
            resolution: resolution,
            temporaryFileName: temporaryURL.lastPathComponent,
            finalFileName: finalURL.lastPathComponent,
            state: .prepared,
            duration: 0,
            interruptionReason: nil
        )

        do {
            try write(manifest, projectID: projectID)
        } catch {
            try? fileManager.removeItem(at: directory.project)
            throw CaptureError.filePreparationFailed
        }

        return PendingRecording(
            projectID: projectID,
            recordingID: recordingID,
            scriptID: scriptID,
            temporaryURL: temporaryURL,
            finalURL: finalURL,
            createdAt: createdAt,
            orientation: orientation,
            resolution: resolution
        )
    }

    func markRecordingStarted(_ recording: PendingRecording) async throws {
        var manifest = try readManifest(projectID: recording.projectID)
        guard
            manifest.recordingID == recording.recordingID,
            manifest.state == .prepared
        else {
            throw CaptureError.filePreparationFailed
        }
        manifest.state = .recording
        manifest.updatedAt = now()
        try write(manifest, projectID: recording.projectID)
    }

    func completeRecording(
        _ recording: PendingRecording,
        duration: TimeInterval
    ) async throws -> CompletedRecording {
        var manifest = try readManifest(projectID: recording.projectID)
        guard manifest.recordingID == recording.recordingID else {
            throw CaptureError.fileFinalizationFailed
        }

        let sourceURL: URL
        if fileManager.fileExists(atPath: recording.temporaryURL.path) {
            sourceURL = recording.temporaryURL
        } else if fileManager.fileExists(atPath: recording.finalURL.path) {
            sourceURL = recording.finalURL
        } else {
            throw CaptureError.fileFinalizationFailed
        }

        if sourceURL != recording.finalURL {
            do {
                try fileManager.moveItem(
                    at: recording.temporaryURL,
                    to: recording.finalURL
                )
            } catch {
                try? markManifestRecoverable(
                    &manifest,
                    reason: .unknown,
                    projectID: recording.projectID
                )
                throw CaptureError.fileFinalizationFailed
            }
        }

        manifest.state = .completed
        manifest.duration = max(duration, 0)
        manifest.updatedAt = now()
        manifest.interruptionReason = nil

        do {
            try write(manifest, projectID: recording.projectID)
        } catch {
            try? markManifestRecoverable(
                &manifest,
                reason: .unknown,
                projectID: recording.projectID
            )
            throw CaptureError.fileFinalizationFailed
        }

        return CompletedRecording(
            projectID: recording.projectID,
            recordingID: recording.recordingID,
            fileURL: recording.finalURL,
            duration: max(duration, 0),
            completedAt: manifest.updatedAt
        )
    }

    func preserveRecoverableRecording(
        _ recording: PendingRecording,
        reason: CaptureInterruptionReason
    ) async throws -> RecoverableRecording {
        var manifest = try readManifest(projectID: recording.projectID)
        guard manifest.recordingID == recording.recordingID else {
            throw CaptureError.fileFinalizationFailed
        }
        let retainedURL = retainedFileURL(for: recording)
        guard
            let retainedURL,
            isNonEmptyRegularFile(at: retainedURL)
        else {
            throw CaptureError.fileFinalizationFailed
        }
        try markManifestRecoverable(
            &manifest,
            reason: reason,
            projectID: recording.projectID
        )
        return RecoverableRecording(
            projectID: recording.projectID,
            recordingID: recording.recordingID,
            fileURL: retainedURL,
            reason: reason,
            discoveredAt: manifest.updatedAt
        )
    }

    func recoverPendingRecordings() async -> [RecoverableRecording] {
        scanRecoverableRecordings(promotingOrphans: true)
    }

    func recoverCommittedRecordings() async -> [RecoverableRecording] {
        scanRecoverableRecordings(promotingOrphans: false)
    }

    private func scanRecoverableRecordings(
        promotingOrphans: Bool
    ) -> [RecoverableRecording] {
        guard
            let projectURLs = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var recovered: [RecoverableRecording] = []
        for projectURL in projectURLs {
            guard
                let projectID = UUID(uuidString: projectURL.lastPathComponent),
                var manifest = try? readManifest(projectID: projectID),
                manifest.state != .completed,
                manifest.state != .retainedInterrupted
            else {
                continue
            }
            let urls = urls(for: manifest)
            let retainedURL: URL?
            if fileManager.fileExists(atPath: urls.temporary.path) {
                retainedURL = urls.temporary
            } else if fileManager.fileExists(atPath: urls.final.path) {
                retainedURL = urls.final
            } else {
                retainedURL = nil
            }
            guard let retainedURL else {
                continue
            }
            if manifest.state == .prepared || manifest.state == .recording {
                guard
                    promotingOrphans,
                    isNonEmptyRegularFile(at: retainedURL)
                else {
                    continue
                }
                do {
                    try markManifestRecoverable(
                        &manifest,
                        reason: manifest.interruptionReason ?? .unknown,
                        projectID: manifest.projectID
                    )
                } catch {
                    continue
                }
            }
            recovered.append(
                RecoverableRecording(
                    projectID: manifest.projectID,
                    recordingID: manifest.recordingID,
                    fileURL: retainedURL,
                    reason: manifest.interruptionReason ?? .unknown,
                    discoveredAt: manifest.updatedAt,
                    disposition: manifest.state == .damaged
                        ? .damaged : .pendingReview
                )
            )
        }
        return recovered.sorted { $0.discoveredAt < $1.discoveredAt }
    }

    func retainRecoverableRecording(
        _ recording: RecoverableRecording,
        duration: TimeInterval
    ) async throws -> CompletedRecording {
        guard duration.isFinite, duration > 0 else {
            throw CaptureError.fileFinalizationFailed
        }
        var manifest = try readManifest(projectID: recording.projectID)
        guard
            manifest.recordingID == recording.recordingID,
            manifest.state == .recoverable
                || manifest.state == .recording
                || manifest.state == .prepared
                || manifest.state == .retaining
        else {
            throw CaptureError.fileFinalizationFailed
        }
        let locations = urls(for: manifest)
        let sourceURL: URL
        if fileManager.fileExists(atPath: locations.temporary.path) {
            sourceURL = locations.temporary
        } else if fileManager.fileExists(atPath: locations.final.path) {
            sourceURL = locations.final
        } else {
            throw CaptureError.fileFinalizationFailed
        }

        manifest.schemaVersion = 2
        manifest.state = .retaining
        manifest.updatedAt = now()
        try write(manifest, projectID: recording.projectID)

        if sourceURL != locations.final {
            guard !fileManager.fileExists(atPath: locations.final.path) else {
                throw CaptureError.fileFinalizationFailed
            }
            do {
                try fileManager.moveItem(at: sourceURL, to: locations.final)
            } catch {
                throw CaptureError.fileFinalizationFailed
            }
        }

        manifest.state = .retainedInterrupted
        manifest.duration = duration
        manifest.updatedAt = now()
        do {
            try write(manifest, projectID: recording.projectID)
        } catch {
            // The manifest remains in the recoverable `retaining` state and
            // startup scanning finds the file at either supported location.
            throw CaptureError.fileFinalizationFailed
        }
        return CompletedRecording(
            projectID: recording.projectID,
            recordingID: recording.recordingID,
            fileURL: locations.final,
            duration: duration,
            completedAt: manifest.updatedAt,
            origin: .interruptedRecovery
        )
    }

    func markRecoverableRecordingDamaged(
        _ recording: RecoverableRecording
    ) async throws -> RecoverableRecording {
        var manifest = try readManifest(projectID: recording.projectID)
        guard
            manifest.recordingID == recording.recordingID,
            manifest.state != .completed,
            manifest.state != .retainedInterrupted
        else {
            throw CaptureError.fileFinalizationFailed
        }
        manifest.schemaVersion = 2
        manifest.state = .damaged
        manifest.updatedAt = now()
        try write(manifest, projectID: recording.projectID)
        var updated = recording
        updated.disposition = .damaged
        return updated
    }

    func deleteRecoverableRecording(
        projectID: UUID,
        recordingID: UUID
    ) async throws {
        let manifest = try readManifest(projectID: projectID)
        guard
            manifest.recordingID == recordingID,
            manifest.state != .completed,
            manifest.state != .retainedInterrupted
        else {
            throw CaptureError.fileFinalizationFailed
        }
        try await deleteProject(projectID: projectID)
    }

    func deleteProject(projectID: UUID) async throws {
        let projectURL = rootURL.appendingPathComponent(
            projectID.uuidString,
            isDirectory: true
        ).standardizedFileURL
        let expectedParent = projectURL.deletingLastPathComponent()
            .standardizedFileURL
        guard
            expectedParent == rootURL,
            projectURL.lastPathComponent == projectID.uuidString
        else {
            throw CaptureError.fileFinalizationFailed
        }
        guard fileManager.fileExists(atPath: projectURL.path) else {
            return
        }
        try fileManager.removeItem(at: projectURL)
    }

    private func retainedFileURL(for recording: PendingRecording) -> URL? {
        if fileManager.fileExists(atPath: recording.temporaryURL.path) {
            return recording.temporaryURL
        }
        if fileManager.fileExists(atPath: recording.finalURL.path) {
            return recording.finalURL
        }
        return nil
    }

    private func isNonEmptyRegularFile(at url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ),
            values.isRegularFile == true,
            let size = values.fileSize,
            size > 0
        else {
            return false
        }
        return true
    }

    private func prepareProjectDirectory(
        projectID: UUID
    ) throws -> (project: URL, temporary: URL, segments: URL) {
        let project = rootURL.appendingPathComponent(
            projectID.uuidString,
            isDirectory: true
        )
        let temporary = project.appendingPathComponent(
            "Temporary",
            isDirectory: true
        )
        let segments = project.appendingPathComponent(
            "Segments",
            isDirectory: true
        )
        try Self.prepareDirectory(at: temporary, fileManager: fileManager)
        try Self.prepareDirectory(at: segments, fileManager: fileManager)
        return (project, temporary, segments)
    }

    private func write(_ manifest: Manifest, projectID: UUID) throws {
        let data = try JSONEncoder.takeFlowRecording.encode(manifest)
        try data.write(
            to: manifestURL(projectID: projectID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func readManifest(projectID: UUID) throws -> Manifest {
        let data = try Data(contentsOf: manifestURL(projectID: projectID))
        return try JSONDecoder.takeFlowRecording.decode(
            Manifest.self,
            from: data
        )
    }

    private func markManifestRecoverable(
        _ manifest: inout Manifest,
        reason: CaptureInterruptionReason,
        projectID: UUID
    ) throws {
        manifest.schemaVersion = 2
        manifest.state = .recoverable
        manifest.updatedAt = now()
        manifest.interruptionReason = reason
        try write(manifest, projectID: projectID)
    }

    private func manifestURL(projectID: UUID) -> URL {
        rootURL
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("recording.json", isDirectory: false)
    }

    private func urls(
        for manifest: Manifest
    ) -> (temporary: URL, final: URL) {
        let projectURL = rootURL.appendingPathComponent(
            manifest.projectID.uuidString,
            isDirectory: true
        )
        return (
            projectURL
                .appendingPathComponent("Temporary", isDirectory: true)
                .appendingPathComponent(manifest.temporaryFileName),
            projectURL
                .appendingPathComponent("Segments", isDirectory: true)
                .appendingPathComponent(manifest.finalFileName)
        )
    }

    private static func prepareDirectory(
        at url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try? fileManager.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: url.path
        )
    }
}

private extension JSONEncoder {
    static var takeFlowRecording: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var takeFlowRecording: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

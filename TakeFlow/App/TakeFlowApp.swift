import SwiftUI

@main
struct TakeFlowApp: App {
    private let service: any TakeFlowServicing
    private let cameraRecordingDependencies:
        CameraRecordingDependencies

    init() {
        do {
            cameraRecordingDependencies =
                try Self.makeCameraRecordingDependencies()
        } catch {
            AppLogger.error(
                "capture_dependencies_initialization_failed",
                category: .appLifecycle
            )
            cameraRecordingDependencies = .unavailable()
        }
        let recordingFiles = cameraRecordingDependencies.files
        Task {
            let recovered =
                await recordingFiles.recoverPendingRecordings()
            if !recovered.isEmpty {
                AppLogger.info(
                    "recording_recovery_items_discovered",
                    category: .recording
                )
            }
        }

        do {
            let storageConfiguration =
                try Self.makeScriptStorageConfiguration()
            let container = try ScriptModelContainer.make(
                isStoredInMemoryOnly:
                    storageConfiguration.isStoredInMemoryOnly,
                storeURL: storageConfiguration.storeURL
            )
            let repository = SwiftDataScriptRepository(
                modelContainer: container
            )
            let recoveryStore: any ScriptRecoveryDraftStoring
            do {
                recoveryStore = try Self.makeRecoveryStore(
                    storageConfiguration: storageConfiguration
                )
            } catch {
                AppLogger.error(
                    "script_recovery_store_initialization_failed",
                    category: .persistence
                )
                recoveryStore = UnavailableScriptRecoveryDraftStore()
            }
            service = ScriptLibraryService(
                repository: repository,
                recoveryStore: recoveryStore
            )
        } catch {
            AppLogger.error(
                "script_container_initialization_failed",
                category: .persistence
            )
            service = ScriptLibraryService(
                repository: UnavailableScriptRepository(),
                recoveryStore: UnavailableScriptRecoveryDraftStore()
            )
        }
    }

    private struct ScriptStorageConfiguration {
        let isStoredInMemoryOnly: Bool
        let storeURL: URL?
    }

    private static func makeCameraRecordingDependencies() throws
        -> CameraRecordingDependencies
    {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing") {
            return try CameraRecordingDependencies.uiTesting(
                arguments: arguments
            )
        }
#endif
        return try CameraRecordingDependencies.production()
    }

    private static func makeScriptStorageConfiguration() throws
        -> ScriptStorageConfiguration
    {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let usesInMemoryStore = arguments.contains("-ui-testing")
        let persistentStoreURL = try persistentUITestStoreURL(
            arguments: arguments
        )
        return ScriptStorageConfiguration(
            isStoredInMemoryOnly:
                usesInMemoryStore && persistentStoreURL == nil,
            storeURL: persistentStoreURL
        )
#else
        return ScriptStorageConfiguration(
            isStoredInMemoryOnly: false,
            storeURL: nil
        )
#endif
    }

    private static func makeRecoveryStore(
        storageConfiguration: ScriptStorageConfiguration
    ) throws -> any ScriptRecoveryDraftStoring {
#if DEBUG
        if let persistentStoreURL = storageConfiguration.storeURL {
            let directoryURL = persistentStoreURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "\(persistentStoreURL.lastPathComponent)-Recovery",
                    isDirectory: true
                )
            return try FileScriptRecoveryDraftStore(
                directoryURL: directoryURL
            )
        }
        if storageConfiguration.isStoredInMemoryOnly {
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "TakeFlow-UITest-Recovery-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            return try FileScriptRecoveryDraftStore(
                directoryURL: directoryURL
            )
        }
#endif
        return try FileScriptRecoveryDraftStore.production()
    }

#if DEBUG
    private static func persistentUITestStoreURL(
        arguments: [String]
    ) throws -> URL? {
        let prefix = "-ui-testing-persistent-store="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) })
        else {
            return nil
        }

        let rawIdentifier = String(argument.dropFirst(prefix.count))
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard
            !rawIdentifier.isEmpty,
            rawIdentifier.unicodeScalars.allSatisfy(
                allowedCharacters.contains
            )
        else {
            throw AppError.invalidState
        }

        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupportURL.appendingPathComponent(
            "TakeFlow-UITest-\(rawIdentifier).store"
        )
    }
#endif

    var body: some Scene {
        WindowGroup {
            HomeView(
                service: service,
                cameraRecordingDependencies:
                    cameraRecordingDependencies
            )
        }
    }
}

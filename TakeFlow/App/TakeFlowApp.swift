import SwiftUI

@main
struct TakeFlowApp: App {
    private let service: any ScriptLibraryServicing

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let usesInMemoryStore = arguments.contains("-ui-testing")

        do {
            let persistentUITestStoreURL = try Self.persistentUITestStoreURL(
                arguments: arguments
            )
            let container = try ScriptModelContainer.make(
                isStoredInMemoryOnly:
                    usesInMemoryStore && persistentUITestStoreURL == nil,
                storeURL: persistentUITestStoreURL
            )
            let repository = SwiftDataScriptRepository(
                modelContainer: container
            )
            let recoveryStore: any ScriptRecoveryDraftStoring
            do {
                recoveryStore = try Self.makeRecoveryStore(
                    arguments: arguments,
                    persistentUITestStoreURL: persistentUITestStoreURL
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

    private static func makeRecoveryStore(
        arguments: [String],
        persistentUITestStoreURL: URL?
    ) throws -> any ScriptRecoveryDraftStoring {
        if let persistentUITestStoreURL {
            let directoryURL = persistentUITestStoreURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "\(persistentUITestStoreURL.lastPathComponent)-Recovery",
                    isDirectory: true
                )
            return try FileScriptRecoveryDraftStore(
                directoryURL: directoryURL
            )
        }
        if arguments.contains("-ui-testing") {
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "TakeFlow-UITest-Recovery-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            return try FileScriptRecoveryDraftStore(
                directoryURL: directoryURL
            )
        }
        return try FileScriptRecoveryDraftStore.production()
    }

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

    var body: some Scene {
        WindowGroup {
            HomeView(service: service)
        }
    }
}

import Foundation
import SwiftData

enum ScriptModelContainer {
    static let schema = Schema(ScriptSchemaV2.models)

    static func make(
        isStoredInMemoryOnly: Bool = false,
        storeURL: URL? = nil
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration

        if let storeURL {
            configuration = ModelConfiguration(
                "TakeFlow",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
        } else if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                "TakeFlow",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else {
            let applicationSupportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try FileManager.default.createDirectory(
                at: applicationSupportURL,
                withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(
                "TakeFlow",
                schema: schema,
                url: applicationSupportURL.appendingPathComponent(
                    "TakeFlow.store"
                ),
                allowsSave: true,
                cloudKitDatabase: .none
            )
        }

        return try ModelContainer(
            for: schema,
            migrationPlan: TakeFlowSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }
}

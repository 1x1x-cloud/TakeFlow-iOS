import Foundation

struct SystemStorageSpaceService: StorageSpaceChecking {
    private let volumeURL: URL

    init(volumeURL: URL) {
        self.volumeURL = volumeURL
    }

    static func production() throws -> SystemStorageSpaceService {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return SystemStorageSpaceService(volumeURL: applicationSupportURL)
    }

    func availableCapacityForImportantUsage() async throws -> Int64 {
        let values = try volumeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let capacity = values.volumeAvailableCapacityForImportantUsage
        else {
            throw CaptureError.storageSpaceInsufficient
        }
        return capacity
    }
}

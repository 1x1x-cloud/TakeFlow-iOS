import Foundation

protocol ProjectFileManaging: Sendable {
    func prepareProjectDirectory(for projectID: UUID) async throws -> URL
    func removeProjectDirectory(for projectID: UUID) async throws
}

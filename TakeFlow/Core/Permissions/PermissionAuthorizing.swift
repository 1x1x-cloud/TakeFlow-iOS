import Foundation

enum PermissionKind: String, CaseIterable, Sendable {
    case camera
    case microphone
    case speechRecognition
    case photoLibraryAddOnly
}

enum PermissionState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

@MainActor
protocol PermissionAuthorizing: AnyObject {
    func status(for permission: PermissionKind) -> PermissionState
    func request(_ permission: PermissionKind) async -> PermissionState
}

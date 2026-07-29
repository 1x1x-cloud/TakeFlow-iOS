import Foundation
@preconcurrency import Photos

struct SystemPhotoLibraryService: PhotoLibrarySaving {
    func authorizationStatus() async -> PermissionState {
        map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func saveVideo(at url: URL) async -> PhotoSaveResult {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else {
            return .permissionDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(
                    atFileURL: url
                )
            }
            return .saved
        } catch {
            AppLogger.error(
                "photo_library_video_save_failed",
                category: .persistence
            )
            return .failed
        }
    }

    private func map(_ status: PHAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorized, .limited:
            .authorized
        @unknown default:
            .unavailable
        }
    }
}

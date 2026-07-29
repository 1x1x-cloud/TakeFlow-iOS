@preconcurrency import AVFoundation
import Photos

@MainActor
final class SystemPermissionService: PermissionAuthorizing {
    func status(for permission: PermissionKind) -> PermissionState {
        switch permission {
        case .camera:
            map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .photoLibraryAddOnly:
            map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        case .speechRecognition:
            .unavailable
        }
    }

    func request(_ permission: PermissionKind) async -> PermissionState {
        let current = status(for: permission)
        guard current == .notDetermined else {
            return current
        }

        switch permission {
        case .camera:
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            return allowed ? .authorized : .denied
        case .microphone:
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            return allowed ? .authorized : .denied
        case .photoLibraryAddOnly:
            let status = await PHPhotoLibrary.requestAuthorization(
                for: .addOnly
            )
            return map(status)
        case .speechRecognition:
            return .unavailable
        }
    }

    private func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorized:
            .authorized
        @unknown default:
            .unavailable
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

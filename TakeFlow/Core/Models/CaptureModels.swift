import AVFoundation
import Foundation

enum CameraPosition: String, Codable, CaseIterable, Sendable {
    case front
    case back
}

enum CaptureVideoCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case hevc
}

struct CaptureFormatOption: Identifiable, Codable, Hashable, Sendable {
    let resolution: VideoResolution
    let framesPerSecond: Int
    let codec: CaptureVideoCodec

    var id: String {
        "\(resolution.rawValue)-\(framesPerSecond)-\(codec.rawValue)"
    }
}

struct CaptureCapabilities: Codable, Equatable, Sendable {
    var availableFormats: [CaptureFormatOption]
    var supportsFocusPoint: Bool
    var supportsExposurePoint: Bool
    var supportsFocusLock: Bool
    var supportsExposureLock: Bool
    var supportsVideoStabilization: Bool

    static let unavailable = CaptureCapabilities(
        availableFormats: [],
        supportsFocusPoint: false,
        supportsExposurePoint: false,
        supportsFocusLock: false,
        supportsExposureLock: false,
        supportsVideoStabilization: false
    )
}

struct NormalizedCapturePoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

enum CaptureInterruptionReason: String, Codable, CaseIterable, Sendable {
    case applicationBackgrounded
    case audioSessionInterrupted
    case cameraUnavailable
    case audioDeviceInUseByAnotherClient
    case videoDeviceInUseByAnotherClient
    case videoDeviceNotAvailableWithMultipleForegroundApps
    case videoDeviceNotAvailableDueToSystemPressure
    case sensitiveContentMitigationActivated
    case mediaServicesReset
    case storageSpaceLow
    case unknown
}

enum CaptureInterruptionSource: String, Codable, Hashable, Sendable {
    case captureSession
    case audioSession
    case applicationLifecycle
    case storageMonitor
}

struct AudioInputRoute: Codable, Equatable, Sendable {
    let name: String
    let isBluetooth: Bool
    let isAvailable: Bool

    static let unavailable = AudioInputRoute(
        name: "",
        isBluetooth: false,
        isAvailable: false
    )
}

enum AudioSessionEvent: Equatable, Sendable {
    case routeChanged(AudioInputRoute)
    case interruptionBegan
    case interruptionEnded
}

struct CaptureConfiguration: Codable, Equatable, Sendable {
    let position: CameraPosition
    let format: CaptureFormatOption
    let previewMirrored: Bool
    let outputMirrored: Bool
}

struct CapturePreviewSource: @unchecked Sendable {
    let session: AVCaptureSession
    let device: AVCaptureDevice

    init(session: AVCaptureSession, device: AVCaptureDevice) {
        self.session = session
        self.device = device
    }
}

enum CaptureSessionEvent: Sendable {
    case sessionReady(
        source: CapturePreviewSource?,
        configuration: CaptureConfiguration,
        capabilities: CaptureCapabilities
    )
    case duration(recordingID: UUID, seconds: TimeInterval)
    case recordingFinished(
        recordingID: UUID,
        outputURL: URL,
        duration: TimeInterval
    )
    case recordingFailed(
        recordingID: UUID,
        outputURL: URL?,
        error: CaptureError
    )
    case interrupted(
        recordingID: UUID?,
        reason: CaptureInterruptionReason,
        outputURL: URL?
    )
    case interruptionEnded(reason: CaptureInterruptionReason?)
    case audioRouteChanged(AudioInputRoute)
    case mediaServicesReset
}

enum PhotoSaveResult: Equatable, Sendable {
    case saved
    case permissionDenied
    case failed
}

enum CaptureFormatSelector {
    static func select(
        preferredResolution: VideoResolution,
        supportedResolutions: Set<VideoResolution>,
        availableCodecs: Set<CaptureVideoCodec>
    ) -> CaptureFormatOption? {
        let resolution: VideoResolution
        if supportedResolutions.contains(preferredResolution) {
            resolution = preferredResolution
        } else if supportedResolutions.contains(.fullHD1080p) {
            resolution = .fullHD1080p
        } else {
            return nil
        }

        let codecPreference: [CaptureVideoCodec] =
            resolution == .ultraHD4K ? [.hevc, .h264] : [.h264, .hevc]
        guard
            let codec = codecPreference.first(
                where: availableCodecs.contains
            )
        else {
            return nil
        }
        return CaptureFormatOption(
            resolution: resolution,
            framesPerSecond: 30,
            codec: codec
        )
    }
}

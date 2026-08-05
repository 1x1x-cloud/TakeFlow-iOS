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
    var supportsContinuousFocus: Bool
    var supportsContinuousExposure: Bool
    var supportsVideoStabilization: Bool

    static let unavailable = CaptureCapabilities(
        availableFormats: [],
        supportsFocusPoint: false,
        supportsExposurePoint: false,
        supportsFocusLock: false,
        supportsExposureLock: false,
        supportsContinuousFocus: false,
        supportsContinuousExposure: false,
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

struct CapturePointAdjustmentResult: Equatable, Sendable {
    let focusApplied: Bool
    let exposureApplied: Bool

    var didApplyAnyAdjustment: Bool {
        focusApplied || exposureApplied
    }
}

struct CaptureFocusExposureLockState: Equatable, Sendable {
    let focusLocked: Bool
    let exposureLocked: Bool

    var isFullyLocked: Bool {
        focusLocked && exposureLocked
    }
}

enum CaptureInterruptionReason: String, Codable, CaseIterable, Hashable,
    Sendable
{
    case applicationBackgrounded
    case audioSessionInterrupted
    case cameraUnavailable
    case audioDeviceInUseByAnotherClient
    case videoDeviceInUseByAnotherClient
    case videoDeviceNotAvailableWithMultipleForegroundApps
    case videoDeviceNotAvailableDueToSystemPressure
    case sensitiveContentMitigationActivated
    case mediaServicesLost
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

enum InterruptionEpisodeSource: String, Codable, Hashable, Sendable {
    case applicationBackgrounded
    case captureSession
    case audioSession
    case cameraInUseByAnotherClient
    case microphoneInUseByAnotherClient
    case systemPressure
    case mediaServices
    case unknownSystem
}

struct AudioInterruptionDetails: Equatable, Sendable {
    let rawType: UInt?
    let rawReason: UInt?
    let wasSuspended: Bool

    static let unspecified = AudioInterruptionDetails(
        rawType: nil,
        rawReason: nil,
        wasSuspended: false
    )
}

struct InterruptionEpisode: Equatable, Sendable {
    let id: UUID
    var recordingID: UUID?
    let captureSessionID: UUID
    let lifecycleGeneration: UInt64
    private(set) var sources: Set<InterruptionEpisodeSource>
    private(set) var reasons: Set<CaptureInterruptionReason>
    let firstOccurredAt: Date
    private(set) var occurredDuringRecording: Bool
    private(set) var didRequestFinalization: Bool
    private(set) var didFinishAVFoundationFinalization: Bool
    private(set) var didResolveAVFoundationFinalization: Bool
    private(set) var didCommitRecoveryManifest: Bool
    private(set) var didResolveRecoveryManifest: Bool
    private(set) var requiresManualReprepare: Bool
    private(set) var primaryReason: CaptureInterruptionReason

    init(
        id: UUID = UUID(),
        recordingID: UUID?,
        captureSessionID: UUID,
        lifecycleGeneration: UInt64,
        source: InterruptionEpisodeSource,
        reason: CaptureInterruptionReason,
        occurredDuringRecording: Bool,
        firstOccurredAt: Date = .now
    ) {
        self.id = id
        self.recordingID = recordingID
        self.captureSessionID = captureSessionID
        self.lifecycleGeneration = lifecycleGeneration
        sources = [source]
        reasons = [reason]
        self.firstOccurredAt = firstOccurredAt
        self.occurredDuringRecording = occurredDuringRecording
        didRequestFinalization = false
        didFinishAVFoundationFinalization = false
        didResolveAVFoundationFinalization = false
        didCommitRecoveryManifest = false
        didResolveRecoveryManifest = false
        requiresManualReprepare = true
        primaryReason = reason
    }

    mutating func merge(
        source: InterruptionEpisodeSource,
        reason: CaptureInterruptionReason,
        recordingID: UUID?,
        occurredDuringRecording: Bool = false
    ) {
        sources.insert(source)
        reasons.insert(reason)
        if self.recordingID == nil {
            self.recordingID = recordingID
        }
        if occurredDuringRecording {
            self.occurredDuringRecording = true
        }
        if Self.priority(of: reason) > Self.priority(of: primaryReason) {
            primaryReason = reason
        }
    }

    mutating func requestFinalizationIfNeeded() -> Bool {
        guard
            recordingID != nil,
            !didRequestFinalization,
            !didResolveAVFoundationFinalization
        else {
            return false
        }
        didRequestFinalization = true
        return true
    }

    mutating func markAVFoundationFinalized() {
        didFinishAVFoundationFinalization = true
        didResolveAVFoundationFinalization = true
    }

    mutating func markAVFoundationFinalizationFailed() {
        didResolveAVFoundationFinalization = true
    }

    mutating func markRecoveryManifestCommitted() {
        didCommitRecoveryManifest = true
        didResolveRecoveryManifest = true
    }

    mutating func markRecoveryManifestFailed() {
        didResolveRecoveryManifest = true
    }

    mutating func markRecoveryManifestNotRequired() {
        didResolveRecoveryManifest = true
    }

    mutating func clearManualReprepareAfterNewSessionReady() {
        requiresManualReprepare = false
    }

    var isWaitingForRecoveryCommit: Bool {
        guard recordingID != nil else {
            return false
        }
        return !didResolveAVFoundationFinalization
            || (occurredDuringRecording && !didResolveRecoveryManifest)
    }

    static func source(
        for reason: CaptureInterruptionReason
    ) -> InterruptionEpisodeSource {
        switch reason {
        case .applicationBackgrounded:
            .applicationBackgrounded
        case .audioSessionInterrupted:
            .audioSession
        case .audioDeviceInUseByAnotherClient:
            .microphoneInUseByAnotherClient
        case .videoDeviceInUseByAnotherClient,
             .videoDeviceNotAvailableWithMultipleForegroundApps:
            .cameraInUseByAnotherClient
        case .videoDeviceNotAvailableDueToSystemPressure,
             .sensitiveContentMitigationActivated:
            .systemPressure
        case .mediaServicesReset:
            .mediaServices
        case .mediaServicesLost:
            .mediaServices
        case .cameraUnavailable, .unknown, .storageSpaceLow:
            .unknownSystem
        }
    }

    private static func priority(
        of reason: CaptureInterruptionReason
    ) -> Int {
        switch reason {
        case .mediaServicesLost, .mediaServicesReset:
            600
        case .videoDeviceNotAvailableDueToSystemPressure,
             .sensitiveContentMitigationActivated:
            500
        case .applicationBackgrounded:
            400
        case .videoDeviceInUseByAnotherClient,
             .videoDeviceNotAvailableWithMultipleForegroundApps:
            300
        case .audioDeviceInUseByAnotherClient:
            220
        case .audioSessionInterrupted:
            200
        case .cameraUnavailable, .unknown, .storageSpaceLow:
            100
        }
    }
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
    case interruptionBegan(AudioInterruptionDetails)
    case interruptionEnded(AudioInterruptionDetails)
    case mediaServicesWereLost
    case mediaServicesWereReset
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
    case recordingStarted(recordingID: UUID)
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

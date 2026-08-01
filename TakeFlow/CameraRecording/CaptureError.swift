import Foundation

enum CaptureError: Error, Equatable, Sendable {
    case permissionDenied(PermissionKind)
    case permissionRestricted(PermissionKind)
    case permissionUnavailable(PermissionKind)
    case cameraUnavailable
    case microphoneUnavailable
    case preparationTimedOut
    case recordingStartTimedOut
    case unsupportedConfiguration
    case invalidTransition
    case alreadyRecording
    case notRecording
    case cameraSwitchDuringRecording
    case focusUnsupported
    case exposureUnsupported
    case storageSpaceInsufficient
    case recordingFailed
    case filePreparationFailed
    case fileFinalizationFailed
    case photoPermissionDenied
    case photoSaveFailed
    case staleCallback
    case sessionInterrupted(CaptureInterruptionReason)
}

extension CaptureError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .permissionDenied(.camera):
            "摄像头权限已关闭。请在系统设置中允许“一遍成”使用摄像头。"
        case .permissionDenied(.microphone):
            "麦克风权限已关闭。没有可用麦克风时不会开始录制。"
        case .permissionDenied:
            "所需权限已关闭。"
        case .permissionRestricted:
            "此设备限制了所需权限。"
        case .permissionUnavailable:
            "此设备无法提供所需权限。"
        case .cameraUnavailable:
            "当前没有可用摄像头。"
        case .microphoneUnavailable:
            "当前没有可用麦克风，录制尚未开始。"
        case .preparationTimedOut:
            "摄像头准备超时。请确认没有其他 App 占用摄像头，然后重新尝试。"
        case .recordingStartTimedOut:
            "录制启动超时，媒体尚未开始写入。请重新准备摄像头后再试。"
        case .unsupportedConfiguration:
            "当前设备不支持所选录制配置。"
        case .invalidTransition:
            "当前状态不能执行此操作。"
        case .alreadyRecording:
            "录制已在进行中。"
        case .notRecording:
            "当前没有正在进行的录制。"
        case .cameraSwitchDuringRecording:
            "录制期间不能切换摄像头。"
        case .focusUnsupported:
            "当前摄像头不支持点击对焦。"
        case .exposureUnsupported:
            "当前摄像头不支持点击曝光。"
        case .storageSpaceInsufficient:
            "存储空间不足，无法安全录制。"
        case .recordingFailed:
            "录制未能正常完成，已保留可恢复的内容。"
        case .filePreparationFailed:
            "无法准备安全的录制文件。"
        case .fileFinalizationFailed:
            "录制文件未能完成整理，已保留原始内容供恢复。"
        case .photoPermissionDenied:
            "没有“添加到照片”的权限，视频仍保留在 App 内并可分享。"
        case .photoSaveFailed:
            "视频未能保存到照片，仍可从 App 内分享。"
        case .staleCallback:
            "已忽略过期的录制回调。"
        case .sessionInterrupted(.storageSpaceLow):
            "存储空间不足，录制已安全停止。"
        case .sessionInterrupted(.applicationBackgrounded):
            "App 进入后台，录制已停止且不会自动继续。"
        case .sessionInterrupted:
            "录制受到系统中断，已尽可能保留写入内容。"
        }
    }
}

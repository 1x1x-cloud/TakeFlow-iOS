import Foundation

enum CameraRecordingStrings {
    static let title = "摄像提词"
    static let preparing = "正在准备摄像头…"
    static let ready = "预览已就绪"
    static let record = "开始录制"
    static let stop = "停止录制"
    static let retry = "重新尝试"
    static let switchCamera = "切换前后摄像头"
    static let focusLock = "锁定焦点和曝光"
    static let focusUnlocked = "焦点和曝光自动调整"
    static let saveToPhotos = "保存到照片"
    static let share = "分享视频"
    static let localPreview = "本地录制预览"
    static let close = "返回稿件"
    static let permissionDenied = "权限未开启"
    static let unavailable = "摄像头当前不可用"
    static let directionLocked = "本段方向已锁定"
    static let controls = "录制控制"
    static let quality = "录制清晰度"
    static let fullHD = "1080p · 30fps"
    static let ultraHD = "4K · 30fps"
#if DEBUG
    static let fakePreview = "模拟器摄像头预览（自动化测试）"
#endif
    static let savedToPhotos = "已保存到照片"
    static let interrupted = "录制已中断，已保留可恢复片段"
    static let storageLow = "存储空间不足，无法安全开始录制"
    static let audioUnavailable = "音频输入不可用"
    static let recoveredRecordingFound =
        "发现一段未完整完成的录制，已保留供后续检查。"

    static func recordingCountdown(_ remaining: Int) -> String {
        "录制倒计时 \(remaining)"
    }

    static func audioInput(_ route: AudioInputRoute) -> String {
        guard route.isAvailable else {
            return audioUnavailable
        }

        let routeType = route.isBluetooth ? "蓝牙" : "设备"
        return "音频输入：\(route.name)（\(routeType)）"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

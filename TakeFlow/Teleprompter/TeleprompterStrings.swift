import Foundation

enum TeleprompterStrings {
    static let title = "提词模式"
    static let loading = "正在载入稿件"
    static let start = "开始"
    static let pause = "暂停"
    static let resume = "继续"
    static let restart = "重新开始"
    static let cancelCountdown = "取消倒计时"
    static let settings = "显示设置"
    static let closeSettings = "完成"
    static let showControls = "显示提词控制"
    static let hideControlsHint = "轻点稿件可隐藏控制栏"
    static let showControlsHint = "轻点此按钮或稿件可恢复控制栏"
    static let reload = "重新载入"
    static let emptyTitle = "稿件没有正文"
    static let emptyDescription = "返回编辑器输入正文后再开始提词。"
    static let errorTitle = "无法继续提词"
    static let stateIdle = "尚未开始"
    static let stateRunning = "正在滚动"
    static let statePaused = "已暂停"
    static let stateDragging = "正在手动定位"
    static let stateFinished = "已到稿件结尾"
    static let stateError = "发生错误"
    static let fontSize = "字号"
    static let lineSpacing = "行距"
    static let scrollSpeed = "滚动速度"
    static let horizontalMargin = "左右边距"
    static let textAreaWidth = "提词区域宽度"
    static let verticalPosition = "提词区域垂直位置"
    static let appearance = "显示模式"
    static let darkAppearance = "深色"
    static let lightAppearance = "浅色"
    static let horizontalMirror = "水平镜像"
    static let verticalMirror = "垂直镜像"
    static let countdown = "开始倒计时"
    static let seconds = "秒"

    static func countdownState(_ seconds: Int) -> String {
        "倒计时 \(seconds) 秒"
    }

    static func pointsPerSecond(_ value: Double) -> String {
        "\(Int(value.rounded())) 点/秒"
    }

    static func points(_ value: Double) -> String {
        "\(Int(value.rounded())) 点"
    }

    static func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

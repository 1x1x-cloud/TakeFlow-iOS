import Foundation

enum CameraRecordingStrings {
    static let title = "摄像提词"
    static let preparing = "正在准备摄像头…"
    static let ready = "预览已就绪"
    static let completedAndReady = "录制已完成，可以继续拍摄"
    static let record = "开始录制"
    static let stop = "停止录制"
    static let retry = "重新尝试"
    static let prepareCameraAgain = "重新准备摄像头"
    static let switchCamera = "切换前后摄像头"
    static let frontCameraActive = "当前为前置摄像头"
    static let backCameraActive = "当前为后置摄像头"
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
    static let cameraInterrupted = "摄像头会话已中断"
    static let interruptionEnded =
        "中断已经结束。请重新准备摄像头后再继续拍摄。"
    static let storageLow = "存储空间不足，无法安全开始录制"
    static let audioUnavailable = "音频输入不可用"
    static let recoveredRecordingFound =
        "发现一段未完整完成的录制，已保留供后续检查。"

    static func recordingCountdown(_ remaining: Int) -> String {
        "录制倒计时 \(remaining)"
    }

    static func interruptionMessage(
        for reason: CaptureInterruptionReason,
        recordingWasActive: Bool
    ) -> String {
        let preservationSuffix = recordingWasActive
            ? "，当前片段已安全停止。"
            : "。"
        return switch reason {
        case .applicationBackgrounded:
            "App 已进入后台，录制已停止。返回后请重新准备摄像头。"
        case .audioSessionInterrupted,
             .audioDeviceInUseByAnotherClient:
            "麦克风暂时被系统或其他应用占用" + preservationSuffix
        case .videoDeviceInUseByAnotherClient:
            "摄像头暂时被其他应用占用" + preservationSuffix
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            "当前多窗口状态无法使用摄像头，请全屏返回后重新准备。"
        case .videoDeviceNotAvailableDueToSystemPressure:
            "设备压力过高，摄像头已暂停。请稍后重新准备。"
        case .sensitiveContentMitigationActivated:
            "系统已暂停摄像头画面，请处理系统提示后重新准备。"
        case .mediaServicesReset:
            "系统媒体服务已重置，请重新准备摄像头。"
        case .storageSpaceLow:
            storageLow
        case .cameraUnavailable, .unknown:
            recordingWasActive
                ? "摄像头会话受到中断，当前片段已作为可恢复片段保留。"
                : "摄像头会话受到中断，请等待中断结束后重新准备。"
        }
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

enum CaptureDiagnostics {
    static func record(
        _ event: String,
        state: RecordingState? = nil,
        lifecycleGeneration: UInt64,
        sessionID: UUID?,
        cameraPosition: CameraPosition?,
        isRecording: Bool,
        isFinalizing: Bool,
        isReconfiguring: Bool,
        interruptionReason: CaptureInterruptionReason? = nil,
        interruptionEnded: Bool? = nil,
        rawInterruptionReason: Int? = nil
    ) {
#if DEBUG
        let uptime = String(
            format: "%.3f",
            ProcessInfo.processInfo.systemUptime
        )
        let sessionToken = sessionID.map(shortToken(for:)) ?? "none"
        let stateName = state.map(diagnosticName(for:)) ?? "service"
        let camera = cameraPosition?.rawValue ?? "unknown"
        let reason = interruptionReason?.rawValue ?? "none"
        let ended = interruptionEnded.map { String($0) } ?? "unknown"
        let rawReason = rawInterruptionReason.map { String($0) } ?? "none"
        AppLogger.info(
            "capture_debug uptime=\(uptime) event=\(event) "
                + "state=\(stateName) lifecycle=\(lifecycleGeneration) "
                + "session=\(sessionToken) camera=\(camera) "
                + "recording=\(isRecording) finalizing=\(isFinalizing) "
                + "reconfiguring=\(isReconfiguring) "
                + "interruption_reason=\(reason) "
                + "interruption_ended=\(ended) raw_reason=\(rawReason)",
            category: .recording
        )
#endif
    }

#if DEBUG
    private static func shortToken(for id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func diagnosticName(for state: RecordingState) -> String {
        switch state {
        case .idle:
            "idle"
        case .requestingPermissions:
            "requestingPermissions"
        case .configuring:
            "configuring"
        case .ready:
            "ready"
        case .starting:
            "starting"
        case .recording:
            "recording"
        case .stopping:
            "stopping"
        case .finished:
            "finished"
        case .interrupted:
            "interrupted"
        case .recoveryRequired:
            "recoveryRequired"
        case .failed:
            "failed"
        }
    }
#endif
}

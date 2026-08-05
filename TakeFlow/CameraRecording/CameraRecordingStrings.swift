import Foundation

enum CameraRecordingStrings {
    static let title = "摄像提词"
    static let preparing = "正在准备摄像头…"
    static let ready = "预览已就绪"
    static let completedAndReady = "录制已完成，可以继续拍摄"
    static let record = "开始录制"
    static let startingRecording = "正在开始录制…"
    static let stop = "停止录制"
    static let retry = "重新尝试"
    static let prepareCameraAgain = "重新准备摄像头"
    static let switchCamera = "切换前后摄像头"
    static let frontCameraActive = "当前为前置摄像头"
    static let backCameraActive = "当前为后置摄像头"
    static let focusLock = "锁定焦点和曝光"
    static let focusUnlock = "解锁焦点和曝光"
    static let focusAndExposureLocked = "焦点和曝光已锁定"
    static let focusUnlocked = "焦点和曝光自动调整"
    static let focusAndExposureSet = "已设置对焦和曝光"
    static let focusSet = "已设置对焦"
    static let exposureSet = "已设置曝光"
    static let focusIndicator = "对焦位置"
    static let focusUnavailable = "当前镜头不支持点击对焦或曝光"
    static let saveToPhotos = "保存到照片"
    static let savingToPhotos = "正在保存…"
    static let saved = "已保存"
    static let retrySaveToPhotos = "重新保存到照片"
    static let share = "分享视频"
    static let localPreview = "本地录制预览"
    static let playPreview = "播放视频"
    static let pausePreview = "暂停视频"
    static let previewClose = "完成"
    static let previewInactive = "播放器已关闭"
    static let previewPaused = "视频已暂停"
    static let previewWaiting = "视频正在准备播放"
    static let previewPlaying = "视频正在播放"
    static let previewEnded = "视频播放完毕"
    static let previewUnavailable = "视频暂时无法播放"
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
    static let interrupted = "录制已中断，正在安全完成当前片段"
    static let cameraInterrupted = "摄像头会话已中断"
    static let interruptionEnded =
        "中断已经结束。请重新准备摄像头后再继续拍摄。"
    static let recoveryCommitFailed =
        "中断片段未能完成安全提交，无法确认恢复文件状态。请重新准备摄像头后再继续。"
    static let backgroundFinalizationDeferred =
        "后台安全封口时间已结束，尚不能确认恢复片段。返回 App 后会再次检查；请重新准备摄像头后再继续。"
    static let mediaServicesRestored =
        "系统媒体服务已经恢复。请重新准备摄像头后再继续拍摄。"
    static let storageLow = "存储空间不足，无法安全开始录制"
    static let audioUnavailable = "音频输入不可用"
    static let recoveredRecordingFound =
        "发现中断录制片段，请逐项检查。"
    static let recoverableCardTitle = "发现中断录制片段"
    static let inspectRecoverable = "检查片段"
    static let validatingRecoverable = "正在验证片段…"
    static let recoverableWarning = "中断片段，可能不完整"
    static let recoverableHasAudio = "检测到视频和音频轨道"
    static let recoverableMissingAudio = "未检测到音频轨道"
    static let retainRecoverable = "保留片段"
    static let recoverableRetaining = "正在保留…"
    static let recoverableRetained = "中断片段已保留"
    static let recoverableRetainFailed = "无法保留片段，原文件仍在"
    static let deleteRecoverable = "删除片段"
    static let deleteRecoverableTitle = "确认删除中断片段？"
    static let deleteRecoverableMessage =
        "此操作只删除当前中断片段，不能撤销，不会影响稿件或其他录像。"
    static let recoverableDeleting = "正在删除…"
    static let recoverableDeleteFailed = "删除失败，片段仍保留在 App 内"
    static let recoverableLater = "稍后处理"
    static let recoverableUnavailable = "此中断片段无法播放"

    static func recoverableReason(
        _ reason: CaptureInterruptionReason
    ) -> String {
        switch reason {
        case .applicationBackgrounded:
            "原因：App 进入后台"
        case .audioSessionInterrupted:
            "原因：音频会话中断"
        case .cameraUnavailable:
            "原因：摄像头不可用"
        case .audioDeviceInUseByAnotherClient:
            "原因：麦克风被其他应用占用"
        case .videoDeviceInUseByAnotherClient:
            "原因：摄像头被其他应用占用"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            "原因：多窗口限制"
        case .videoDeviceNotAvailableDueToSystemPressure:
            "原因：设备压力过高"
        case .sensitiveContentMitigationActivated:
            "原因：系统暂停摄像头"
        case .mediaServicesLost:
            "原因：媒体服务丢失"
        case .mediaServicesReset:
            "原因：媒体服务重置"
        case .storageSpaceLow:
            "原因：存储空间不足"
        case .unknown:
            "原因：录制异常结束"
        }
    }

    static func recoverableValidationMessage(
        _ failure: RecoverableMediaValidationFailure
    ) -> String {
        switch failure {
        case .fileMissing:
            "恢复文件已不存在"
        case .containerUnrecognized:
            "文件容器无法识别"
        case .videoTrackMissing:
            "文件中没有有效视频轨道"
        case .durationInvalid:
            "文件没有有效的可播放时长"
        case .notPlayable:
            "系统无法播放此文件"
        }
    }

    static func recordingCountdown(_ remaining: Int) -> String {
        "录制倒计时 \(remaining)"
    }

    static func interruptionMessage(
        for reason: CaptureInterruptionReason,
        recordingWasActive: Bool
    ) -> String {
        let preservationSuffix = recordingWasActive
            ? "，正在安全完成当前片段。"
            : "。"
        return switch reason {
        case .applicationBackgrounded:
            recordingWasActive
                ? "App 已进入后台，正在安全完成当前片段。返回后请重新准备摄像头。"
                : "App 已进入后台。返回后请重新准备摄像头。"
        case .audioSessionInterrupted,
             .audioDeviceInUseByAnotherClient:
            reason == .audioDeviceInUseByAnotherClient
                ? "麦克风暂时被其他应用占用" + preservationSuffix
                : "音频会话被系统中断" + preservationSuffix
        case .videoDeviceInUseByAnotherClient:
            "摄像头暂时被其他应用占用" + preservationSuffix
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            "当前多窗口状态无法使用摄像头，请全屏返回后重新准备。"
        case .videoDeviceNotAvailableDueToSystemPressure:
            "设备压力过高，摄像头已暂停。请稍后重新准备。"
        case .sensitiveContentMitigationActivated:
            "系统已暂停摄像头画面，请处理系统提示后重新准备。"
        case .mediaServicesLost:
            "系统媒体服务已丢失，请等待系统恢复后重新准备摄像头。"
        case .mediaServicesReset:
            "系统媒体服务不可用或已重置，请重新准备摄像头。"
        case .storageSpaceLow:
            storageLow
        case .cameraUnavailable, .unknown:
            recordingWasActive
                ? "摄像头会话受到中断，正在安全完成当前片段。"
                : "摄像头会话受到中断，请等待中断结束后重新准备。"
        }
    }

    static func recoveryRequiredMessage(
        for reason: CaptureInterruptionReason
    ) -> String {
        let reasonText = switch reason {
        case .mediaServicesLost:
            "系统媒体服务曾丢失"
        case .mediaServicesReset:
            "系统媒体服务不可用或已重置"
        case .videoDeviceNotAvailableDueToSystemPressure:
            "设备压力过高"
        case .sensitiveContentMitigationActivated:
            "系统暂停了摄像头画面"
        case .applicationBackgrounded:
            "App 曾进入后台或锁屏"
        case .videoDeviceInUseByAnotherClient:
            "摄像头曾被其他应用占用"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            "多窗口状态限制了摄像头"
        case .audioDeviceInUseByAnotherClient:
            "麦克风曾被其他应用占用"
        case .audioSessionInterrupted:
            "音频会话曾被系统中断"
        case .storageSpaceLow:
            "录制因存储空间不足停止"
        case .cameraUnavailable, .unknown:
            "摄像头会话受到系统中断"
        }
        return "\(reasonText)。请重新准备摄像头后再继续拍摄。"
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
        rawInterruptionReason: Int? = nil,
        episodeID: UUID? = nil,
        recordingID: UUID? = nil,
        scenePhase: String? = nil,
        audioDetails: AudioInterruptionDetails? = nil,
        didFinishFile: Bool? = nil,
        didCommitManifest: Bool? = nil,
        requiresManualReprepare: Bool? = nil,
        fileExists: Bool? = nil,
        fileNonEmpty: Bool? = nil,
        manifestStage: String? = nil,
        backgroundTaskStage: String? = nil,
        recoveredItemCount: Int? = nil
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
        let episodeToken = episodeID.map(shortToken(for:)) ?? "none"
        let recordingToken = recordingID.map(shortToken(for:)) ?? "none"
        let phase = scenePhase ?? "unknown"
        let audioRawType = audioDetails?.rawType.map(String.init) ?? "none"
        let audioRawReason = audioDetails?.rawReason.map(String.init) ?? "none"
        let audioSuspended = audioDetails.map {
            String($0.wasSuspended)
        } ?? "unknown"
        let fileFinished = didFinishFile.map(String.init) ?? "unknown"
        let manifestCommitted = didCommitManifest.map(String.init) ?? "unknown"
        let manualReprepare = requiresManualReprepare.map(String.init) ?? "unknown"
        let exists = fileExists.map(String.init) ?? "unknown"
        let nonEmpty = fileNonEmpty.map(String.init) ?? "unknown"
        let manifest = manifestStage ?? "unknown"
        let backgroundTask = backgroundTaskStage ?? "unknown"
        let recoveryCount = recoveredItemCount.map(String.init) ?? "unknown"
        AppLogger.info(
            "capture_debug uptime=\(uptime) event=\(event) "
                + "state=\(stateName) lifecycle=\(lifecycleGeneration) "
                + "session=\(sessionToken) camera=\(camera) "
                + "recording=\(isRecording) finalizing=\(isFinalizing) "
                + "reconfiguring=\(isReconfiguring) "
                + "interruption_reason=\(reason) "
                + "interruption_ended=\(ended) raw_reason=\(rawReason) "
                + "episode=\(episodeToken) recording_id=\(recordingToken) "
                + "scene=\(phase) audio_type=\(audioRawType) "
                + "audio_reason=\(audioRawReason) "
                + "audio_suspended=\(audioSuspended) "
                + "file_finished=\(fileFinished) "
                + "manifest_committed=\(manifestCommitted) "
                + "manual_reprepare=\(manualReprepare) "
                + "file_exists=\(exists) file_nonempty=\(nonEmpty) "
                + "manifest_stage=\(manifest) "
                + "background_task=\(backgroundTask) "
                + "recovery_count=\(recoveryCount)",
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
        case .awaitingRecordingStart:
            "awaitingRecordingStart"
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

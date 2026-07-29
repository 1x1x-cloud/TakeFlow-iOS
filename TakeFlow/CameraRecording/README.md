# CameraRecording

模块 3 的摄像预览与基础视频录制边界。

- `RecordingStateMachine`：唯一录制状态机，校验非法转换、录制 UUID 和回调代次。
- `CameraRecordingViewModel`：`@MainActor` UI 状态、权限流程、倒计时、空间监控、中断和文件提交协调。
- `AVFoundationCaptureService`：独立串行队列上的设备能力探测、会话配置、预览、对焦/曝光和 `.mov` 录制。
- `RecordingFileStore`：Application Support 下按项目/录制 UUID 隔离的临时文件、原子元数据、完成提交与启动恢复。
- `SystemPermissionService`、`SystemAudioSessionService`、`SystemPhotoLibraryService`：按需权限、音频路由与 `addOnly` 照片保存。
- `CameraRecordingDependencies.fake`：仅用于模拟器 UI 自动化，界面明确标识 Fake，不代表真实硬件录制证据。

摄像提词界面复用模块 2 的 `TeleprompterViewModel`、状态机、Character 锚点和有界分块渲染；不得在本目录建立第二套提词逻辑。真实摄像头、麦克风、镜像、方向、蓝牙、中断、温度、长录制和文件可播放性必须按 `MANUAL_TEST_CHECKLIST.md` 在真机验证。

# CameraRecording

模块 3 的摄像预览与基础视频录制边界。

- `RecordingStateMachine`：唯一录制状态机，校验非法转换、录制 UUID 和回调代次。
- `CameraRecordingViewModel`：`@MainActor` UI 状态、权限流程、倒计时、空间监控、中断和文件提交协调。
- `AVFoundationCaptureService`：独立串行队列上的设备能力探测、会话配置、预览、对焦/曝光和 `.mov` 录制。
- `RecordingFileStore`：Application Support 下按项目/录制 UUID 隔离的临时文件、原子元数据、完成提交与启动恢复。
- `SystemPermissionService`、`SystemAudioSessionService`、`SystemPhotoLibraryService`：按需权限、音频路由与 `addOnly` 照片保存。
- `CameraRecordingDependencies.fake`：仅用于模拟器 UI 自动化，界面明确标识 Fake，不代表真实硬件录制证据。

正常停止必须先在 `.stopping` 完成文件封口并进入 `.finished`，再由当前有效页面生命周期显式恢复 `.ready`；最近一次 `completedRecording` 在恢复后保留。摄像头切换仅允许从 `.ready` 进入 `.configuring`，成功事件返回后恢复 `.ready`，失败进入既有重试路径；中断、失败、封口中、页面退出或旧 generation 均不得直接恢复。

同一生命周期内切换镜头只允许在 Capture Session 的串行队列中替换视频输入；麦克风输入和 `AVCaptureMovieFileOutput` 必须保持连接，禁止用完整会话图拆装实现镜头切换。Capture Session 与音频中断按来源、session ID 和 lifecycle generation 配对；中断结束及片段安全封口后进入 `.recoveryRequired`，只能由用户明确执行“重新准备摄像头”，不得自动恢复录制。

摄像提词界面复用模块 2 的 `TeleprompterViewModel`、状态机、Character 锚点和有界分块渲染；不得在本目录建立第二套提词逻辑。真实摄像头、麦克风、镜像、方向、蓝牙、中断、温度、长录制和文件可播放性必须按 `MANUAL_TEST_CHECKLIST.md` 在真机验证。

# SpeechTracking

模块 4 的文本规范化、候选匹配、设备端识别和语音跟随状态机边界。详细冻结规格见仓库根目录 `MODULE4_PRODUCT_SPEC.md`。

永久边界：

- 最低 iOS 17 使用 `SFSpeechRecognizer` 抽象；首版不依赖 `SpeechAnalyzer`。
- 用户明确开启后先创建 `zh-CN` recognizer 并检查 `supportsOnDeviceRecognition`；不支持时不申请 Speech 或麦克风权限。支持时才显示用途说明并依次请求权限，授权后重新检查本地能力与 `isAvailable`；请求强制 `requiresOnDeviceRecognition = true`，没有联网回退。
- 不持久化识别文本、候选、时间线、评分、临时锚点或专供识别的音频副本。单次任务可在易失内存处理这些内容和最多 2 秒 PCM；任务结束、取消、中断、切换或退出时释放，不写入 SwiftData、UserDefaults、文件、日志或分析事件。
- 匹配器只输出全局 `ScriptReadingAnchor` 提议；滚动、布局和持久化继续复用 Teleprompter 的唯一状态机与虚拟化路径。
- 普通提词使用独立的单一音频源；摄像提词只订阅 CameraRecording 同一 Capture Session 的瞬时 PCM，不拥有或控制录像。4F 必须用真机证明 PCM 与视频/AAC 输出共存；不得在录制中重建 Session 图或创建第二个 `AVAudioEngine`/麦克风链路，不能安全共存时只降级固定速度。
- 识别失败必须保留固定速度提词，且不得停止或损坏正常视频录制。
- 免费/Pro 只定义协议，不实现 StoreKit、计量或付费墙。

模块 4A 设计冻结已完成，但尚未实现生产代码；模块 4B 尚未开始。开发必须按 4B 至 4H 顺序推进，当前不得提前实现模块 5。

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

## 4B 已实现边界

- `SpeechDocumentBuilder` 在后台构建不可变文档；以 `Character` 半开范围拆分硬句、软边界和最长 48 个规范单元的安全块，不保存 `String.Index`。
- `SpeechTextNormalizer` 执行 Unicode 兼容规范化、稳定拉丁小写、全半角统一及中英文/数字单元化；标点、空白和 Emoji 可产生零个规范单元，每个单元仍保留原稿全局 `Character` 来源范围。
- `SpeechDocumentIndex` 提供句段顺序、规范单元到句段、原稿位置到规范范围、bigram 倒排索引、前 2/后 6 窗口及最多 8 个重定位候选；查询不重新规范化或全文拆句。
- 默认容量上限为 1,000,000 个原稿 `Character`、100,000 个句段、250,000 个 n-gram 键、每键 100,000 个位置、每句段 64 个 n-gram；超限返回类型化错误，不静默截断正文。
- 已建立文档、规范化、索引、候选、锚点提议、设备端识别、瞬时音频、权限能力和免费/Pro 边界协议。识别、音频和权益协议没有系统实现；音频帧与识别结果只表达后续阶段的易失内存边界。
- 固定转写夹具在 4B 只验证拆句、规范化、映射和候选生成；没有匹配评分、置信阈值、锚点推进或重定位状态机，不构成 4C A 层验收。

模块 4A 设计冻结及 4B 文本基础已完成软件验收。4C 尚未开始；当前没有 Speech Framework、麦克风、权限、UI、摄像整合、联网识别、StoreKit 或模块 5 实现。

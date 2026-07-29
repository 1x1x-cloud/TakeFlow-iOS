# 开发状态

最后更新：2026-07-29
产品规格：`PRODUCT_SPEC.md` 1.0
总体状态：进行中
当前阶段：模块 0 已完成；模块 1、模块 2、模块 3 的实现、模拟器构建和自动化验收已通过；模块 3 的摄像头重复进入缺陷已完成软件加固，并通过 M3-16 连续 10 轮真实 iPhone 复测，但方向、镜像、蓝牙、相册、长录制与系统中断恢复等其余真机验收仍待执行

## 状态定义

- **未开始**：尚未实现该模块。
- **进行中**：已有实现，但尚未满足全部验收条件。
- **受阻**：继续实现需要产品决策、外部服务、账号或设备条件。
- **已完成**：全部验收条件有证据，构建、自动化测试和要求的真机验证均通过。

## 模块状态

| 模块 | 名称 | 状态 | 构建 | 自动化测试 | 真机验证 | 备注 |
|---|---|---|---|---|---|---|
| 0 | 工程初始化与规则建立 | 已完成 | iPhone、iPad 模拟器构建通过 | 5 通过、0 失败 | 模拟器启动通过；正式签名、真机与 TestFlight 未验证 | `TakeFlow` App、单测、UI 测试三个 Target 已建立；发布前手动项见 M0-01 至 M0-06 |
| 1 | 稿件管理与编辑 | 进行中 | iPhone、iPad 模拟器 Debug 构建通过 | 单元测试 33/33；UI 测试 4/4 | M1-01 至 M1-07 待执行 | SwiftData 本地持久化、V1 Schema 与独立恢复草稿已落地；状态保留为“进行中”，直到真机强杀恢复、输入、性能、离线和低存储验收完成 |
| 2 | 基础提词器 | 进行中 | iPhone、iPad 模拟器 Debug 构建通过 | 单元测试 74/74；UI 测试 9/9（含模块 1 全量回归） | M2-01 至 M2-10 待执行 | 固定速度、唯一状态机、全局 Character 锚点、每稿偏好及有界分块虚拟化已实现；模拟器 1 万/10 万字符内部阈值通过，真机滚动、辅助功能及长稿性能未验收 |
| 3 | 摄像头与视频录制 | 进行中 | iPhone、iPad 模拟器 Debug、Generic iOS Device 无签名 Debug、Generic iOS Device 无签名 Release 构建通过 | 单元测试 139/139；UI 测试 19/19（含模块 1、2 全量回归）；模块 2 性能阈值继续通过 | M3-16 通过；M3-01 至 M3-15 待执行 | 显式录制状态机、AVFoundation 串行服务、动态能力矩阵、私有录制文件恢复、低空间保护、Debug-only Fake UI 流程和提词器叠加已实现；重复进入采用生命周期 UUID 隔离并加入准备超时/真实重试，iPhone 16 连续 10 轮复测通过 |
| 4 | 实时语音跟随 | 未开始 | 未运行 | 未运行 | 未执行 | 语音识别隐私路径需先确认 |
| 5 | 分段录制与错句重拍 | 未开始 | 未运行 | 未运行 | 未执行 | — |
| 6 | 视频拼接、字幕与导出 | 未开始 | 未运行 | 未运行 | 未执行 | 字幕时间来源与量化标准需先确认 |
| 7 | AI 口语化改稿 | 未开始 | 未运行 | 未运行 | 未执行 | 供应商、后端与数据处理规则未定 |
| 8 | 订阅与权限控制 | 未开始 | 未运行 | 未运行 | 未执行 | 商品、权益细则与免费额度未定 |
| 9 | 隐私、稳定性与上架准备 | 未开始 | 未运行 | 未运行 | 未执行 | 依赖前序模块与外部政策/条款地址 |

## 构建与测试事实

验证日期：2026-07-29

### 模块 0 验证事实

- 工具链：完整 Xcode 26.0.1（Build 17A400），Apple Swift 6.2，iOS/iOS Simulator SDK 26.0。
- 可用运行时：iOS Simulator 26.0.1；已使用 iPhone 17 Pro 与 iPad Pro 11-inch (M4)。
- 工程解析：`plutil -lint TakeFlow.xcodeproj/project.pbxproj` 通过；`xcodebuild -list` 识别 `TakeFlow`、`TakeFlowTests`、`TakeFlowUITests` 和共享 Scheme `TakeFlow`。
- iPhone 构建：Debug、iPhone 17 Pro 模拟器，提交前基线复验 `BUILD SUCCEEDED`；产物位于被忽略的 `.build/BaselineDerivedData`。
- iPad 构建：Debug、iPad Pro 11-inch (M4) 模拟器，`BUILD SUCCEEDED`。
- 模块 0 提交前全量测试：当时共享 Scheme 共 5 项，5 通过、0 失败、0 跳过；结果包位于被忽略的 `.build/BaselineAllTests.xcresult`。
- 单元测试：`TakeFlowTests` 共 4 项，4 通过、0 失败。
- UI 测试：`testLaunchShowsMinimalHome` 共 1 项，1 通过、0 失败；测试真实启动 App 并断言 `home.title` 与 `home.status` 存在。
- 首页视觉核对：已在 iPhone 17 Pro 模拟器重新安装并启动 App，确认显示“首页”“一遍成”“工程基础已就绪”。
- 编译器未报告 Swift 源码警告。Xcode 26 的 `appintentsmetadataprocessor` 对未链接 AppIntents 的 Target 输出一次系统工具提示：“Metadata extraction skipped. No AppIntents.framework dependency found.” 本项目未使用 AppIntents，不影响产物；该提示不来自项目源码。
- 未配置正式开发团队、正式 Bundle ID、权限 entitlement 或真实密钥；当前 Bundle ID 为 `com.example.takeflow.placeholder`。
- 正式签名、真实 iPhone/iPad 安装和 TestFlight 分发尚未验证，不能作为发布就绪证据。
- 未引入第三方包或 SDK；当前业务实现仅限模块 1、模块 2 和模块 3，模块 4 至模块 9 的目录仍只保留边界说明。

### 模块 1 验证事实

- 基线：开始实现前 `HEAD` 为 `57e15631c1f772f9e9351ea2cc1d40d4f9b7b164`，分支 `master`；模块 1 已单独提交为 `a9c13d3b3b23554f1b0578116127d3f6eebd24ff`（`feat: implement resilient script management`）。
- iPhone 构建：`xcodebuild -project TakeFlow.xcodeproj -scheme TakeFlow -configuration Debug -destination 'platform=iOS Simulator,id=4563833B-0C75-4B44-98B9-FE802962D730' -derivedDataPath .build/RecoveryDraftFinal-iPhone build`，iPhone 17 Pro / iOS 26.0.1，`BUILD SUCCEEDED`。
- iPad 构建：`xcodebuild -project TakeFlow.xcodeproj -scheme TakeFlow -configuration Debug -destination 'platform=iOS Simulator,id=08CE106F-C7F5-4CFC-8051-F216CBFDC2F1' -derivedDataPath .build/RecoveryDraftFinal-iPad build`，iPad Pro 11-inch (M4) / iOS 26.0.1，`BUILD SUCCEEDED`。
- 全量单元测试：`xcodebuild ... -derivedDataPath .build/RecoveryDraftFinal -only-testing:TakeFlowTests test`，33 项通过、0 失败、0 跳过；原模块 1 的 20 项全部继续通过，新增恢复草稿测试 13 项全部通过。结果包为 `.build/RecoveryDraftFinal/Logs/Test/Test-TakeFlow-2026.07.28_19-06-30-+0800.xcresult`。
- 10 万字符自动化基线：在上述 iPhone 17 Pro 模拟器使用隔离 SwiftData 内存容器完成正式保存、读取、字符统计和正文搜索，测试耗时 0.308 秒；独立文件恢复草稿的原子写入与读取用例耗时 0.024 秒。两者均低于当前内部保护阈值 5 秒。该数据是本轮模拟器观测值，不是最大时延保证；规格尚未批准量化性能阈值，真实 iOS 17 设备上的编辑响应仍待 M1-02 验证。
- 全量 UI 测试：`-only-testing:TakeFlowUITests`，4 项通过、0 失败；覆盖空稿件页启动、创建与编辑自动保存、复制/删除确认/短时撤销，以及使用磁盘 SwiftData Store 保存后终止并重启 App 的恢复。
- 持久化采用本地 SwiftData Store，显式禁用 CloudKit；生产路径不使用内存演示数据。UI 测试只有需要隔离的用例通过启动参数选择内存 Store，重启恢复用例明确使用磁盘 Store。
- 未完成编辑另写入 `Application Support/TakeFlow/RecoveryDrafts` 下按稳定 Script UUID 命名的独立 JSON 文件，不使用 UserDefaults 或 Caches。每份文件包含标题、正文、阅读位置、草稿时间、正式记录版本依据、编辑会话 ID 与单调 revision；写入在 actor 上串行执行，使用原子替换和文件保护，不在主线程执行大文本磁盘 I/O。
- 编辑器先显示正式 SwiftData 记录，只在恢复草稿的基础版本与正式记录精确匹配且草稿更新时间较新时提出“恢复草稿”或“保留已保存版本”，不会静默覆盖。损坏、不可读或版本不匹配均保留正式记录并显示安全错误；正式保存成功后通过提交版本屏障清理恢复文件，晚到的旧写任务不能重新覆盖或复活草稿。
- 删除稿件会同步阻止晚到草稿写入并清理恢复文件；清理失败时回滚软删除。撤销删除后重新允许该 Script ID 的恢复写入，既有复制、搜索和 5 秒撤销语义不变。
- 恢复草稿不采用额外防抖：每次编辑状态变化都立即投递不可变快照，正式 SwiftData 保存仍保持 600 ms 防抖。因此恢复路径没有人为设置的 600 ms 等待窗口，但异步任务调度、文件系统负载和进程被立即杀死之间仍不存在可证明的固定最大时延。可保证的是“最近一次已完成原子替换的恢复快照”不会出现半写入；若在最新写入完成前强杀，最后若干输入仍可能缺失，不得表述为绝对零丢失。
- 未添加网络客户端、云同步、第三方依赖、真实密钥或正式签名配置；模块 2 至模块 9 的业务功能未提前实现。
- 编译器未报告 Swift 源码警告。Xcode 26 的未使用 AppIntents 元数据工具提示仍存在，性质与模块 0 相同。
- 真机即时强制结束及两种恢复选择、中文输入法组合态、10 万字符真实编辑响应、飞行模式、低存储写入失败、iPad 外接键盘与辅助功能仍未验证，详见 M1-01 至 M1-07。

### 模块 2 验证事实

- 基线：开始实现前 `HEAD` 为模块 1 本地基线 `a9c13d3b3b23554f1b0578116127d3f6eebd24ff`（`feat: implement resilient script management`），分支 `master`；工作区开始时干净，模块 1 与模块 2 的本地基线保持独立。
- 数据迁移：当前 SwiftData Schema 为 `ScriptSchemaV2`，从 V1 使用轻量迁移；新增字号、行距、点/秒速度、左右边距、区域宽度/垂直位置、深浅模式、水平/垂直镜像和倒计时字段。自动化已用真实 V1 磁盘 Store 打开 V2 容器并验证旧稿、旧阅读位置和安全默认值可读。
- 状态与时间：`TeleprompterPlaybackMachine` 明确区分 `idle`、`countingDown`、`running`、`paused`、`userDragging`、`finished` 和类型化 `error`；位置由单调时钟的运行段起点、实际经过秒数和逻辑点/秒推导，不按帧累加。60Hz 与 120Hz 模拟 10 秒均得到 600 点，误差在测试精度 `0.000001` 点内；后台时间不累计，返回时保持暂停。
- 阅读位置：`ScriptReadingAnchor` 使用 Swift 扩展字素簇偏移，UIKit 桥接仅把它换算为当前布局像素；字号、行距、边距、区域宽度、方向和尺寸变化后重新解析锚点。拖动中只在当前块内计算轻量近似锚点，拖动结束时用当前可见 TextKit 单元解析精确全局位置；全文 Character 数与可读性已在后台索引中预计算，滚动帧不再重复扫描正文。
- 分块呈现：`TeleprompterDocument` 在后台按段落优先、Swift Character 安全边界建立内容版本与双向索引；块目标 1,500 Character、硬上限 2,200。`UICollectionView` 只实例化可见 TextKit 单元，预取前 1、后 2 块；富文本 LRU 上限为 8，内存警告时释放非可见缓存。正文版本变化会丢弃旧索引；状态机、全局锚点及 SwiftData 事实来源保持唯一。
- 数据安全：提词器通过 `TeleprompterScriptProviding` 重新读取最新正式稿后只写阅读位置和显示偏好，不持有陈旧正文快照；若存在比正式记录新的恢复草稿，阻止进入或保存提词状态并要求先在编辑器选择版本。单元测试证明保存提词状态不改正文，模块 1 的恢复、删除撤销、复制、搜索和 600 ms 自动保存测试全部继续通过。
- iPhone 提交前复验：`xcodebuild -project TakeFlow.xcodeproj -scheme TakeFlow -configuration Debug -destination 'platform=iOS Simulator,id=4563833B-0C75-4B44-98B9-FE802962D730' -derivedDataPath .build/Module2Baseline-iPhone build -quiet`，iPhone 17 Pro / iOS 26.0.1，退出码 0。
- iPad 提交前复验：`xcodebuild -project TakeFlow.xcodeproj -scheme TakeFlow -configuration Debug -destination 'platform=iOS Simulator,id=08CE106F-C7F5-4CFC-8051-F216CBFDC2F1' -derivedDataPath .build/Module2Baseline-iPad build -quiet`，iPad Pro 11-inch (M4) / iOS 26.0.1，退出码 0。
- 提交前全量单元测试：`xcodebuild ... -derivedDataPath .build/Module2BaselineVerification -only-testing:TakeFlowTests test -quiet`，74 项通过、0 失败、0 跳过；模块 1 基线 33 项全部回归通过。新增覆盖安全分块、Emoji/组合字符、双向偏移、远端跳转、跨块滚动/拖动/状态转换、内容版本失效、有界缓存、内存压力、硬性能阈值及运行期无全文重复布局。结果包为 `.build/Module2BaselineVerification/Logs/Test/Test-TakeFlow-2026.07.28_22-44-16-+0800.xcresult`。
- 提交前全量 UI 测试：`xcodebuild ... -derivedDataPath .build/Module2BaselineVerification -only-testing:TakeFlowUITests test -quiet`，9 项通过、0 失败、0 跳过；模块 1 原 4 项全部回归通过，模块 2 的 5 项覆盖可访问控件与控制栏恢复、倒计时→运行→暂停→继续、拖动后继续、字号/速度/边距退出重入恢复、空稿不能进入运行状态。结果包为 `.build/Module2BaselineVerification/Logs/Test/Test-TakeFlow-2026.07.28_22-45-25-+0800.xcresult`。
- 全量回归曾暴露模块 1 恢复文件日期仅存毫秒、内存 `Date` 保留更高精度导致旧 revision 偶发覆盖新 revision 的缺陷；版本比较已改用持久化的正式记录位版本，并把跨会话草稿时间归一化到毫秒。目标测试连续运行 10 次全部通过，结果包为 `.build/Module2FinalTests/Logs/Test/Test-TakeFlow-2026.07.28_21-01-00-+0800.xcresult`；随后 55 项全量测试再次通过。
- 优化前证据：iPhone 17 Pro / iOS 26.0.1 模拟器测试进程中，SwiftData 读取 13.353 ms、Character/段落索引 134.181 ms、富文本构造 0.321 ms、TextKit 2 整篇赋值 16,182.854 ms、首次布局 9.048 ms、首屏计算 0.657 ms、中点锚点 13.003 ms、全文高度 0.005 ms、滚动与结束锚点 80.504 ms；TextKit 1 对照整篇赋值也为 14,218.354 ms，证明主要瓶颈是整篇文本赋值而非 SwiftData、SwiftUI 或 TextKit 版本。
- 优化后分阶段观测（三轮范围）：SwiftData 读取 3.801–4.168 ms、后台块索引 91.065–106.028 ms、可见块富文本构造 0.079–0.100 ms、可见块赋值 1.061–1.335 ms、首次块布局 90.780–108.954 ms、首屏可见计算 0.176–0.186 ms、块内锚点 0.754–0.783 ms、虚拟高度与首屏 279.832–344.072 ms、桥接等价更新 0.301–0.399 ms、601 次可见区更新 41.684–50.203 ms。
- 提交前连续三轮硬性能测试均通过：1 万字符从 SwiftData 读取到首屏可交互总耗时 400.907 / 351.355 / 354.299 ms（阈值 500 ms）；10 万字符 427.399 / 329.148 / 482.963 ms（阈值 2,000 ms）。设备为 iPhone 17 Pro 模拟器、iOS 26.0.1、Debug、Xcode 26.0.1；测量包含真实内存 SwiftData 值读取、后台索引及虚拟化首屏出现可见单元，属于本机内部防退化数据，不是真机性能保证。三轮各 7 项性能测试均通过，结果包为 `.build/Module2BaselinePerfRound1.xcresult` 至 `.build/Module2BaselinePerfRound3.xcresult`。
- 字号、行距、边距和宽度的 10 万字符重排硬断言低于 1 秒；1,200 次运行更新硬断言低于 1 秒，源码路径和测试均证明不再周期性赋值或布局全文。真机连续滚动、触控、旋转、内存和热状态仍待 M2-08、M2-10。
- 模块 2 基线提交时编译器未报告新增 Swift 源码警告；当时未加入网络、权限、摄像头、麦克风、语音、媒体、StoreKit、CloudKit、第三方依赖、密钥或正式签名资料。模块 3 后续实现没有改变模块 2 的状态机、全局 Character 锚点或有界虚拟化事实来源。

### 模块 3 验证事实

- 基线：开始实现前及发布静态复验开始时，`HEAD` 均为模块 2 本地基线 `cadf791061fc5d738550249f253dba8206316e00`，分支 `master`；模块 0、1、2 提交依次为 `57e1563`、`a9c13d3`、`cadf791`。本节随模块 3 软件与模拟器本地基线提交建立；模块 4 未开始。
- 架构：`CameraRecordingViewModel` 位于 `@MainActor`，只组合权限、录制、文件、空间、照片和音频会话协议；`AVFoundationCaptureService` 在独立串行队列管理 `AVCaptureSession`、设备和 `AVCaptureMovieFileOutput`。Delegate 与系统通知转换为带录制 UUID 的异步事件，显式状态机区分 `idle`、`requestingPermissions`、`configuring`、`ready`、`starting`、`recording`、`stopping`、`finished`、`interrupted` 和 `failed`，并拒绝重复开始、重复停止、录制中切换及过期回调。
- 能力与媒体配置：运行时检查 session preset、设备 format 的 30 fps 范围及 Movie Output 可用 codec；默认 1080p/30 fps/H.264，仅在当前设备完整支持时提供 4K/30 fps/HEVC，并有类型化安全降级。音频目标为 AAC、48 kHz，系统音频会话允许可用 Bluetooth HFP 输入并将路由变化转换为明确 UI 状态；麦克风未授权或无输入时不进入正常含声录制流程。
- 方向与镜像：预览与输出 connection 独立配置，使用 `AVCaptureDevice.RotationCoordinator` 的 `videoRotationAngleForHorizonLevelPreview` 和 `videoRotationAngleForHorizonLevelCapture`；开始录制时冻结输出角度，录制中旋转只更新预览及锁定提示。前摄预览镜像、Movie Output 不镜像，后摄两者均不镜像；未使用已废弃 `videoOrientation`。
- 文件安全：录制位于 `Application Support/TakeFlow/Recordings/<project UUID>`，每次使用独立 recording UUID 和 `Temporary` 临时文件。项目元数据先原子写入，只有 Movie Output 完成回调成功后才移动到 `Segments` 并标记可播放；中断、写入失败和遗留临时文件保留为待检查/可恢复，不冒充正常文件。启动扫描、损坏元数据隔离、唯一命名、精确项目目录删除和跨实例恢复均有测试；日志不记录正文、媒体内容或完整本地路径。
- 存储空间：`RecordingStoragePolicy` 集中定义起录安全线 500 MB、录制中安全停止线 250 MB 和 5 秒轮询间隔；生产实现读取当前卷重要用途可用容量，测试通过注入服务覆盖边界。低空间、文件写入失败、中断、后台及停止竞争只提交一次安全停止，已经落盘的临时内容保留。
- 权限与导出：摄像头和麦克风按进入摄像提词流程请求；录制到私有目录不请求照片权限。用户主动保存时仅请求 Photos `addOnly`；拒绝或失败仍保留 App 内文件并允许系统分享。`PrivacyInfo.xcprivacy` 已加入 Target，磁盘可用空间 required-reason API 声明与当前实现一致。
- 提词器复用：摄像头界面直接复用 `TeleprompterPlaybackMachine`、`TeleprompterDocument`、`TeleprompterViewModel` 和现有分块 Collection View，不存在第二套滚动状态，也没有恢复整篇 TextKit 赋值。摄像头预览、录制连接与 SwiftUI 提词/控制叠加层分离，因此 UI 不进入 Movie Output 媒体流；真实录制文件像素仍需 M3-04 真机验证。
- 模块 2 性能回归期间发现可见块仍触发通用自适应布局和重复锚点校准。修复后，每个可见块使用有界 TextKit 1 单元与 `boundingRect` 高度计算，先按全局 Character 跳转目标块，再在下一次主 actor 调度中完成块内精确校准；revision 屏障避免旧布局覆盖新布局。全文索引、唯一状态机、全局 Character 锚点、块目标 1,500/硬上限 2,200 和富文本 LRU 上限 8 均保持不变。
- 最终 iPhone 构建：`xcodebuild -project TakeFlow.xcodeproj -scheme TakeFlow -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/Module3FinalBuild-iPhone build -quiet`，iPhone 17 Pro / iOS 26.0.1，退出码 0。
- 最终 iPad 构建：`xcodebuild -project TakeFlow.xcodeproj -scheme TakeFlow -configuration Debug -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' -derivedDataPath .build/Module3FinalBuild-iPad build -quiet`，iPad Pro 11-inch (M4) / iOS 26.0.1，退出码 0。
- Generic iOS Device Debug 编译：`xcodebuild -project TakeFlow.xcodeproj -scheme TakeFlow -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath .build/Module3DeviceDebug CODE_SIGNING_ALLOWED=NO build -quiet`，退出码 0。Release 编译使用相同 Generic iOS Device、`.build/Module3DeviceRelease`、`CODE_SIGNING_ALLOWED=NO`，并设置 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`、`GCC_TREAT_WARNINGS_AS_ERRORS=YES`，`BUILD SUCCEEDED`；实际 arm64 产物最低版本为 iOS 17.0。首次把条件编译跨越 SwiftUI `else if` 分支时编译失败，修正为独立 `@ViewBuilder` 边界后最终复验通过，失败期间没有提交。
- Release 产品审计：生产 App 只包含二进制、`Info.plist`、`PrivacyInfo.xcprivacy` 和 `PkgInfo`，无测试媒体、测试 Bundle、调试菜单或代码签名目录。UI 测试启动参数、Fake Capture 服务、Fake 权限/空间/照片/音频服务及 Fake 预览文案均由 `#if DEBUG` 隔离；对 Release 二进制执行字符串和符号扫描，相关匹配为 0。未写入 `DEVELOPMENT_TEAM`，Bundle ID 仍是明确占位值 `com.example.takeflow.placeholder`。
- iOS 17 与权限审计：Generic arm64 iOS 17 编译在警告即错误模式下通过；源码没有无保护的 iOS 18、iOS 26 或 Beta API，也未使用已废弃 `videoOrientation`。`AVCaptureDevice.RotationCoordinator` 与 `videoRotationAngle` 在本机 iOS SDK 头文件中标注 iOS 17 可用。Release `Info.plist` 的摄像头说明为“用于在您主动进入摄像提词并开始录制时拍摄视频。”，麦克风说明为“用于在您主动开始视频录制时同步录制声音。”，照片添加说明为“仅在您主动选择保存到照片时添加已完成的视频。”；不存在 `NSPhotoLibraryUsageDescription`，代码只使用 Photos `.addOnly`。
- 隐私清单：源码与 Release App 内嵌 `PrivacyInfo.xcprivacy` 均通过 `plutil -lint`。清单声明不跟踪、无跟踪域、无收集数据类型，仅为实际使用的磁盘可用空间 API 声明 `NSPrivacyAccessedAPICategoryDiskSpace` / `E174.1`；与当前无网络客户端、无分析 SDK、无照片读取权限的代码一致。
- 最终全量单元测试：`xcodebuild ... -derivedDataPath .build/Module3ReleaseBaseline -resultBundlePath .build/Module3ReleaseBaseline-Units-Retry-20260729.xcresult -only-testing:TakeFlowTests test -quiet`，iPhone 17 Pro / iOS 26.0.1，131 项通过、0 失败、0 跳过。包含模块 1、2 的 74 项基线、56 项模块 3 状态/配置/文件/ViewModel/集成测试和 1 项可见块裁切回归测试。
- 最终全量 UI 测试：`xcodebuild ... -derivedDataPath .build/Module3ReleaseBaseline -resultBundlePath .build/Module3ReleaseBaseline-UI-Final-20260729.xcresult -only-testing:TakeFlowUITests test -quiet`，17 项通过、0 失败、0 跳过。新增 8 项 Fake Capture 流程覆盖允许→就绪→倒计时→录制→停止→本地预览、摄像头拒绝、麦克风拒绝、中断保留、低空间、录制中切换禁用、回前台不自动恢复，以及提词开始/暂停/拖动继续；Fake 仅存在于 Debug。
- 本轮 UI 首次全量复验为 16/17：失败结果包证明 App 已出现新的“正在滚动”元素，但 XCTest 仍轮询倒计时阶段的旧 SwiftUI 可访问性元素。等待器改为每次轮询重新读取可访问性树；期间模拟器服务也出现元素已经存在但 `waitForExistence` 超时及冷启动等待系统 App 约 110 秒的异常。只重启模拟器、不抹除数据后，目标流程 1/1 和最终全量 17/17 通过；没有延长原状态时限、删除测试或接受错误状态。
- 模块 2 硬性能测试使用 iPhone 17 Pro / iOS 26.0.1 模拟器、Debug、从 SwiftData 值读取和后台索引到虚拟化首屏可交互的既定测量方式。一次受模拟器服务异常迟滞影响的尝试真实失败：1 万字符 553.339 ms（读取 5.203、索引 62.222、渲染 485.864 ms），超过 500 ms；同一轮测试进程总耗时异常膨胀到 124 秒。未放宽阈值；冷重启后从零连续三轮各 8/8 通过：1 万字符 236.269 / 430.771 / 248.552 ms（阈值 500 ms），10 万字符 470.239 / 739.123 / 534.147 ms（阈值 2,000 ms）。结果包为 `.build/Module3ReleaseBaseline-Perf-Clean1-20260729.xcresult` 至 `Clean3`；远端跳转、跨块重排、运行事件和缓存上限断言均通过。这些是本机模拟器防退化数据，不是真机保证。
- 最终源码与产品静态检查通过：Swift/GCC 警告即错误构建没有项目源码警告；Xcode 的 AppIntents 元数据工具仍输出既有“未链接 AppIntents，跳过提取”提示。`plutil -lint` 对工程和隐私清单通过，`git diff --check` 通过；扫描未发现密钥、账号、证书、签名资料、构建产物、第三方 SDK、正式 `DEVELOPMENT_TEAM`、完整照片读取权限或模块 4 代码。
- 真机重复进入缺陷根因（2026-07-29）：依赖容器会跨页面复用同一个 `AVFoundationCaptureService`，而原实现只暴露一个非广播 `AsyncStream` continuation。首次页面退出时没有取消旧 `eventTask`、使尚未完成的 `prepare()` 失效或等待 `stopRunning()` 完成，因此旧页面仍可能竞争消费第二次启动的 `.sessionReady`；旧 ViewModel 因已不可见而丢弃该事件，新 ViewModel 则永久停在 `configuring`。这与真机“绿色摄像头指示已出现但新页面黑屏并持续准备”的现象一致。
- 重复进入生命周期加固：每次页面进入建立独立 session UUID 与 ViewModel generation，Capture 事件按生命周期单独投递；退出先使代次失效、取消准备/倒计时/监控任务，再等待同一 AVFoundation 串行队列完成安全停止。配置、`startRunning()`、`stopRunning()`、输入输出修改仍全部在原有单一串行上下文；start、stop、退出均幂等，旧 session 事件不能污染新页面，未创建并行 `AVCaptureSession`。准备超过 12 秒进入类型化错误并显示“重新尝试”；重试会完整结束旧生命周期并生成新 UUID 重新配置，不是只改 UI 状态。
- 录制中退出加固：若页面退出时仍在录制，先请求一次安全停止并等待带原录制 UUID 的完成回调提交文件；8 秒安全界限后仍未完成则保留为可恢复状态，随后再停止会话。停止竞争由 `stoppingRecordingID` 去重，避免用户停止、退出和中断重复调用 Movie Output；迟到完成只允许结算精确匹配的待处理录制，不得更新已退出页面或下一生命周期。
- 重复进入修复后的最终模拟器构建：iPhone 17 Pro / iOS 26.0.1 Debug 与 iPad Pro 11-inch (M4) / iOS 26.0.1 Debug 均 `BUILD SUCCEEDED`。没有新增 Swift 源码警告；仅保留 Xcode AppIntents 元数据工具的既有“未链接 AppIntents”提示。
- 重复进入修复后的设备 SDK Release 复验：`xcodebuild -project TakeFlow.xcodeproj -scheme TakeFlow -configuration Release -destination 'generic/platform=iOS' -derivedDataPath .build/Module3RepeatedEntry-DeviceRelease CODE_SIGNING_ALLOWED=NO build`，arm64 / iOS 17.0，`BUILD SUCCEEDED`。Release App 仅含可执行文件、`Info.plist`、`PrivacyInfo.xcprivacy` 和 `PkgInfo`；字符串扫描未发现 Fake Capture、测试开关或测试摄像头文案，Debug/Release 隔离保持不变。
- 重复进入修复后的最终单元测试：`xcodebuild -project TakeFlow.xcodeproj -scheme TakeFlow -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/DerivedData -resultBundlePath .build/Module3RepeatedEntry-Units-Final-20260729-Retry.xcresult -only-testing:TakeFlowTests test`，iPhone 17 Pro / iOS 26.0.1，139 项通过、0 失败、0 跳过。新增覆盖首次进入→退出→第二次成功、连续 20 次进入退出、准备中退出后重入、重复 start/stop 幂等、首次生命周期迟到回调隔离、准备超时及真实重试、后台/中断后重入，以及录制中退出完成后再释放生命周期。
- 重复进入修复后的最终 UI 测试：iPhone 17 Pro / iOS 26.0.1，19 项通过、0 失败、0 跳过，结果包 `.build/DerivedData/Logs/Test/Test-TakeFlow-2026.07.29_20-10-10-+0800.xcresult`。新增二次进入和准备超时→“重新尝试”→恢复流程。首次全量运行中，既有拖动测试使用 20 行短稿，一次滑动已到真实结尾而得到正确 `finished` 状态；测试稿扩展为 100 行以确保断言的确是中段继续，未放宽状态时限或接受错误状态，最终全量通过。
- 本轮最终全量单元测试内的模块 2 性能回归继续通过：1 万字符从读取、索引到首屏为 98.750 ms，10 万字符为 208.356 ms；普通偏好重排为 0.324 秒，LRU 上限与唯一滚动状态机测试通过。这些是 iPhone 17 Pro / iOS 26.0.1 模拟器 Debug 的单次防退化观测，不是真机性能保证。
- M3-16 真实设备验收（2026-07-29）：iPhone 16 / iOS 26.5.2，测试版本为 `HEAD` `10480d3e37800432d2944bb10383a581be90fd3c` 加本次未提交摄像头生命周期修复。连续 10 轮执行“进入摄像提词→约 1 秒出现预览→录制 5 秒→停止→播放→退出→再次进入”，10/10 通过；每轮文件均可播放且有声音，每轮退出后绿色摄像头指示均消失，全程无需强制结束 App，未再出现黑屏或永久停留在“正在准备摄像头”。这验证了当前页面退出时在同一串行队列停止会话、下一生命周期重新初始化的真实硬件路径。
- M3-16 已通过，但真实方向、镜像、焦点/曝光、防抖、Bluetooth 路由、系统中断、媒体服务重置、低空间封口、Photos、30 分钟热量/功耗/音画同步与异常文件可播放性仍需 M3-01 至 M3-15 验证，因此模块 3 状态保持“进行中”。

## 规格审查：待确认、遗漏与技术风险

下表保留规格原要求，只记录开发前需要解决的决策。除明确标为“阻断”的条目外，不代表删除或降低任何验收条件。

| ID | 类型 | 影响模块 | 问题或风险 | 建议决定 | 状态 |
|---|---|---|---|---|---|
| SPEC-001 | 已解决 | 0、9 | 用户请求中的产品名是“一遍成”，规格 1.0 的暂定名是“一遍过”。 | 已确认内部工程名 `TakeFlow`、用户可见名“一遍成”；规格原文不改写。 | 2026-07-28 已解决 |
| SPEC-002 | 范围遗漏 | 1、2、7 | 核心路径写有“导入稿件”“自动口语化和断句”“试讲并校准语速”，但模块 1 仅支持粘贴并明确排除 PDF/Word；没有文件导入或试讲校准模块；AI 口语化又属于后置 Pro 能力。 | 定义首发导入格式、断句是否本地基础能力、试讲校准流程及免费/Pro 边界。 | 待确认 |
| SPEC-003 | 范围遗漏 | 8、9 | Pro 权益包含“表现分析”，但模块 0–9 没有功能定义、数据模型、隐私边界或验收条件。 | 删除该权益文案或补充独立规格；不得自行虚构实现。 | 待确认，阻断该权益 |
| SPEC-004 | 隐私歧义 | 3、4、9 | 模块 3 必须把麦克风录入视频；模块 4 又称不得“记录或上传用户音频”。Speech Framework 在部分设备/语言下可能需要服务端识别，不能默认等同纯本地。 | 明确该禁令仅针对语音识别副本，还是也约束视频音轨；决定首版强制本地识别，或为系统/云端识别提供明确披露与同意。 | 待确认，阻断语音识别路径 |
| SPEC-005 | 定义遗漏 | 4、5、6 | “基于稿件和录制时间生成字幕”未定义时间戳来源；自由发挥、漏词、重拍和片段替换会让稿件位置与真实语音不一致。 | 定义字幕对齐算法、置信度、人工校正入口、自由发挥文本来源及失败降级。 | 待确认 |
| SPEC-006 | 权益歧义 | 4、7、8 | “有限次数语音跟随”没有计量单位和重置周期；永久买断是可选但无决定；AI 调用是否含额度未定义；离线权益的“合理”保留期不明确。 | 形成完整权益矩阵：计量事件、额度、周期、宽限期、退款/到期、永久权益、AI 成本与离线校验窗口。 | 待确认，阻断付费墙 |
| SPEC-007 | 验收不可量化 | 1、2、3、6 | “不应明显卡死”“基本一致”“不卡住”“没有明显爆音”“无可感知漂移”等没有设备、样本、时长、容差和测量方法。 | 模块 2 已批准模拟器内部阈值：1 万字符 0.5 秒、10 万字符 2 秒、普通重排主线程冻结低于 1 秒；真机阈值及模块 1、3、6 指标仍需确定。 | 模块 2 内部防退化部分解决，其余待确认 |
| SPEC-008 | 已解决 | 3、5、6 | 模块 3 启动前已批准视频、音频、镜像、方向、中断、文件、空间和照片权限矩阵。 | 默认 1080p/30 fps/H.264；能力允许时 4K/30 fps/HEVC；AAC 48 kHz；录制段方向锁定；500/250 MB 空间线；私有目录录制与 Photos add-only 分离。 | 2026-07-29 已解决 |
| SPEC-009 | 存储遗漏 | 0、1、3、5、6、9 | 未定义原片段和成片保留期、项目删除/撤销关系、崩溃遗留文件回收、临时空间预算、备份排除、用户可见存储管理。长视频可能迅速耗尽空间。 | 定义项目目录、保留与清理策略、原子提交、备份策略、低空间阈值和用户确认规则。 | 待确认 |
| SPEC-010 | 云端安全遗漏 | 7、9 | 规定客户端不存密钥，但未指定安全后端、认证、滥用防护、供应商、地域、保留/删除策略、最大稿长和隐私政策披露。 | AI 接入前批准后端架构及数据处理清单；未批准时只允许协议和测试 UI，不得声称服务可用。 | 待确认，阻断真实 AI |
| SPEC-011 | 分析隐私遗漏 | 9 | 成功指标要求匿名非内容型分析，但未指定事件定义、匿名方式、同意机制、SDK/自建方案、标识符、保留期和退出机制。 | 先定义最小事件字典与隐私方案；未批准前不采集。 | 待确认 |
| SPEC-012 | iOS 平台限制 | 3、9 | 普通 iOS App 进入后台后不能依赖摄像头继续录制。规格允许“安全停止或保存当前片段”，这是可实现路径，但不能承诺后台持续拍摄。 | 模块 3 已实现进入后台时发起一次安全停止、保留完成或可恢复文件、回前台不自动继续；真实系统调度与封口结果仍待 M3-07 验证。 | 实现完成，真机风险待验证 |
| SPEC-013 | 设备能力风险 | 3、4 | 4K、特定焦点/曝光模式、前后摄像头组合、蓝牙麦克风和本地语音识别并非所有 iOS 17 设备都支持。 | 全部能力运行时探测、隐藏不可用选项、保留固定速度与 1080p 降级，并建立设备矩阵。 | 风险已标记 |
| SPEC-014 | 性能风险 | 3、5、6 | 30 分钟 4K 录制、多片段合成、字幕烧录可能产生显著发热、存储和导出耗时；后台/锁屏也会中断导出或录制。 | 采用分阶段写入、进度与取消、热状态提示、空间预估，并在目标真机上建立基准。 | 风险已标记 |
| SPEC-015 | 上架依赖遗漏 | 8、9 | 隐私政策、使用条款、支持页面、订阅商品 ID、App Store Connect 配置、截图设备/语言和 App Review 账号尚未提供。 | 模块 8 前确定商品；模块 9 前提供有效公开 URL、商店资料和审核说明输入。 | 待外部资料 |
| SPEC-016 | 可访问性范围 | 2、3、7、8、9 | 模块 2 只要求核心按钮可识别，模块 9 又要求 VoiceOver 核心流程可操作；录制、字幕编辑、AI 差异和订阅页的操作语义尚未逐项定义。 | 把无障碍作为所有模块的横切验收，而不是最后补做。 | 风险已标记 |

## 关键决策记录

| 日期 | 决策 | 影响 | 批准人 |
|---|---|---|---|
| 2026-07-28 | 内部工程名与 Scheme 使用 `TakeFlow`；App 显示名使用“一遍成” | 模块 0、9 与所有用户可见文案 | 产品负责人（用户） |
| 2026-07-28 | Bundle ID 暂用 `com.example.takeflow.placeholder`，不设置正式开发团队 | 模块 0、8、9；真机安装和归档暂不可作为发布证据 | 产品负责人（用户） |
| 2026-07-28 | 领域模型使用 Swift 6 `Sendable` 值类型；真实持久化适配器留到模块 1，模块 0 只建立异步协议并用测试 Mock 验证契约 | Core、模块 1 及后续依赖 | 模块 0 架构决策 |
| 2026-07-28 | 模块 1 使用 `ScriptSchemaV1` 版本化 SwiftData Schema；稳定 UUID 为领域标识；生产 Store 仅本地、CloudKit 关闭；V1 发布后不回改，后续字段变更新增 Schema 版本并优先轻量迁移，语义转换使用显式 `MigrationStage` | Core/Persistence、ScriptEditor 与后续读取稿件的模块 | 模块 1 架构决策 |
| 2026-07-28 | 编辑自动保存采用可注入时钟的 600 ms 防抖；进入后台或离开编辑页时立即冲刷；保存失败保留屏幕草稿并显示用户可理解错误，不把失败状态伪装为已保存 | ScriptEditor、生命周期恢复 | 模块 1 架构决策 |
| 2026-07-28 | 在 600 ms 正式保存之外，每次编辑立即异步写入独立恢复快照；恢复文件位于 Application Support、采用原子替换与版本屏障；只有基础版本精确匹配且更新时才向用户提供恢复/保留选择，正式保存成功后清理 | Core/Persistence、ScriptEditor、崩溃恢复与后续迁移 | 模块 1 数据安全加固决策 |
| 2026-07-28 | 删除采用 SwiftData 软删除标记与 5 秒撤销令牌；窗口内恢复，窗口结束后精确永久删除目标 UUID；复制生成新 UUID | ScriptEditor、后续项目引用规则 | 模块 1 架构决策 |
| 2026-07-28 | 字数按去除空白后的扩展字素簇计数；预计时长默认 240 字符/分钟，可在 60–600 范围调整；最后阅读位置写入稿件记录并按正文长度夹紧 | ScriptEditor、Teleprompter 接口 | 模块 1 产品实现假设，待产品在后续模块确认默认语速 |
| 2026-07-28 | 模块 2 使用 SwiftData V2 轻量迁移保存每稿提词偏好；速度单位固定为逻辑点/秒；阅读位置使用扩展字素簇偏移；滚动按单调时间运行段推导，布局像素不作为持久化事实 | Core/Persistence、Teleprompter、模块 3 后续复用 | 模块 2 架构决策 |
| 2026-07-28 | 提词拖动期间使用滚动比例维护轻量近似锚点，结束时使用 TextKit 精确解析；这是为 10 万字符避免每帧全文命中布局的性能边界，不改变最终保存的 Character 锚点语义 | Teleprompter 文本桥接与长稿性能 | 模块 2 性能决策 |
| 2026-07-28 | 长稿采用后台 `TeleprompterDocument` 分块索引和原生 Collection View 虚拟化；块目标 1,500、硬上限 2,200 Character，预取前 1 后 2，富文本 LRU 上限 8；全局 Character 锚点与原状态机保持唯一 | Teleprompter 长稿性能、模块 3 复用边界 | 模块 2 性能加固决策 |
| 2026-07-28 | 模块 2 模拟器内部防退化阈值为：1 万字符首屏 0.5 秒、10 万字符首屏 2 秒、普通显示设置重排主线程冻结低于 1 秒；测试必须硬失败并记录设备/系统/方法，不能替代真机性能结论 | 模块 2 测试与发布风险记录 | 产品负责人（用户） |
| 2026-07-29 | 模块 3 录制矩阵采用默认 1080p/30 fps/H.264、能力允许时 4K/30 fps/HEVC、AAC 48 kHz；前摄只镜像预览，录制段冻结 Rotation Coordinator 输出角度；不提供 60 fps、HDR、ProRes、双摄或后台持续录制 | CameraRecording、后续片段与导出兼容性 | 产品负责人（用户） |
| 2026-07-29 | 录制采用唯一显式状态机和带 UUID 的异步事件；AVFoundation 隔离在串行服务，文件先建元数据和独立临时文件，只有完成回调成功后提交为可播放；500 MB 阻止起录、250 MB 安全停止，Photos 仅在主动保存时 add-only 请求 | CameraRecording、Core/Persistence、模块 5/6 接口 | 模块 3 架构决策 |
| 2026-07-29 | 摄像头叠加继续复用模块 2 的唯一提词状态机、全局 Character 锚点和分块虚拟化；可见块改用有界 TextKit 1 与确定高度计算，锚点精调延后一轮主 actor 并由 revision 防止过期回调，LRU 上限仍为 8 | Teleprompter、CameraRecording、长稿性能 | 模块 3 性能回归决策 |

## 更新规则

1. 开始模块时将状态改为“进行中”，并记录范围和基线测试。
2. 出现无法继续的产品或外部依赖时改为“受阻”，链接对应 SPEC 编号。
3. 每次构建和测试记录实际命令、环境、通过数、失败数；未运行不得写“通过”。
4. 所有未自动验证的行为加入 `MANUAL_TEST_CHECKLIST.md`。
5. 只有逐条验收完成、证据齐全后才能改为“已完成”。

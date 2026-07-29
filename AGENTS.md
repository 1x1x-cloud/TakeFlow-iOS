# 一遍成 iOS 项目开发规则

本文件是仓库内所有后续开发任务必须遵守的永久规则。产品负责人已于 2026-07-28 确认：内部工程名和 Scheme 使用 `TakeFlow`，用户可见 App 显示名使用“一遍成”。`PRODUCT_SPEC.md` 1.0 中的“一遍过”仅为早期暂定名，保留原文但不再用于新增工程配置或用户界面。

## 项目上下文与事实来源

- 本目录是 ChatGPT 项目 “TakeFLow-project” 的本地镜像。
- `sources/` 下所有文件仅作只读参考；不得编辑、重命名、移动或删除，它们可能在下一次同步时被替换。
- `PRODUCT_SPEC.md` 是产品范围和验收条件的唯一基准，不得擅自缩减。
- `DEVELOPMENT_STATUS.md` 是模块完成度、构建、测试和风险的事实记录。
- `MANUAL_TEST_CHECKLIST.md` 是所有未能自动验证的真机项目的事实记录。
- 规范、实现和状态记录冲突时，停止受影响的实现，记录冲突并请求产品决策；不得静默选择更容易的解释。

## 每次开发前

1. 完整阅读 `PRODUCT_SPEC.md`、本文件和 `DEVELOPMENT_STATUS.md`。
2. 检查现有代码、测试、工程配置和版本控制状态，保留用户已有修改。
3. 用自己的话复述目标、范围、明确不做的内容、状态与数据流、失败场景及验证计划。
4. 检查 `DEVELOPMENT_STATUS.md` 中未解决的阻断项；受阻模块不得先行实现。
5. 不得以占位业务逻辑、写死返回值、仅能演示的假数据或 Mock 冒充功能完成。Mock 只能用于测试和规格明确允许的未接入服务流程。

## 不可违反的产品原则

优先级依次为：录制稳定；不丢稿、不丢片段；本地优先和明确授权；免费核心体验可用；AI 与订阅故障不阻塞基础功能；离线可用；视觉润色。

- 免费用户必须能完成至少一次 1080p 录制和无水印导出。
- 稿件、已落盘片段和源视频不得因崩溃、中断、导出失败或取消而被静默丢失。
- 未经用户针对具体行为明确授权，不得访问摄像头、麦克风、照片，也不得上传稿件、音频或视频。
- 任何发布阻断条件仍存在时，不得声称已具备 App Store 提交条件。

## 架构规则

### 模块与依赖

- 保持规格中的模块边界：`App`、`Core`、`ScriptEditor`、`Teleprompter`、`CameraRecording`、`SpeechTracking`、`RetakeComposer`、`Captioning`、`VideoExport`、`Subscription`、`Settings`。
- `App` 仅负责启动、导航和依赖组装；功能模块不得直接依赖 `App`。
- 通用模型、协议、错误、权限、持久化、日志和工具放入 `Core`。`Core` 不得反向依赖任何功能模块。
- 功能模块之间通过小而稳定的协议或领域值传递数据，不得读取彼此的 View、内部存储实现或全局单例。
- SwiftUI View 只负责呈现和转发用户意图。持久化、文件、摄像头、录音、识别、导出、购买等逻辑必须位于独立服务或领域组件。
- 服务必须协议化并通过构造器或环境显式注入。生产实现与测试替身分离。

### 状态、并发与生命周期

- 使用 Swift 6 严格并发检查。共享可变状态必须由 actor、明确隔离的串行执行器或不可变值保护。
- UI 可观察状态和 UI 更新必须位于 `@MainActor`；不得在主线程执行媒体编码、文件遍历、识别匹配或大文本处理。
- AVFoundation 会话、录制状态机和 writer 生命周期必须与 SwiftUI View 生命周期隔离；禁止让 View 直接拥有关键录制资源。
- 所有长任务必须支持取消，并定义取消、失败、重试、前后台切换和进程终止后的状态。
- 状态机转换必须显式、可测试；非法转换返回领域错误，不得静默忽略。

### 基础提词器不变量

- 固定速度的持久化和界面单位统一为逻辑点/秒；不得改回无单位倍率，改变映射必须新增迁移并更新测试。
- 滚动位置必须由单调时钟的运行段起点和实际经过时间推导，不得按帧累加固定像素，也不得累计后台时间。
- `ScriptReadingAnchor` 的持久化语义是 Swift 扩展字素簇（`Character`）偏移；像素偏移仅是当前布局的瞬时结果，不得单独作为跨布局恢复依据。
- 字号、行距、边距、区域宽度、Dynamic Type、方向和设备尺寸变化必须通过内容锚点重新解析布局；不得重置为开头。
- 长稿索引必须在后台一次建立，按段落或 Swift `Character` 安全边界分块；不得在主线程同步把 10 万字符整篇重复赋给 TextKit，也不得在滚动帧中重复执行全文 `String.count`、裁剪或布局。
- 基础提词器使用原生虚拟化呈现：只保留可见块、相邻预加载块和固定上限缓存。当前块目标 1,500 Character、硬上限 2,200 Character、富文本 LRU 上限 8；调整这些常量必须重新通过 1 万/10 万字符硬性能、边界完整性、远端跳转和内存上限测试。
- 全局 Character 偏移与块内偏移必须可逆；正文内容版本变化必须重建索引。内存警告可以释放非当前缓存，但不得丢失稿件、阅读锚点或创建第二套滚动状态。
- 模块 3 及后续摄像提词层必须复用提词状态机、锚点和服务协议，不得复制出第二套滚动状态或绕过恢复草稿检查。
- 提词显示偏好与阅读位置通过 `TeleprompterScriptProviding` 保存；SwiftUI View 和 UIKit 文本桥接不得直接访问 SwiftData。

### 摄像录制不变量

- `RecordingStateMachine` 是录制生命周期的唯一事实来源；权限请求、会话配置、起录、录制、停止、完成、中断和失败不得由互相独立的 View 布尔值拼接。
- `AVCaptureSession`、设备配置和 `AVCaptureMovieFileOutput` 调用只在独立串行执行上下文运行；delegate 事件必须携带录制 UUID，并在 `@MainActor` ViewModel 通过代次校验后更新 UI，旧回调不得污染新录制。
- 录制能力必须从当前设备、Preset、格式、30 fps 范围和可用编码器动态探测。默认 1080p/30 fps/H.264；仅在实际支持时提供 4K/30 fps/HEVC；首发不得加入 60 fps、HDR、Dolby Vision、ProRes 或双摄同录。
- 前摄预览默认镜像、文件默认不镜像；后摄预览和文件均不镜像。预览与输出分别使用 `AVCaptureDevice.RotationCoordinator` 和 `videoRotationAngle`，开始录制后锁定当前段的输出角度，录制中禁止切换摄像头。
- 音频目标为 AAC 48 kHz；必须显示当前输入路由并监听路由和中断变化。麦克风不可用或音频配置失败时不得生成让用户误认为有声的正常成片。
- 录制目录固定在 Application Support 下，以项目 UUID 和录制 UUID 隔离。元数据先于起录创建，临时 `.recording.mov` 只在完成回调后移动为可播放 `.mov`；中断、写入失败和遗留临时文件保留为 `recoverable`，不得冒充完成或自动删除。
- 起录空间安全线为 500 MB，录制中安全停止线为 250 MB，默认每 5 秒检查一次；阈值集中在 `RecordingStoragePolicy`，修改后必须重跑低空间、并发停止和文件保留测试。
- App 进入后台、来电或音频中断、会话被占用、媒体服务重置时不得继续录制；尽可能安全封口，回到前台后保持中断状态，必须由用户明确重新开始。
- 私有目录录制不请求照片权限；仅用户主动保存时请求 `PHAccessLevel.addOnly`。拒绝后保留 App 内文件并继续提供系统分享。
- 摄像提词层必须复用 `TeleprompterViewModel`、`TeleprompterPlaybackMachine`、`TeleprompterDocument` 和有界虚拟化视图。相机预览及状态事件不得触发整篇正文重新布局，提词和控制层不得进入 `AVCaptureMovieFileOutput`。

### 数据与文件安全

- `Script`、`RecordingProject`、`RecordingSegment` 使用稳定 UUID；持久化关系和文件目录以 ID 关联，不以用户标题作为路径。
- 每个录制项目使用独立目录。源片段、工作临时文件、导出中的文件和最终成片必须分区存放。
- 写入元数据和关键小文件时采用原子替换；视频写入成功后再提交对应元数据状态，恢复流程必须能够发现孤立文件和缺失文件。
- 大文本未完成编辑使用 Application Support 下的独立恢复文件，不得写入 UserDefaults 或 Caches。恢复文件必须原子替换、按稳定 ID 命名、带正式记录版本依据和单调 revision；正式保存后清理，恢复前必须让用户在草稿与已保存版本之间明确选择。
- 新片段永不覆盖旧片段。导出成功并经用户确认前不得删除源片段。
- 删除必须精确限制在目标项目目录，校验归属和标准化路径；不得使用宽泛递归删除。
- 为低存储、写入失败、文件损坏、文件缺失和迁移失败提供可理解提示和恢复路径。
- 在产品决策明确前，不得自行启用 iCloud/CloudKit，也不得假定大体积视频会被云备份。

## 隐私与安全

- 默认本地处理、最少权限、最少数据和目的限定。权限在用户触发相关功能时按需申请，不在首次启动集中索取。
- 日志和分析不得包含稿件正文、识别文本、音频、视频、字幕正文、完整本地路径、联系人信息、稳定用户标识、购买凭证或密钥。
- OSLog 使用隐私标记；发布日志只记录非内容型事件、错误分类、匿名计数和耗时。
- 语音跟随必须明确区分“视频录音”和“语音识别数据”。若系统识别可能使用网络服务，必须在实现前解决 `DEVELOPMENT_STATUS.md` 中对应隐私决策，不能把可能上传的路径描述为纯本地。
- AI 上传前必须逐次清楚展示发送内容类别、目的和服务方；取消、拒绝、失败或异常返回都不得覆盖原稿。
- 服务端密钥不得进入客户端源码、资源、构建设置、日志或 Git 历史。云端 AI 必须通过受控后端或等价的安全代理。
- 第三方 SDK 必须事先批准，并记录数据行为、隐私清单、许可和移除方案。不得仅为统计或便利引入 SDK。
- `PrivacyInfo.xcprivacy`、Info.plist 权限文案、App Store 隐私披露和实际网络/数据行为必须一致。
- 敏感本地内容使用合适的数据保护等级；设备锁定、备份排除、共享和清理策略在相关模块实现时必须记录并测试。

## 编码规范

- 使用当前稳定 Xcode 支持的 Swift 6，最低部署目标 iOS 17，同时支持 iPhone 与 iPad。
- 新代码不得使用废弃 API，不得产生未解释的编译警告。
- 不对用户数据、文件 URL、设备能力、权限状态或服务返回值使用强制解包、`try!` 或不可控的 `fatalError`。
- 错误使用类型化领域错误表达，并在 UI 层转成可操作提示；底层错误不得直接展示敏感细节。
- 类型和函数保持单一职责；公共接口写清线程/actor 隔离、所有权、失败和取消语义。
- 使用值类型承载不可变领域数据；时间、字数、语速、分辨率、方向和文件状态避免使用无语义裸值。
- 用户可见文本集中管理，为中文文案及后续本地化留出结构；不得散落硬编码在业务逻辑中。
- 所有核心控件提供可访问名称、提示、状态和值；支持 Dynamic Type、VoiceOver、深浅色和合理的 iPad 布局。
- 不加入未经批准的依赖，不修改测试来掩盖缺陷，不降低编译、并发或验收标准。

## 构建方法

工程文件为 `TakeFlow.xcodeproj`，共享 Scheme 为 `TakeFlow`。所有本地构建产物写入被 Git 忽略的 `.build/`。执行测试前必须先通过 `-showdestinations` 确认当前机器的模拟器名称；以下名称是模块 0 已验证的基线。

```sh
# 枚举 Scheme 与可用目标
xcodebuild -list -project TakeFlow.xcodeproj
xcodebuild -showdestinations -project TakeFlow.xcodeproj -scheme TakeFlow

# iPhone Debug 模拟器构建
xcodebuild -project TakeFlow.xcodeproj \
  -scheme TakeFlow \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/DerivedData \
  build

# iPad Debug 模拟器构建
xcodebuild -project TakeFlow.xcodeproj \
  -scheme TakeFlow \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' \
  -derivedDataPath .build/DerivedData \
  build

# 单元测试
xcodebuild -project TakeFlow.xcodeproj \
  -scheme TakeFlow \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/DerivedData \
  -only-testing:TakeFlowTests \
  test

# 全部 UI 测试（含启动、自动保存、复制、删除确认与撤销）
xcodebuild -project TakeFlow.xcodeproj \
  -scheme TakeFlow \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/DerivedData \
  -only-testing:TakeFlowUITests \
  test

# 发布前 Release 归档；仅在正式 Bundle ID 和开发团队获批后执行
xcodebuild -project TakeFlow.xcodeproj \
  -scheme TakeFlow \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  archive \
  -archivePath .build/TakeFlow.xcarchive
```

- 当前 Bundle Identifier `com.example.takeflow.placeholder` 是明确占位值；正式 Bundle ID 和 `DEVELOPMENT_TEAM` 尚未配置。获得批准前不得伪造签名配置，也不得把占位包标识用于发布。
- 不得把 DerivedData、归档、导出视频、真实稿件、密钥或购买凭证提交到仓库。
- 构建失败时保留完整错误证据；不得通过删除 Target、测试或安全设置来取得绿色结果。

## 测试要求

- 每个核心业务规则和每个错误分支至少有一个自动化测试。
- 纯逻辑优先单元测试：文本规范化、滚动状态机、语音匹配、片段排序、字幕时间线、权益判断、文件清理决策。
- 使用协议替身覆盖权限拒绝、文件失败、空间不足、服务中断、超时、取消、异常返回和恢复。
- 持久化测试必须使用隔离的临时容器；文件测试必须证明不会跨项目删除。
- UI 测试覆盖至少一个免费核心流程和关键权限/错误呈现，但不得用 UI 测试代替领域单元测试。
- 对 10 万字符编辑、长稿滚动、片段数量和导出状态执行性能或基准测试，结果记录设备/模拟器与阈值。
- AVFoundation、Speech、照片保存、StoreKit Sandbox、连续录制、音画同步、发热、旋转、蓝牙音频和真实中断必须进入 `MANUAL_TEST_CHECKLIST.md`。
- “通过”只能基于本轮实际执行结果；未运行、仅阅读、只在模拟器验证的真机行为一律标记“未验证”。
- 每个模块完成时逐条记录验收项、状态、命令/设备、结果、失败原因和遗留风险。

## 完成与状态更新

- 只有代码、构建、自动化测试和该模块所需真机验证都满足规格，且无未解决阻断项时，模块才能标记“已完成”。
- 部分实现标记“进行中”，依赖产品决定或外部条件标记“受阻”，从未开始实现标记“未开始”。
- 每次修改后同步更新 `DEVELOPMENT_STATUS.md`；新增未自动验证行为同步加入 `MANUAL_TEST_CHECKLIST.md`。
- 最终回报严格采用 `PRODUCT_SPEC.md` 第七章格式，并明确区分“通过”“失败”“未验证”。

# Teleprompter

模块 2 的无摄像头基础提词器。

- `TeleprompterPlaybackMachine` 是与界面分离的确定性状态机，只接收单调时钟经过秒数，并以点/秒计算滚动距离。
- `ScriptReadingAnchor` 保存正文 Character 偏移；像素位置仅是当前布局的瞬时状态。
- `TeleprompterDocument` 在后台一次建立内容版本、段落优先的安全分块和全局/块内 Character 双向索引；目标块 1,500 字符，硬上限 2,200 字符。
- `TeleprompterTextView` 使用原生 `UICollectionView` 虚拟化 TextKit 2 单元，仅呈现可见块并预取前 1、后 2 块；富文本 LRU 缓存上限为 8，内存警告时释放非可见项。
- `TeleprompterViewModel` 负责生命周期、唯一滚动状态机和通过 `TeleprompterScriptProviding` 保存阅读位置及每稿显示偏好；滚动期间不重复扫描全文。
- 字号、行距、边距、宽度及尺寸变化只失效当前呈现缓存，并以全局 Character 锚点重新定位，不把像素偏移写入持久化。
- `TeleprompterView` 与 UIKit 桥接只负责显示和转发用户意图，不直接访问 SwiftData。

本模块不依赖或实现摄像头、麦克风、语音识别及后续媒体能力。

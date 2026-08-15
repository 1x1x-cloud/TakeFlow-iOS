import Foundation

enum ScriptEditorStrings {
    static let libraryTitle = "稿件"
    static let addScript = "新建稿件"
    static let unnamedScript = "未命名稿件"
    static let emptyLibraryTitle = "还没有稿件"
    static let emptyLibraryDescription = "新建一份空白稿件，开始准备口播内容。"
    static let emptySearchTitle = "没有匹配的稿件"
    static let emptySearchDescription = "请尝试搜索其他标题或正文内容。"
    static let searchPrompt = "搜索标题或正文"
    static let duplicate = "复制"
    static let delete = "删除"
    static let deleteTitle = "删除这份稿件？"
    static let deleteMessage = "稿件会先进入短暂的可撤销状态。"
    static let deleteAccessibilityHint = "打开删除确认，不会立即删除稿件"
    static let cancelDeletion = "取消删除稿件"
    static let confirmDeletion = "确认删除稿件"
    static let cancel = "取消"
    static let undo = "撤销"
    static let deleted = "稿件已删除"
    static let errorTitle = "操作未完成"
    static let dismiss = "好"
    static let titlePlaceholder = "稿件标题"
    static let contentPlaceholder = "粘贴或输入稿件正文"
    static let emptyContent = "正文为空"
    static let settings = "稿件设置"
    static let speechRate = "预计语速"
    static let decreaseSpeechRate = "降低预计语速"
    static let increaseSpeechRate = "提高预计语速"
    static let readPosition = "最后阅读位置"
    static let moveReadPositionBackward = "后退 10 字"
    static let moveReadPositionForward = "前进 10 字"
    static let saving = "正在保存…"
    static let saved = "已保存"
    static let pendingSave = "等待自动保存"
    static let saveFailed = "保存失败，当前内容仍保留在屏幕上。"
    static let loading = "正在读取稿件…"
    static let recoveryTitle = "发现未完成编辑"
    static let recoveryMessage =
        "恢复草稿比已保存版本更新。请选择要继续使用的版本。"
    static let recoverDraft = "恢复草稿"
    static let keepSavedVersion = "保留已保存版本"

    static func deleteTarget(_ title: String) -> String {
        "将要删除：\(title)"
    }

    static func duplicateTitle(for title: String) -> String {
        let visibleTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return visibleTitle.isEmpty
            ? "\(unnamedScript) 副本"
            : "\(visibleTitle) 副本"
    }

    static func characterCount(_ count: Int) -> String {
        "\(count) 字"
    }

    static func estimatedDuration(_ duration: String) -> String {
        "约 \(duration)"
    }

    static func speechRate(_ rate: Int) -> String {
        "\(rate) 字/分钟"
    }

    static func readPosition(_ position: Int, total: Int) -> String {
        "\(position)/\(total)"
    }
}

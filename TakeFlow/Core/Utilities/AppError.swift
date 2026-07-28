import Foundation

enum AppError: Error, Equatable, Sendable {
    case invalidState
    case permissionDenied
    case persistenceUnavailable
    case fileOperationFailed
    case serviceUnavailable
    case scriptNotFound
    case undoExpired
    case recoveryDraftUnavailable
    case recoveryDraftCorrupted
    case recoveryDraftVersionMismatch
    case recoveryDraftCleanupFailed
    case cancelled
}

extension AppError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "当前状态无法完成此操作。"
        case .permissionDenied:
            return "缺少完成此操作所需的权限。"
        case .persistenceUnavailable:
            return "暂时无法保存或读取内容。"
        case .fileOperationFailed:
            return "文件操作失败，请检查可用存储空间后重试。"
        case .serviceUnavailable:
            return "所需服务当前不可用。"
        case .scriptNotFound:
            return "找不到这份稿件，它可能已被删除。"
        case .undoExpired:
            return "撤销时间已结束，稿件已删除。"
        case .recoveryDraftUnavailable:
            return "暂时无法保护未完成编辑，请等待稿件显示“已保存”后再退出。"
        case .recoveryDraftCorrupted:
            return "发现无法读取的恢复草稿，已保留最近保存的稿件版本。"
        case .recoveryDraftVersionMismatch:
            return "恢复草稿与当前稿件版本不匹配，已保留最近保存的版本。"
        case .recoveryDraftCleanupFailed:
            return "稿件已保存，但无法清理旧的恢复草稿，请稍后重试。"
        case .cancelled:
            return "操作已取消。"
        }
    }
}

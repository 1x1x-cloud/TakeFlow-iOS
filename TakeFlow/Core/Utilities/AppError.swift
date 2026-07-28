import Foundation

enum AppError: Error, Equatable, Sendable {
    case invalidState
    case permissionDenied
    case persistenceUnavailable
    case fileOperationFailed
    case serviceUnavailable
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
        case .cancelled:
            return "操作已取消。"
        }
    }
}

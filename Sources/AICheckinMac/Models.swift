import Foundation

// MARK: - 平台与账号模型

enum PlatformKind: String, CaseIterable {
    case trae = "Trae"
    case workBuddy = "WorkBuddy"
    case qoder = "Qoder"

    /// 卡片右上角标签
    var label: String { rawValue }

    /// 账号 id 前缀，保证各平台 uid 不撞
    var prefix: String {
        switch self {
        case .trae: return "tr"
        case .workBuddy: return "wb"
        case .qoder: return "qd"
        }
    }
}

/// 一个可签到的账号（来自本机客户端凭据）
struct PlatformAccount: Identifiable {
    let id: String          // "<prefix>:<uid>"
    let platform: PlatformKind
    let uid: String
    let displayName: String
    let source: String      // 客户端形态说明，如 "CodeBuddy CN"
}

/// 一次拉取到的账号用量/签到状态
struct PlatformUsage: Identifiable {
    let id: String
    var ok: Bool = false
    var message: String = ""
    var signed: Bool = false
    /// 今日获得（WB）或今日领取数（Qoder）
    var todayCredits: Double? = nil
    var balance: Double? = nil
    var total: Double? = nil
    /// 连续签到天数（WB）
    var streak: Int? = nil
    /// 今日会话数（Trae）
    var sessions: Int? = nil
    /// 卡片副标题：可领活动数 / 套餐名 / 邮箱等
    var detail: String = ""
}

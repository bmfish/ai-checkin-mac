import Combine
import Foundation

// MARK: - 界面状态与刷新

final class UsageModel: ObservableObject {

    @Published var accounts: [PlatformAccount] = []
    @Published var usage: [PlatformUsage] = []
    @Published var loaded = false
    @Published var busy = false
    @Published var signing = false
    @Published var note = ""
    @Published var tip = ""
    @Published var startHour: Int
    @Published var autostart: Bool
    @Published var windowHeight: CGFloat = 430

    private let workQueue = DispatchQueue(label: "ai-checkin.work", qos: .utility)
    private let defaults = UserDefaults.standard

    init() {
        let stored = defaults.object(forKey: "startHour") as? Int
        startHour = stored ?? 9
        autostart = LoginItem.isEnabled
    }

    // MARK: 汇总

    private var signedIDs: Set<String> {
        Set(usage.filter { $0.ok && $0.signed }.map(\.id))
    }

    var signedCount: Int {
        accounts.filter { signedIDs.contains($0.id) }.count
    }

    var allSigned: Bool {
        !accounts.isEmpty && signedCount == accounts.count
    }

    static func money(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 0.005 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.2f", rounded)
    }

    static func dateText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func timeText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    // MARK: 刷新

    func refresh() {
        guard !busy else { return }
        busy = true
        workQueue.async { [weak self] in
            guard let self else { return }
            let found = AccountDiscovery.discover()
            var rows: [PlatformUsage] = []

            // Trae：今日消耗 / 会话数 / 余额，签到状态单独查一次
            let traeCreds = TraeClientCredentials.discover()
            if !traeCreds.isEmpty {
                for item in TraeUsage.today() {
                    var row = PlatformUsage(id: "\(PlatformKind.trae.prefix):\(item.uid)")
                    row.ok = item.ok
                    row.message = item.message
                    row.todayCredits = item.credits
                    row.sessions = item.sessions
                    row.balance = item.balance
                    row.total = item.total
                    row.detail = item.app
                    if let cred = traeCreds.first(where: { $0.uid == item.uid }),
                       let jwt = TraeSupport.jwt(for: cred) {
                        let status = TraeCheckin.status(jwt: jwt, uid: cred.uid,
                                                        deviceID: cred.deviceID)
                        row.signed = status.checkedIn
                    }
                    rows.append(row)
                }
            }

            if let cred = WorkBuddyClient.discover().first {
                let status = WorkBuddyClient.status(cred)
                var row = PlatformUsage(id: "\(PlatformKind.workBuddy.prefix):\(cred.uid)")
                row.ok = status.ok
                row.message = status.message
                row.signed = status.signed
                row.streak = status.streak
                let today = status.todayCredit > 0 ? status.todayCredit : status.dailyCredit
                row.todayCredits = today
                if let balance = WorkBuddyClient.balance(cred) {
                    row.balance = balance.remain
                    row.total = balance.total
                    row.detail = balance.plan
                }
                rows.append(row)
            }

            if let auth = QoderClient.loadAuth() {
                let uid = auth.uid.isEmpty ? (auth.email.isEmpty ? "account" : auth.email) : auth.uid
                let (items, unauthorized) = QoderClient.campaigns(auth)
                var row = PlatformUsage(id: "\(PlatformKind.qoder.prefix):\(uid)")
                row.ok = !unauthorized
                row.message = unauthorized ? "登录已过期，请重新登录 Qoder" : ""
                let claimable = items.filter(\.claimable).count
                row.signed = claimable == 0 && !unauthorized
                row.todayCredits = Double(claimable)
                row.detail = claimable > 0 ? "可领 \(claimable) 个活动" : "暂无新活动"
                rows.append(row)
            }

            let accounts = found
            let updated = Self.timeText()
            DispatchQueue.main.async {
                self.accounts = accounts
                self.usage = rows
                self.loaded = true
                self.busy = false
                self.tip = "更新于 \(updated)"
                self.note = self.summaryText()
                self.windowHeight = self.preferredHeight()
            }
        }
    }

    // MARK: 手动签到

    func checkin() {
        guard !signing else { return }
        signing = true
        workQueue.async { [weak self] in
            guard let self else { return }
            let results = CheckinRunner.runOnce(force: true, startHour: self.startHour)
            let done = results.filter { $0.action == .done || $0.action == .already }
            let credits = done.reduce(0.0) { $0 + $1.credits }
            let failed = results.first { $0.action == .failed }
            DispatchQueue.main.async {
                self.signing = false
                if let failed {
                    self.note = "签到失败：\(failed.message)"
                } else if !done.isEmpty {
                    self.note = "签到完成 · 获得 \(Self.money(credits)) 积分"
                }
                self.refresh()
            }
        }
    }

    // MARK: 设置

    func setStartHour(_ hour: Int) {
        startHour = min(23, max(0, hour))
        defaults.set(startHour, forKey: "startHour")
    }

    func toggleAutostart() {
        let target = !autostart
        if let error = LoginItem.setEnabled(target) {
            tip = "自启设置失败：\(error)"
        } else {
            autostart = target
            tip = target ? "已开启开机自启" : "已关闭开机自启"
        }
    }

    // MARK: 文案与窗口高度

    private func summaryText() -> String {
        guard !accounts.isEmpty else { return "" }
        // WorkBuddy 的 todayCredits 是积分，Qoder 的是可领活动数，分开表述
        let wbCredits = usage.filter { $0.id.hasPrefix("wb:") }
            .compactMap(\.todayCredits).reduce(0, +)
        let qdClaimable = usage.filter { $0.id.hasPrefix("qd:") }
            .compactMap(\.todayCredits).reduce(0, +)
        var parts: [String] = []
        if wbCredits > 0 { parts.append("今日 \(Self.money(wbCredits)) 积分") }
        if qdClaimable > 0 { parts.append("Qoder \(Int(qdClaimable)) 个可领") }
        return parts.joined(separator: " · ")
    }

    private func preferredHeight() -> CGFloat {
        let cards = accounts.reduce(CGFloat(0)) { sum, account in
            switch account.platform {
            case .trae, .workBuddy: return sum + 176
            case .qoder: return sum + 118
            }
        }
        let height = 100 + max(cards, 118) + 120
        return min(720, max(340, height))
    }
}

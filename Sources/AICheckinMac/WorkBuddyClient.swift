import CryptoKit
import Foundation

// MARK: - WorkBuddy（CodeBuddy 客户端）签到
//
// 凭证来源：~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info
//   { "account": {uid, nickname, ...},
//     "auth": {accessToken, refreshToken, expiresAt, domain, ...} }
// 接口（与 Windows 版一致）：
//   POST {base}/v2/billing/meter/checkin-activity-status   预检
//   POST {base}/v2/billing/meter/daily-checkin             签到
//   POST {base}/billing/meter/get-user-resource-summary    余额
//   POST https://www.codebuddy.cn/v2/plugin/auth/token/refresh   RT 续签

enum WorkBuddyClient {

    struct Credential {
        let uid: String
        let nickname: String
        var accessToken: String
        var refreshToken: String
        let domain: String

        var billingBase: String {
            domain.contains(".workbuddy.ai") ? "https://www.workbuddy.ai" : "https://www.codebuddy.cn"
        }
    }

    static var infoPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info")
            .path
    }

    // MARK: 发现账号

    static func discover() -> [Credential] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let auth = root["auth"] as? [String: Any],
              let token = auth["accessToken"] as? String, !token.isEmpty,
              let account = root["account"] as? [String: Any],
              let uid = account["uid"] as? String, !uid.isEmpty
        else { return [] }
        let nickname = (account["nickname"] as? String) ?? ""
        return [Credential(
            uid: uid,
            nickname: nickname.isEmpty ? uid : nickname,
            accessToken: token,
            refreshToken: (auth["refreshToken"] as? String) ?? "",
            domain: (auth["domain"] as? String) ?? ""
        )]
    }

    // MARK: 请求头（客户端形态）

    static func headers(_ c: Credential) -> [String: String] {
        let machine = sha256("wb-fingerprint:machine:\(c.uid)").prefix(32)
        let session = sha256("wb-fingerprint:session:\(c.uid)").prefix(32)
        return [
            "Authorization": "Bearer \(c.accessToken)",
            "User-Agent": "WorkBuddy/5.5.6",
            "X-User-Id": c.uid,
            "X-Machine-ID": String(machine),
            "X-Session-ID": String(session),
            "X-Domain": c.domain
        ]
    }

    // MARK: 状态

    struct Status {
        var ok = false
        var active = true
        var signed = false
        var streak = 0
        var dailyCredit: Double = 0
        var todayCredit: Double = 0
        var message = ""
    }

    static func status(_ c: Credential) -> Status {
        var cred = c
        var response = HTTP.postJSON("\(cred.billingBase)/v2/billing/meter/checkin-activity-status",
                                     headers: headers(cred))
        if response?.status == 401, refresh(&cred) {
            response = HTTP.postJSON("\(cred.billingBase)/v2/billing/meter/checkin-activity-status",
                                     headers: headers(cred))
        }
        guard let response, response.status == 200, let json = response.json else {
            var st = Status()
            st.message = response.map { "HTTP \($0.status) \($0.message)" } ?? "网络请求失败"
            return st
        }
        let data = (json["data"] as? [String: Any]) ?? [:]
        var st = Status()
        st.ok = (json["code"] as? Int) == 0
        st.active = (data["active"] as? Bool) ?? true
        st.signed = (data["today_checked_in"] as? Bool) ?? false
        st.streak = intValue(data["streak_days"])
        st.dailyCredit = doubleValue(data["daily_credit"])
        st.todayCredit = doubleValue(data["today_credit"])
        if !st.ok { st.message = response.message }
        return st
    }

    // MARK: 签到

    static func checkin(_ c: Credential) -> (ok: Bool, already: Bool, message: String) {
        var cred = c
        var response = HTTP.postJSON("\(cred.billingBase)/v2/billing/meter/daily-checkin",
                                     headers: headers(cred))
        if response?.status == 401, refresh(&cred) {
            response = HTTP.postJSON("\(cred.billingBase)/v2/billing/meter/daily-checkin",
                                     headers: headers(cred))
        }
        guard let response else { return (false, false, "网络请求失败") }
        if response.status == 401 { return (false, false, "登录已过期，请在 CodeBuddy 客户端重新登录") }
        let code = response.code ?? -1
        let msg = response.message
        let success = (response.status == 200 || response.status == 201)
            && (code == 0 || code == 200 || code == -1)
        if success { return (true, false, msg.isEmpty ? "签到成功" : msg) }
        if code == 10001 || containsAlready(msg) {
            return (true, true, msg.isEmpty ? "今日已签" : msg)
        }
        return (false, false, msg.isEmpty ? "HTTP \(response.status)" : msg)
    }

    // MARK: 余额

    struct Balance {
        var remain: Double
        var total: Double
        var plan: String
    }

    static func balance(_ c: Credential) -> Balance? {
        var cred = c
        var response = HTTP.postJSON("\(cred.billingBase)/billing/meter/get-user-resource-summary",
                                     headers: headers(cred))
        if response?.status == 401, refresh(&cred) {
            response = HTTP.postJSON("\(cred.billingBase)/billing/meter/get-user-resource-summary",
                                     headers: headers(cred))
        }
        guard let response, response.status == 200,
              let json = response.json,
              let data = json["data"] as? [String: Any]
        else { return nil }

        var remain = doubleValue(data["TotalCredits"])
        var total = 0.0
        if let packages = data["Packages"] as? [[String: Any]], !packages.isEmpty {
            var remainSum = 0.0
            var totalSum = 0.0
            for pkg in packages {
                remainSum += doubleValue(pkg["CycleRemainCapacity"])
                totalSum += doubleValue(pkg["CycleTotalCapacity"])
            }
            if remainSum > 0 { remain = remainSum }
            total = totalSum
        }
        let plan = (data["SubscriptionPackageName"] as? String) ?? ""
        guard remain > 0 || total > 0 else { return nil }
        return Balance(remain: remain, total: total, plan: plan)
    }

    // MARK: RT 续签（仅在 401 时调用；不写回客户端文件，避免与客户端争抢轮换）

    @discardableResult
    static func refresh(_ c: inout Credential) -> Bool {
        guard !c.refreshToken.isEmpty else { return false }
        guard let response = HTTP.postJSON("https://www.codebuddy.cn/v2/plugin/auth/token/refresh",
                                           headers: ["User-Agent": "WorkBuddy/5.5.6"],
                                           body: ["refreshToken": c.refreshToken]),
              let json = response.json, (json["code"] as? Int) == 0,
              let data = json["data"] as? [String: Any],
              let token = data["accessToken"] as? String, !token.isEmpty
        else { return false }
        c.accessToken = token
        if let rt = data["refreshToken"] as? String, !rt.isEmpty { c.refreshToken = rt }
        return true
    }

    // MARK: 工具

    static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func containsAlready(_ message: String) -> Bool {
        let lower = message.lowercased()
        return ["已签到", "已经签到", "repeat", "already"].contains { lower.contains($0) }
    }

    private static func intValue(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let n = Int(s) { return n }
        return 0
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let d = Double(s) { return d }
        return 0
    }
}

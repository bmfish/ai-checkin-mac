import Foundation

// MARK: - 本地状态
//
// ~/.ai-checkin/state.json
//   done  { accountID: "YYYY-MM-DD" }  已签水位
//   fail  { accountID: epoch }         上次失败时间（1 小时内不重试）
//   log   [ {t, uid, ok, credits, msg} ]  最近 100 条
// ~/.ai-checkin/checkin.log             追加式文本日志

struct CheckinRecord {
    let t: Int64
    let uid: String
    let ok: Bool
    let credits: Double
    let msg: String

    var dict: [String: Any] {
        ["t": t, "uid": uid, "ok": ok, "credits": credits, "msg": msg]
    }

    init?(dict: [String: Any]) {
        guard let uid = dict["uid"] as? String else { return nil }
        t = Int64((dict["t"] as? NSNumber)?.int64Value ?? 0)
        self.uid = uid
        ok = (dict["ok"] as? Bool) ?? false
        credits = (dict["credits"] as? NSNumber)?.doubleValue ?? 0
        msg = dict["msg"] as? String ?? ""
    }

    init(t: Int64, uid: String, ok: Bool, credits: Double, msg: String) {
        self.t = t; self.uid = uid; self.ok = ok; self.credits = credits; self.msg = msg
    }
}

final class CheckinStore {

    static let shared = CheckinStore()

    let dir: URL
    private let statePath: URL
    private let logPath: URL
    private let queue = DispatchQueue(label: "ai-checkin.store")
    private var state: [String: Any] = [:]

    init(directory: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["AI_CHECKIN_HOME"]
        if let directory {
            dir = directory
        } else if let override, !override.isEmpty {
            dir = URL(fileURLWithPath: override)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ai-checkin")
        }
        statePath = dir.appendingPathComponent("state.json")
        logPath = dir.appendingPathComponent("checkin.log")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: statePath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            state = obj
        } else {
            state = [:]
        }
        state["done"] = state["done"] as? [String: Any] ?? [:]
        state["fail"] = state["fail"] as? [String: Any] ?? [:]
        state["log"] = state["log"] as? [Any] ?? []
    }

    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: state,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: statePath, options: .atomic)
    }

    // MARK: 水位

    func doneToday(_ uid: String, _ day: String) -> Bool {
        queue.sync { ((state["done"] as? [String: Any])?[uid] as? String) == day }
    }

    func markDone(_ uid: String, _ day: String) {
        queue.sync {
            var done = state["done"] as? [String: Any] ?? [:]
            done[uid] = day
            state["done"] = done
            var fail = state["fail"] as? [String: Any] ?? [:]
            fail.removeValue(forKey: uid)
            state["fail"] = fail
            save()
        }
    }

    func failAt(_ uid: String) -> Int64 {
        queue.sync {
            Int64(((state["fail"] as? [String: Any])?[uid] as? NSNumber)?.int64Value ?? 0)
        }
    }

    func markFail(_ uid: String, _ epoch: Int64) {
        queue.sync {
            var fail = state["fail"] as? [String: Any] ?? [:]
            fail[uid] = epoch
            state["fail"] = fail
            save()
        }
    }

    // MARK: 记录

    func appendLog(_ uid: String, ok: Bool, credits: Double, msg: String, epoch: Int64) {
        let record = CheckinRecord(t: epoch, uid: uid, ok: ok, credits: credits, msg: msg)
        queue.sync {
            var log = state["log"] as? [Any] ?? []
            log.append(record.dict)
            if log.count > 100 { log.removeFirst(log.count - 100) }
            state["log"] = log
            save()
            writeText(record)
        }
    }

    /// 今日成功记录只写一笔
    func recordOnce(_ uid: String, _ day: String, credits: Double, msg: String, epoch: Int64) {
        if !loggedToday(uid, day) {
            appendLog(uid, ok: true, credits: credits, msg: msg, epoch: epoch)
        }
    }

    func loggedToday(_ uid: String, _ day: String) -> Bool {
        queue.sync {
            let log = state["log"] as? [Any] ?? []
            return log.contains { item in
                guard let dict = item as? [String: Any], let rec = CheckinRecord(dict: dict) else { return false }
                return rec.ok && rec.uid == uid && Self.dayOf(rec.t) == day
            }
        }
    }

    func todayCredits(_ day: String) -> Double {
        queue.sync {
            let log = state["log"] as? [Any] ?? []
            return log.reduce(0.0) { sum, item in
                guard let dict = item as? [String: Any], let rec = CheckinRecord(dict: dict) else { return sum }
                return rec.ok && Self.dayOf(rec.t) == day ? sum + rec.credits : sum
            }
        }
    }

    func recent(_ limit: Int = 5) -> [CheckinRecord] {
        queue.sync {
            let log = (state["log"] as? [Any] ?? []).compactMap {
                ($0 as? [String: Any]).flatMap(CheckinRecord.init(dict:))
            }
            return Array(log.suffix(limit).reversed())
        }
    }

    private func writeText(_ record: CheckinRecord) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(record.t)))
        let amount = record.credits > 0 ? String(format: "+%g", record.credits) : "-"
        let line = "\(stamp)\tuid=\(record.uid)\t\(record.ok ? "OK" : "FAIL")\t\(amount)\t\(record.msg)\n"
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logPath)
        }
    }

    static func dayOf(_ epoch: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}

// MARK: - 一轮签到

enum CheckinRunner {

    enum Action: String {
        case done, already, skipped, failed
    }

    struct Result {
        let uid: String
        let action: Action
        let message: String
        let credits: Double
    }

    static let failCooldown: TimeInterval = 3600

    /// 执行一轮签到。force=true 忽略随机分钟门与失败冷却（手动签到）。
    @discardableResult
    static func runOnce(force: Bool, startHour: Int, now: Date = Date(),
                        store: CheckinStore = .shared) -> [Result] {
        let accounts = AccountDiscovery.discover()
        guard !accounts.isEmpty else { return [] }
        let epoch = Int64(now.timeIntervalSince1970)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let dayStart = Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        var results: [Result] = []
        for account in accounts {
            results.append(checkin(account, store: store, epoch: epoch, dayStart: dayStart,
                                   today: today, force: force, startHour: startHour))
        }
        return results
    }

    private static func checkin(_ account: PlatformAccount, store: CheckinStore,
                                epoch: Int64, dayStart: Int64, today: String,
                                force: Bool, startHour: Int) -> Result {
        // 1) 本地水位：今日已签彻底跳过，连 status 都不请求
        if store.doneToday(account.id, today) {
            return Result(uid: account.id, action: .skipped, message: "今日已签", credits: 0)
        }
        // 2) 随机分钟门：起始小时 + 账号当天派生分钟
        let slot = dayStart + Int64(startHour * 3600)
            + Int64(slotMinute(uid: account.id, day: today) * 60)
        if !force && epoch < slot {
            let text = DateFormatter.localizedString(from: Date(timeIntervalSince1970: TimeInterval(slot)),
                                                     dateStyle: .none, timeStyle: .short)
            return Result(uid: account.id, action: .skipped, message: "未到签到时间 \(text)", credits: 0)
        }
        // 3) 失败冷却
        if !force && epoch - store.failAt(account.id) < Int64(failCooldown) {
            return Result(uid: account.id, action: .skipped, message: "失败冷却中", credits: 0)
        }

        switch account.platform {
        case .trae:
            return checkinTrae(account, store: store, epoch: epoch, today: today)
        case .workBuddy:
            return checkinWorkBuddy(account, store: store, epoch: epoch, today: today)
        case .qoder:
            return checkinQoder(account, store: store, epoch: epoch, today: today)
        }
    }

    private static func checkinTrae(_ account: PlatformAccount, store: CheckinStore,
                                    epoch: Int64, today: String) -> Result {
        guard let cred = TraeClientCredentials.discover().first(where: { $0.uid == account.uid }) else {
            return Result(uid: account.id, action: .skipped, message: "凭据已失效", credits: 0)
        }
        guard let jwt = TraeSupport.jwt(for: cred) else {
            store.appendLog(account.id, ok: false, credits: 0,
                            msg: "JWT 已过期，请打开 Trae 客户端", epoch: epoch)
            store.markFail(account.id, epoch)
            return Result(uid: account.id, action: .failed,
                          message: "JWT 已过期，请打开 Trae 客户端", credits: 0)
        }
        let status = TraeCheckin.status(jwt: jwt, uid: cred.uid, deviceID: cred.deviceID)
        let reward = status.credits + status.extraCredits
        if status.checkedIn {
            store.markDone(account.id, today)
            store.recordOnce(account.id, today, credits: reward, msg: "今日已签", epoch: epoch)
            return Result(uid: account.id, action: .already, message: "今日已签", credits: reward)
        }
        if !status.enable {
            return Result(uid: account.id, action: .skipped,
                          message: status.message.isEmpty ? "签到未开启" : status.message, credits: 0)
        }
        let claim = TraeCheckin.claim(jwt: jwt, uid: cred.uid, deviceID: cred.deviceID)
        if claim.ok {
            store.markDone(account.id, today)
            store.recordOnce(account.id, today, credits: reward,
                             msg: claim.already ? "今日已签" : "签到成功", epoch: epoch)
            return Result(uid: account.id, action: claim.already ? .already : .done,
                          message: claim.already ? "今日已签" : "签到成功", credits: reward)
        }
        store.appendLog(account.id, ok: false, credits: 0, msg: claim.message, epoch: epoch)
        store.markFail(account.id, epoch)
        return Result(uid: account.id, action: .failed,
                      message: claim.message.isEmpty ? "签到失败" : claim.message, credits: 0)
    }

    private static func checkinWorkBuddy(_ account: PlatformAccount, store: CheckinStore,
                                         epoch: Int64, today: String) -> Result {
        guard let cred = WorkBuddyClient.discover().first(where: { $0.uid == account.uid }) else {
            return Result(uid: account.id, action: .skipped, message: "凭据已失效", credits: 0)
        }
        let status = WorkBuddyClient.status(cred)
        if !status.ok {
            store.appendLog(account.id, ok: false, credits: 0, msg: status.message, epoch: epoch)
            store.markFail(account.id, epoch)
            return Result(uid: account.id, action: .failed,
                          message: status.message.isEmpty ? "状态查询失败" : status.message, credits: 0)
        }
        if !status.active {
            return Result(uid: account.id, action: .skipped, message: "活动未开启", credits: 0)
        }
        if status.signed {
            let reward = status.todayCredit > 0 ? status.todayCredit : status.dailyCredit
            store.markDone(account.id, today)
            store.recordOnce(account.id, today, credits: reward, msg: "今日已签", epoch: epoch)
            return Result(uid: account.id, action: .already, message: "今日已签", credits: reward)
        }
        let result = WorkBuddyClient.checkin(cred)
        if result.ok {
            let reward = status.dailyCredit
            store.markDone(account.id, today)
            store.recordOnce(account.id, today, credits: reward, msg: result.message, epoch: epoch)
            return Result(uid: account.id, action: result.already ? .already : .done,
                          message: result.message, credits: reward)
        }
        store.appendLog(account.id, ok: false, credits: 0, msg: result.message, epoch: epoch)
        store.markFail(account.id, epoch)
        return Result(uid: account.id, action: .failed,
                      message: result.message.isEmpty ? "签到失败" : result.message, credits: 0)
    }

    private static func checkinQoder(_ account: PlatformAccount, store: CheckinStore,
                                     epoch: Int64, today: String) -> Result {
        guard let auth = QoderClient.loadAuth() else {
            store.appendLog(account.id, ok: false, credits: 0, msg: "无法读取 Qoder 凭据", epoch: epoch)
            store.markFail(account.id, epoch)
            return Result(uid: account.id, action: .failed, message: "无法读取 Qoder 凭据", credits: 0)
        }
        let (campaigns, unauthorized) = QoderClient.campaigns(auth)
        if unauthorized {
            store.appendLog(account.id, ok: false, credits: 0, msg: "Qoder 登录已过期", epoch: epoch)
            store.markFail(account.id, epoch)
            return Result(uid: account.id, action: .failed, message: "Qoder 登录已过期", credits: 0)
        }
        let claimable = campaigns.filter(\.claimable)
        guard !claimable.isEmpty else {
            store.markDone(account.id, today)
            return Result(uid: account.id, action: .already, message: "暂无可领活动", credits: 0)
        }
        var claimed = 0.0
        var lastMessage = ""
        for campaign in claimable {
            let result = QoderClient.claim(auth, id: campaign.id)
            lastMessage = result.message
            if result.ok { claimed += 1 }
            Thread.sleep(forTimeInterval: 1.5)
        }
        if claimed > 0 {
            store.markDone(account.id, today)
            store.recordOnce(account.id, today, credits: claimed,
                             msg: "领取 \(Int(claimed)) 个活动", epoch: epoch)
            return Result(uid: account.id, action: .done,
                          message: "领取 \(Int(claimed)) 个活动", credits: claimed)
        }
        store.appendLog(account.id, ok: false, credits: 0, msg: lastMessage, epoch: epoch)
        store.markFail(account.id, epoch)
        return Result(uid: account.id, action: .failed,
                      message: lastMessage.isEmpty ? "领取失败" : lastMessage, credits: 0)
    }

    /// 账号当天派生 0–59 分钟，避免整点齐发
    static func slotMinute(uid: String, day: String) -> Int {
        let digest = WorkBuddyClient.sha256("\(uid)|\(day)")
        let prefix = digest.prefix(4)
        let value = Int(prefix, radix: 16) ?? 0
        return value % 60
    }
}

// MARK: - 账号发现（两个平台并成一张表）

enum AccountDiscovery {

    static func discover() -> [PlatformAccount] {
        var accounts: [PlatformAccount] = []

        for cred in TraeClientCredentials.discover() {
            accounts.append(PlatformAccount(
                id: "\(PlatformKind.trae.prefix):\(cred.uid)",
                platform: .trae,
                uid: cred.uid,
                displayName: cred.uid,
                source: cred.sourceApp
            ))
        }

        for cred in WorkBuddyClient.discover() {
            accounts.append(PlatformAccount(
                id: "\(PlatformKind.workBuddy.prefix):\(cred.uid)",
                platform: .workBuddy,
                uid: cred.uid,
                displayName: cred.nickname,
                source: "CodeBuddy CN"
            ))
        }

        if let auth = QoderClient.loadAuth() {
            let uid = auth.uid.isEmpty ? (auth.email.isEmpty ? "account" : auth.email) : auth.uid
            let name = !auth.name.isEmpty ? auth.name : (!auth.email.isEmpty ? auth.email : uid)
            accounts.append(PlatformAccount(
                id: "\(PlatformKind.qoder.prefix):\(uid)",
                platform: .qoder,
                uid: uid,
                displayName: name,
                source: "Qoder"
            ))
        }

        return accounts
    }
}

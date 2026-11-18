import Foundation

// MARK: - 终端自检（--selftest）

enum SelfTest {

    static func run() {
        print("=== AI 签到 自检 ===")
        let accounts = AccountDiscovery.discover()
        print("发现账号 \(accounts.count) 个")
        for account in accounts {
            print("- \(account.platform.label)  \(account.displayName)  [\(account.id)]  \(account.source)")
        }

        if TraeClientCredentials.discover().isEmpty {
            print("\n[Trae] 未发现凭据")
        } else {
            for item in TraeUsage.today() {
                print("\n[Trae] uid=\(item.uid) app=\(item.app) sessions=\(item.sessions) "
                    + "credits=\(item.credits) balance=\(item.balance.map { "\($0)" } ?? "-") "
                    + "total=\(item.total.map { "\($0)" } ?? "-") msg=\(item.message)")
            }
        }

        if let cred = WorkBuddyClient.discover().first {
            let status = WorkBuddyClient.status(cred)
            print("\n[WorkBuddy] ok=\(status.ok) signed=\(status.signed) streak=\(status.streak) "
                + "today=\(status.todayCredit) daily=\(status.dailyCredit) msg=\(status.message)")
            if let balance = WorkBuddyClient.balance(cred) {
                print("[WorkBuddy] balance=\(balance.remain)/\(balance.total) plan=\(balance.plan)")
            } else {
                print("[WorkBuddy] balance 读取失败")
            }
        } else {
            print("\n[WorkBuddy] 未发现凭据")
        }

        if let auth = QoderClient.loadAuth() {
            let (items, unauthorized) = QoderClient.campaigns(auth)
            print("\n[Qoder] unauthorized=\(unauthorized) campaigns=\(items.count) "
                + "claimable=\(items.filter(\.claimable).count)")
            for item in items {
                print("  - \(item.title)  \(item.id)  \(item.status)")
            }
        } else {
            print("\n[Qoder] 凭据解密失败（钥匙串未授权或文件缺失）")
        }
    }
}

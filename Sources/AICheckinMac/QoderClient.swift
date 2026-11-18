import CommonCrypto
import Foundation

// MARK: - Qoder 活动领取（无传统签到，靠活动 campaign）
//
// 凭证：~/Library/Application Support/com.qoder.app.stable/auth.v1.dat
//   Electron safeStorage 格式：3 字节 "v10" + AES-128-CBC(PKCS7)
//   密钥 = PBKDF2-SHA1(钥匙串 "Qoder App Safe Storage" 密码, "saltysalt", 1003 轮, 16 字节)
//   IV   = 16 个 0x20
// 接口（本机客户端走 .sh 域）：
//   GET  https://openapi.qoder.sh/sash/api/v1/me/campaigns
//   POST https://openapi.qoder.sh/sash/api/v1/me/campaigns/{id}/claim

enum QoderClient {

    struct Auth {
        var token: String
        var refreshToken: String
        var uid: String
        var name: String
        var email: String
    }

    struct Campaign {
        let id: String
        let title: String
        let status: String

        var claimable: Bool { status.uppercased() == "CLAIMABLE" }
    }

    static let base = "https://openapi.qoder.sh"
    private static let keychainService = "Qoder App Safe Storage"

    static var authPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.qoder.app.stable/auth.v1.dat")
            .path
    }

    // MARK: 读取并解密凭证

    static func loadAuth() -> Auth? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              raw.count > 3,
              String(data: raw.prefix(3), encoding: .utf8) == "v10",
              let plain = decrypt(raw.suffix(from: 3)),
              let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty
        else { return nil }

        var user: [String: Any] = [:]
        if let u = json["user"] as? [String: Any] { user = u }
        return Auth(
            token: token,
            refreshToken: (json["refreshToken"] as? String) ?? "",
            uid: (user["id"] as? String) ?? "",
            name: (user["name"] as? String) ?? "",
            email: (user["email"] as? String) ?? ""
        )
    }

    private static func keychainPassword() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var data = pipe.fileHandleForReading.readDataToEndOfFile()
        while let last = data.last, last == 0x0A || last == 0x0D {
            data.removeLast()
        }
        return data.isEmpty ? nil : data
    }

    private static func decrypt(_ payload: Data) -> Data? {
        guard let password = keychainPassword() else { return nil }

        let salt = Data("saltysalt".utf8)
        var key = Data(count: 16)
        let derived = key.withUnsafeMutableBytes { keyBytes -> Int32 in
            password.withUnsafeBytes { pwBytes -> Int32 in
                salt.withUnsafeBytes { saltBytes -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress, 16)
                }
            }
        }
        guard derived == kCCSuccess else { return nil }

        let iv = Data(repeating: 0x20, count: 16)
        let capacity = payload.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES128),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, 16,
                                ivBytes.baseAddress,
                                inBytes.baseAddress, payload.count,
                                outBytes.baseAddress, capacity,
                                &outputLength)
                    }
                }
            }
        }
        guard status == kCCSuccess, outputLength > 0 else { return nil }
        return output.prefix(outputLength)
    }

    // MARK: 请求头

    static func headers(_ auth: Auth) -> [String: String] {
        [
            "Authorization": "Bearer \(auth.token)",
            "Cosy-ClientType": "10",
            "User-Agent": "Qoder",
            "Content-Type": "application/json"
        ]
    }

    // MARK: 活动列表

    static func campaigns(_ auth: Auth) -> (items: [Campaign], unauthorized: Bool) {
        guard let response = HTTP.getJSON("\(base)/sash/api/v1/me/campaigns", headers: headers(auth))
        else { return ([], false) }
        if response.status == 401 { return ([], true) }
        guard response.status == 200, let json = response.json else { return ([], false) }
        var found: [Campaign] = []
        collect(json, &found)
        // campaignId 可能在多层结构里重复出现，按 id 去重
        var seen = Set<String>()
        found = found.filter { seen.insert($0.id).inserted }
        return (found, false)
    }

    private static func collect(_ node: Any, _ out: inout [Campaign]) {
        if let array = node as? [Any] {
            for item in array { collect(item, &out) }
            return
        }
        guard let dict = node as? [String: Any] else { return }

        // 真实结构：campaignId = UUID，campaignKey = "act-YYYYMMDD-xxx"，
        // claimStatus = CLAIMABLE / CLAIMED / ...
        let id = string(dict["campaignId"]) ?? string(dict["campaign_id"])
        let status = string(dict["claimStatus"]) ?? string(dict["claim_status"])
        let title = string(dict["campaignKey"]) ?? string(dict["campaign_key"])
            ?? string(dict["campaignName"]) ?? string(dict["title"]) ?? ""

        if let id, let status {
            out.append(Campaign(id: id, title: title, status: status))
            return
        }
        for (_, value) in dict { collect(value, &out) }
    }

    // MARK: 领取

    static func claim(_ auth: Auth, id: String) -> (ok: Bool, already: Bool, message: String) {
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            return (false, false, "活动 id 非法")
        }
        guard let response = HTTP.postJSON("\(base)/sash/api/v1/me/campaigns/\(id)/claim",
                                           headers: headers(auth)),
              let json = response.json
        else { return (false, false, "网络请求失败") }

        if response.status == 401 { return (false, false, "登录已过期，请重新登录 Qoder") }
        if response.status == 409 { return (false, false, "活动已失效") }

        let code = response.code ?? -1
        if code == 0 || response.status == 200 {
            let replayed = (json["replayed"] as? Bool)
                ?? ((json["data"] as? [String: Any])?["replayed"] as? Bool)
                ?? false
            return (true, replayed, replayed ? "已领取" : "领取成功")
        }
        return (false, false, response.message.isEmpty ? "HTTP \(response.status)" : response.message)
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        return nil
    }
}

import Foundation

// MARK: - 同步 HTTP 封装（全部在后台队列调用）

struct HTTPResponse {
    let status: Int
    let data: Data

    var text: String { String(data: data, encoding: .utf8) ?? "" }

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 宽松取业务码：兼容 code / statusCode / ret
    var code: Int? {
        guard let json else { return nil }
        for key in ["code", "statusCode", "ret"] {
            if let n = json[key] as? NSNumber { return n.intValue }
            if let s = json[key] as? String, let n = Int(s) { return n }
        }
        return nil
    }

    var message: String {
        guard let json else { return "" }
        for key in ["msg", "message", "error", "errMsg", "statusMessage"] {
            if let s = json[key] as? String, !s.isEmpty { return s }
        }
        if let data = json["data"] as? [String: Any],
           let s = data["message"] as? String, !s.isEmpty { return s }
        return ""
    }
}

enum HTTP {

    static func request(_ method: String,
                        _ url: String,
                        headers: [String: String] = [:],
                        body: Data? = nil,
                        timeout: TimeInterval = 20) -> HTTPResponse? {
        guard let target = URL(string: url) else { return nil }
        var req = URLRequest(url: target)
        req.httpMethod = method
        req.timeoutInterval = timeout
        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            req.httpBody = body
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: HTTPResponse?
        let task = URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = HTTPResponse(status: http.statusCode, data: data ?? Data())
            } else if let data {
                result = HTTPResponse(status: 0, data: data)
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 5)
        return result
    }

    static func postJSON(_ url: String,
                         headers: [String: String],
                         body: [String: Any] = [:],
                         timeout: TimeInterval = 20) -> HTTPResponse? {
        var h = headers
        h["Content-Type"] = "application/json"
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return request("POST", url, headers: h, body: data, timeout: timeout)
    }

    static func getJSON(_ url: String,
                        headers: [String: String],
                        timeout: TimeInterval = 20) -> HTTPResponse? {
        request("GET", url, headers: headers, timeout: timeout)
    }

    /// 原文 body 的 POST（Trae 接口需要精确控制序列化结果）
    static func postText(_ url: String,
                         headers: [String: String],
                         body: String,
                         timeout: TimeInterval = 20) -> (status: Int, data: Data?) {
        let response = request("POST", url, headers: headers,
                               body: Data(body.utf8), timeout: timeout)
        return (response?.status ?? 0, response?.data)
    }
}

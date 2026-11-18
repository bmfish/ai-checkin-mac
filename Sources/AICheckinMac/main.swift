import Cocoa
import Foundation

// MARK: - 入口
//
// --selftest  终端自检：打印账号发现与接口结果，不进事件循环

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

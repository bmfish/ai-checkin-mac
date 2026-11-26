import Cocoa
import Combine
import SwiftUI

// MARK: - 菜单栏 + 主窗口
//
// 左键点图标：打开/收起「AI 签到」窗口
// 右键点图标：快捷菜单（打开窗口 / 立即签到 / 刷新 / 退出）
// 后台：60 秒一轮自动签到，命中「起始小时 + 账号当天派生分钟」才发请求

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model = UsageModel()
    private let workQueue = DispatchQueue(label: "ai-checkin.scheduler", qos: .utility)

    private var window: NSWindow?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var contextMenu: NSMenu?
    private var resignActiveObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 恢复上次选择的外观（默认跟随系统）
        if let saved = UserDefaults.standard.string(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: saved) {
            mode.apply()
        }
        setupStatusItem()
        setupWindow()
        observeModel()
        startScheduler()
        model.refresh()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showWindow() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
    }

    // MARK: 状态栏

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "checkmark.seal",
                               accessibilityDescription: "AI 签到")
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(onStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "AI 签到 · Trae / WorkBuddy / Qoder"
    }

    @objc private func onStatusItemClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggleWindow()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem("打开窗口", #selector(openWindow)))
        menu.addItem(menuItem("立即签到", #selector(checkinNow)))
        menu.addItem(menuItem("刷新", #selector(refreshNow)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出", #selector(quit)))
        contextMenu = menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: 窗口

    private func setupWindow() {
        let hosting = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: model.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "AI 签到"
        // 跟随系统浅色 / 深色外观；标题栏透出窗口底色
        window.backgroundColor = Palette.titlebar
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        self.window = window
        // 点窗口以外的空白处（切到其他 App / 桌面）时自动收起
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.window?.orderOut(nil)
        }
    }

    private func observeModel() {
        model.$windowHeight
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] height in
                guard let self, let window = self.window else { return }
                var frame = window.frame
                let top = frame.origin.y + frame.height
                frame.size.height = height
                frame.origin.y = top - height
                window.setFrame(frame, display: true, animate: false)
            }
            .store(in: &cancellables)
    }

    @objc private func openWindow() { showWindow() }

    private func toggleWindow() {
        guard let window else { return }
        // 只看可见性：失焦的窗口也算「已打开」，再点一次就收起
        if window.isVisible {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    private func showWindow() {
        guard let window else { return }
        positionAtTop()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 顶到菜单栏下沿，水平居中
    private func positionAtTop() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.origin.y = visible.maxY - frame.height
        frame.origin.x = visible.midX - frame.width / 2
        window.setFrame(frame, display: false)
    }

    // MARK: 动作

    @objc private func checkinNow() { model.checkin() }

    @objc private func refreshNow() { model.refresh() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 定时签到

    private func startScheduler() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.scheduledTick()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.scheduledTick()
        }
    }

    private func scheduledTick() {
        // 跨天：日期文字与卡片数据都属于前一天，立即失效重读（不算定时刷新）
        let today = UsageModel.dateText()
        if today != model.todayText {
            model.todayText = today
            model.refresh()
        }
        let hour = model.startHour
        workQueue.async { [weak self] in
            guard let self else { return }
            let results = CheckinRunner.runOnce(force: false, startHour: hour)
            // 只有签到真的产生新结果才回读界面，其余时间不动用量数据（手动点刷新才更新）
            guard results.contains(where: { $0.action == .done || $0.action == .already }) else { return }
            DispatchQueue.main.async { self.model.refresh() }
        }
    }
}

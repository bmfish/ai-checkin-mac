import AppKit
import SwiftUI

// MARK: - 主窗口（深绿描边卡片 + 平台徽章 + 大号数值）

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - 主题色
//
// 浅色为默认主体，系统切到深色时自动换深色一套（设计稿 design/ai-checkin-light-skin.html）。
enum Palette {
    /// 同一 token 的浅 / 深两套取值，由系统外观决定实际解析结果
    private static func ns(_ light: UInt32, _ dark: UInt32,
                           lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    private static func color(_ light: UInt32, _ dark: UInt32,
                              lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: ns(light, dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    /// 标题栏底色（AppDelegate 设置窗口背景用）
    static let titlebar = ns(0xEBF0ED, 0x171B19)

    static let bg = color(0xF4F7F5, 0x0A0E0B)
    static let cardTop = color(0xFFFFFF, 0x0F1B14)
    static let cardBottom = color(0xF9FCFA, 0x0A120D)
    static let cardStroke = color(0xDEE9E2, 0x1C4A33)
    static let track = color(0xE7EEE9, 0x1A211C)
    static let fg = color(0x122019, 0xE8F2EC)
    static let muted = color(0x5E6E65, 0x7C8A80)
    static let dim = color(0x8A9890, 0x5C6A60)
    static let accent = color(0x0B9152, 0x3DF08C)
    static let accentBar = color(0x2CC777, 0x3DF08C)
    static let topline = color(0x0B9152, 0x3DF08C, lightAlpha: 0.45, darkAlpha: 0.55)
    static let badgeBg = color(0xE6F8EF, 0x3DF08C, darkAlpha: 0.12)
    static let badgeLine = color(0x9FDFC0, 0x3DF08C, darkAlpha: 0.55)
    static let badgeFg = color(0x0A7C46, 0x3DF08C)
    static let danger = color(0xC0392B, 0xFF7B72)
    static let field = color(0xF2F6F4, 0x0E1511)
    static let buttonBg = color(0xFFFFFF, 0x14181A)
    static let buttonStroke = color(0xDCE4DF, 0x2A3136)
    static let divider = color(0xE6EDE9, 0x1B221D)
    /// 浅色卡片投影；深色不用阴影，靠描边分层
    static let cardShadow = color(0x122E1F, 0x000000, lightAlpha: 0.08, darkAlpha: 0)
}

/// 应用外观：跟随系统（默认）/ 浅色 / 深色
enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct ContentView: View {

    @ObservedObject var model: UsageModel
    @State private var hourText: String = ""
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.topline).frame(height: 1)
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if model.loaded && model.accounts.isEmpty {
                        emptyState
                    }
                    ForEach(model.accounts) { account in
                        card(account)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            infoRows
            footer
        }
        .background(Palette.bg)
        .frame(width: 460)
        .onAppear {
            hourText = String(format: "%02d", model.startHour)
            applyAppearance()
        }
        .onChange(of: model.startHour) { hour in
            hourText = String(format: "%02d", hour)
        }
        .onChange(of: appearanceMode) { _ in
            applyAppearance()
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("AI 签到")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Palette.fg)
            Text("Trae · WorkBuddy · Qoder")
                .font(.system(size: 10.5))
                .foregroundColor(Palette.muted)
            Spacer()
            appearanceToggle
            Text(UsageModel.dateText())
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Palette.dim)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// 外观切换按钮：浅色时显示月亮（点后切深色），深色时显示太阳（点后切浅色）
    private var appearanceToggle: some View {
        let isDark = colorScheme == .dark
        return Button(action: toggleAppearance) {
            Text(Image(systemName: isDark ? "sun.max" : "moon"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isDark ? Palette.accent : Palette.muted)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isDark ? Palette.buttonBg : Palette.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Palette.buttonStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(isDark ? "切换为浅色" : "切换为深色")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("未发现本机客户端凭据")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.fg.opacity(0.75))
            Text("请先登录 CodeBuddy / Qoder 客户端")
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Palette.cardTop, Palette.cardBottom],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.cardStroke, lineWidth: 1))
        .shadow(color: Palette.cardShadow, radius: 14, x: 0, y: 8)
    }

    // MARK: 账号卡片

    private func card(_ account: PlatformAccount) -> some View {
        let row = model.usage.first(where: { $0.id == account.id })
        let signed = row?.signed ?? false
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Palette.fg)
                        .lineLimit(1)
                    if account.platform == .trae, account.displayName != account.uid {
                        Text(account.uid)
                            .font(.system(size: 10))
                            .foregroundColor(Palette.dim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(account.platform.label)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
                badge(signed: signed)
            }

            if let row, row.ok {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(primaryValue(row, account))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(primaryColor(row))
                    Text(primaryUnit(account))
                        .font(.system(size: 11))
                        .foregroundColor(Palette.muted)
                    Rectangle().fill(Palette.cardStroke).frame(width: 1, height: 20)
                        .padding(.horizontal, 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
                    Text(secondaryText(row, account))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.fg.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.top, 5)

                if let balance = row.balance {
                    balanceRow(balance: balance, total: row.total)
                } else if !row.detail.isEmpty && account.platform != .qoder {
                    Text(row.detail)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.muted)
                        .padding(.top, 7)
                }
            } else if let row, !row.message.isEmpty {
                Text(row.message)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.danger)
                    .padding(.top, 8)
            } else {
                Text("正在读取…")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.dim)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Palette.cardTop, Palette.cardBottom],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.cardStroke, lineWidth: 1))
        .shadow(color: Palette.cardShadow, radius: 14, x: 0, y: 8)
    }

    private func primaryValue(_ row: PlatformUsage, _ account: PlatformAccount) -> String {
        switch account.platform {
        case .trae, .workBuddy:
            return UsageModel.money(row.todayCredits ?? 0)
        case .qoder:
            return "\(Int(row.todayCredits ?? 0))"
        }
    }

    private func primaryUnit(_ account: PlatformAccount) -> String {
        switch account.platform {
        case .trae: return "今日消耗"
        case .workBuddy: return "今日积分"
        case .qoder: return "个可领活动"
        }
    }

    private func primaryColor(_ row: PlatformUsage) -> Color {
        (row.todayCredits ?? 0) > 0 ? Palette.accent : Palette.fg.opacity(0.5)
    }

    private func secondaryText(_ row: PlatformUsage, _ account: PlatformAccount) -> String {
        switch account.platform {
        case .trae:
            return "会话 \(row.sessions ?? 0)"
        case .workBuddy:
            return "连签 \(row.streak ?? 0) 天"
        case .qoder:
            return row.detail.isEmpty ? "暂无新活动" : row.detail
        }
    }

    private func balanceRow(balance: Double, total: Double?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("余额")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
                Text(UsageModel.money(balance))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Palette.fg)
                if let total {
                    Text("/").font(.system(size: 11)).foregroundColor(Palette.dim)
                    Text("总额")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.muted)
                    Text(UsageModel.money(total))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Palette.fg)
                }
            }
            .padding(.top, 7)

            if let total, total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.track)
                        Capsule()
                            .fill(Palette.accentBar)
                            .frame(width: max(0, min(1, balance / total)) * geo.size.width)
                    }
                }
                .frame(height: 5)
                .padding(.top, 8)
            }
        }
    }

    private func badge(signed: Bool) -> some View {
        Text(signed ? "已签" : "待签")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(signed ? Palette.badgeFg : Palette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(signed ? Palette.badgeBg : Palette.field)
            )
            .overlay(
                Capsule().stroke(signed ? Palette.badgeLine : Palette.buttonStroke,
                                 lineWidth: 1)
            )
    }

    // MARK: 信息行

    private var infoRows: some View {
        VStack(spacing: 0) {
            infoRow("签到") {
                HStack(spacing: 6) {
                    Text(signedRatio)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(Palette.fg)
                    if let summary = signBadge {
                        Text(summary)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(model.allSigned ? Palette.badgeFg : Palette.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(model.allSigned ? Palette.badgeBg : Palette.field))
                            .overlay(Capsule().stroke(model.allSigned ? Palette.badgeLine : Palette.buttonStroke,
                                                      lineWidth: 1))
                    }
                    if !model.note.isEmpty {
                        Text(model.note)
                            .font(.system(size: 11))
                            .foregroundColor(Palette.muted)
                            .lineLimit(1)
                    }
                }
            }
            infoRow("签到时间") {
                HStack(spacing: 8) {
                    hourControl
                    Text(String(format: "点后  %02d:00–%02d:59 随机一分钟",
                                model.startHour, model.startHour))
                        .font(.system(size: 11))
                        .foregroundColor(Palette.muted)
                }
            }
            infoRow("开机自启") {
                HStack(spacing: 6) {
                    Button(model.autostart ? "已开启" : "未开启") {
                        model.toggleAutostart()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(model.autostart ? Palette.accent : Palette.fg)

                    if !model.tip.isEmpty {
                        Text("·").font(.system(size: 11)).foregroundColor(Palette.dim)
                        Text(model.tip)
                            .font(.system(size: 11))
                            .foregroundColor(Palette.dim)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func infoRow<Content: View>(_ label: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
                .frame(width: 56, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(height: 34)
    }

    // MARK: 签到时间控件

    private var hourControl: some View {
        HStack(spacing: 0) {
            TextField("", text: $hourText)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.accent)
                .multilineTextAlignment(.center)
                .frame(width: 34, height: 24)
                .onSubmit(commitHour)
            Rectangle().fill(Palette.cardStroke).frame(width: 1, height: 24)
            VStack(spacing: 0) {
                stepButton("chevron.up") { model.setStartHour(model.startHour + 1) }
                stepButton("chevron.down") { model.setStartHour(model.startHour - 1) }
            }
            .frame(width: 18)
        }
        .background(Palette.field)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.cardStroke, lineWidth: 1))
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 6.5, weight: .bold))
                .foregroundColor(Palette.muted)
                .frame(width: 18, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 底栏

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.divider).frame(height: 1)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    model.refresh()
                } label: {
                    Text("刷新")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(model.busy ? Palette.dim : Palette.fg)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.buttonBg))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Palette.buttonStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.busy)

                Button {
                    model.checkin()
                } label: {
                    Text(signTitle())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Palette.badgeFg.opacity(model.allSigned ? 0.62 : 1))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Palette.badgeBg.opacity(model.allSigned ? 0.6 : 1))
                        )
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Palette.badgeLine.opacity(model.allSigned ? 0.6 : 1),
                                    lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.signing || model.allSigned)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: 文案

    private var signedRatio: String {
        let total = model.accounts.count
        return total == 0 ? "0/0" : "\(model.signedCount)/\(total)"
    }

    private var signBadge: String? {
        guard !model.accounts.isEmpty else { return nil }
        return model.allSigned ? "已签" : "待签"
    }

    private func signTitle() -> String {
        if model.signing { return "签到中…" }
        if !model.loaded { return "立即签到" }
        if model.accounts.isEmpty { return "无账号" }
        if model.allSigned { return "今日已签 ✓" }
        return "立即签到"
    }

    private func commitHour() {
        if let value = Int(hourText) {
            model.setStartHour(min(23, max(0, value)))
        } else {
            hourText = String(format: "%02d", model.startHour)
        }
    }

    private func applyAppearance() {
        AppearanceMode(rawValue: appearanceMode)?.apply()
    }

    /// 在浅色 / 深色之间切换，并记住选择
    private func toggleAppearance() {
        appearanceMode = (colorScheme == .dark ? AppearanceMode.light : .dark).rawValue
    }
}

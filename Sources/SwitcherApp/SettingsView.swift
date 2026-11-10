import SwiftUI
import SwitcherCore

/// The Settings window's tabs, in toolbar order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, accounts, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L.t("General", "通用")
        case .accounts: L.t("Accounts", "账号")
        case .about: L.t("About", "关于")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.2"
        case .about: "info.circle"
        }
    }
}

/// The Settings window: the system's toolbar tabs over one page each.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            ForEach(SettingsTab.allCases) { tab in
                SettingsPage(model: model, tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
            }
        }
    }
}

/// One tab's page. The window takes the page's height, up to a limit; past it the page scrolls.
struct SettingsPage: View {
    let model: AppModel
    let tab: SettingsTab
    var staged = Staged()

    /// States a still image cannot reach by itself, for captures. Rows are named "claude/<account>".
    struct Staged {
        var hover: String?
        var confirmRemove: String?
        var openAtLogin: Bool?
    }

    /// The page's own height, measured: the window follows it up to the limit.
    @State private var height: CGFloat = 0
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        Group {
            if staticRender {
                content
            } else {
                ScrollView {
                    content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: height > 0 ? min(height, Metrics.settingsMaxHeight) : nil)
            }
        }
        .frame(width: Metrics.settingsWidth)
        .task(id: model.banner?.id) {
            // As in the menu: a success message leaves by itself; errors and notes stay.
            guard let banner = model.banner, banner.kind == .success else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, model.banner?.id == banner.id { model.banner = nil }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Metrics.settingsGap) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            switch tab {
            case .general: GeneralSettings(model: model, staged: staged)
            case .accounts: AccountsSettings(model: model, staged: staged)
            case .about: AboutSettings()
            }
        }
        .padding(Metrics.settingsPad)
    }
}

// MARK: Shared parts

/// A group of rows on one surface, like a group in System Settings.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }
}

/// The hairline between two rows of a card.
struct RowDivider: View {
    var inset: CGFloat = Metrics.cardPad

    var body: some View {
        Divider().padding(.leading, inset)
    }
}

/// A title over a card, with something small on the right.
struct SectionHeader<Trailing: View>: View {
    var symbol: String?
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.body.weight(.semibold))
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Metrics.cardPad)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(symbol: String? = nil, title: String, detail: String? = nil) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// A setting: its name, one line about it, and its control.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control
        }
        .padding(Metrics.cardPad)
    }
}

/// The system switch. In a drawn image (no AppKit controls there) a look-alike stands in.
struct SwitchControl: View {
    @Binding var isOn: Bool
    let label: String
    var small = false
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        if staticRender {
            let height: CGFloat = small ? 18 : 22
            Capsule()
                .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Fill.track))
                .frame(width: small ? 32 : 38, height: height)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                        .frame(width: height - 3, height: height - 3)
                        .padding(1.5)
                }
        } else {
            Toggle(label, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(small ? .small : .regular)
        }
    }
}

/// A line of explanation that starts with what it is about: "Kept identical: …".
struct Point: View {
    let symbol: String
    /// Lead with the green "running" dot instead: the mark the open account wears in the diagram.
    var runningDot = false
    let lead: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if runningDot {
                    StatusDot(running: true).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
                } else {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            (Text(lead).fontWeight(.medium).foregroundStyle(.primary) + Text(text).foregroundStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

// MARK: General

struct GeneralSettings: View {
    let model: AppModel
    private let staged: SettingsPage.Staged
    @State private var openAtLogin: Bool
    @Environment(\.staticRender) private var staticRender

    init(model: AppModel, staged: SettingsPage.Staged = .init()) {
        self.model = model
        self.staged = staged
        _openAtLogin = State(initialValue: staged.openAtLogin ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.settingsGap) {
            SettingsCard {
                SettingRow(
                    title: L.t("Open at login", "登录时打开"),
                    detail: L.t("Switcher is in the menu bar as soon as you log in to this Mac.", "登录这台 Mac 后，Switcher 就已经在菜单栏里。")
                ) {
                    SwitchControl(isOn: Binding(
                        get: { openAtLogin },
                        set: {
                            // The system decides; show what it kept.
                            model.openAtLogin = $0
                            openAtLogin = model.openAtLogin
                        }), label: L.t("Open at login", "登录时打开"))
                }
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    MenuBarSketch()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Switcher lives in the menu bar", "Switcher 常驻菜单栏"))
                            .font(.body.weight(.medium))
                        (Text(L.t("Click ", "点击菜单栏里的 "))
                            + Text(Image(systemName: "person.2.circle")).foregroundStyle(.primary)
                            + Text(L.t(" to switch accounts, check usage or add an account. There is no Dock icon and no main window: that menu is the app, and this window only holds its settings.",
                                       " 即可切换账号、查看用量或添加账号。Switcher 没有程序坞图标，也没有主窗口：那个菜单就是整个应用，这个窗口只放设置。")))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Metrics.cardPad)
            }
        }
        .onAppear { if !staticRender { openAtLogin = model.openAtLogin } }
    }
}

/// The right end of a menu bar, with Switcher's icon picked out.
private struct MenuBarSketch: View {
    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "person.2.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 20)
                .background(Fill.tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Image(systemName: "magnifyingglass")
            Text(verbatim: "9:41")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .frame(height: Metrics.control)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius - 2, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: About

struct AboutSettings: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.settingsGap) {
            HStack(spacing: 14) {
                Image(systemName: "person.2.circle")
                    .font(.largeTitle.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: Metrics.appIcon, height: Metrics.appIcon)
                    .background(Fill.tint, in: RoundedRectangle(cornerRadius: Metrics.appIconRadius, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "Switcher")
                            .font(.title2.weight(.semibold))
                        Text(L.t("Version \(version)", "版本 \(version)"))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(L.t("Switches the official sign-ins of Claude and Antigravity on this Mac.",
                             "在这台 Mac 上切换 Claude 和 Antigravity 的官方登录。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Metrics.cardPad)

            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: L.t("Privacy", "隐私"))
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Point(symbol: "arrow.left.arrow.right", lead: L.t("Sign-ins are moved, never sent. ", "登录只在本机移动，从不外传。"),
                              text: L.t("Switching moves them between the app and Switcher's storage on this Mac.", "切换时，它们只在应用和 Switcher 在这台 Mac 上的存储之间移动。"))
                        Point(symbol: "gauge.with.dots.needle.33percent", lead: L.t("Antigravity quota comes from Google. ", "Antigravity 配额来自 Google。"),
                              text: L.t("Each account's own sign-in asks for its own numbers.", "每个账号用自己的登录读取自己的数字。"))
                        Point(symbol: "doc.text", lead: L.t("Claude usage comes from Claude's own files. ", "Claude 用量来自 Claude 自己的文件。"),
                              text: L.t("Switcher reads what Claude last saved on this Mac and asks no server.", "Switcher 只读取 Claude 上次保存在这台 Mac 上的数据，不请求任何服务器。"))
                    }
                    .padding(Metrics.cardPad)
                }
            }

            Text(L.t("Includes code ported from cc-same (MIT) and an approach from openusage.",
                     "包含移植自 cc-same（MIT）的代码，并借鉴了 openusage 的做法。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.cardPad)
        }
    }
}

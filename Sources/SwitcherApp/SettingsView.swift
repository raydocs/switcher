import SwiftUI
import SwitcherCore

/// The Settings window's tabs, in toolbar order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, accounts, terminal, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L.t("General", "通用")
        case .accounts: L.t("Accounts", "账号")
        case .terminal: L.t("Terminal", "终端诊断")
        case .about: L.t("About", "关于")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.2"
        case .terminal: "stethoscope"
        case .about: "info.circle"
        }
    }
}

/// The Settings window: the system's toolbar tabs over one page each.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        let _ = model.language
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
        var rename: String?
        var openAtLogin: Bool?
        var confirmUninstallShims = false
    }

    /// The page's own height, measured: the window follows it up to the limit.
    @State private var height: CGFloat = 0
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        let _ = model.language
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
            case .terminal: TerminalDoctorSettings(model: model, staged: staged)
            case .about: AboutSettings(model: model)
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
                RowDivider()
                SettingRow(
                    title: L.t("Menu bar display", "菜单栏样式"),
                    detail: L.t("Show the classic icon, two usage bars, or bars with a compact percentage.",
                                "可显示经典图标、双柱状用量条，或柱状条加紧凑百分比。")
                ) {
                    pickerControl(
                        label: L.t("Menu bar display", "菜单栏样式"),
                        selection: Binding(get: { model.menuBarStyle }, set: { model.menuBarStyle = $0 }),
                        cases: MenuBarStyle.allCases,
                        title: menuBarStyleName
                    )
                }
                if model.menuBarStyle != .icon {
                    RowDivider()
                    SettingRow(
                        title: L.t("Menu bar source", "菜单栏监控来源"),
                        detail: L.t("Automatically tracks the tightest active account across Antigravity, Claude Code and Codex, or pin one tool.",
                                    "自动追踪 Antigravity、Claude Code 和 Codex 中最紧的活跃账号，或固定显示某一个工具。")
                    ) {
                        pickerControl(
                            label: L.t("Menu bar source", "菜单栏监控来源"),
                            selection: Binding(get: { model.menuBarSource }, set: { model.menuBarSource = $0 }),
                            cases: MenuBarSource.allCases,
                            title: menuBarSourceName
                        )
                    }
                }
                RowDivider()
                SettingRow(
                    title: L.t("Quota display", "配额显示方式"),
                    detail: L.t("Show meters as percent used or percent remaining.",
                                "将用量条与百分比显示为“已用”或“剩余”。")
                ) {
                    pickerControl(
                        label: L.t("Quota display", "配额显示方式"),
                        selection: Binding(get: { model.quotaDisplayMode }, set: { model.quotaDisplayMode = $0 }),
                        cases: QuotaDisplayMode.allCases,
                        title: quotaModeName
                    )
                }
                RowDivider()
                SettingRow(
                    title: L.t("Global shortcut", "全局唤出快捷键"),
                    detail: L.t("Summon or dismiss Switcher from any app without Accessibility permission.",
                                "在任意应用内一键唤出或收起 Switcher，无需辅助功能权限。")
                ) {
                    pickerControl(
                        label: L.t("Global shortcut", "全局唤出快捷键"),
                        selection: Binding(get: { model.globalHotkey }, set: { model.globalHotkey = $0 }),
                        cases: GlobalHotkeyPreset.allCases,
                        title: \.label
                    )
                }
                RowDivider()
                SettingRow(
                    title: L.t("Hide email addresses", "隐藏邮箱地址"),
                    detail: L.t("Masks emails like a•••@l•••.dev for screenshots or screen sharing.",
                                "将邮箱显示为 a•••@l•••.dev，便于录屏或共享屏幕。")
                ) {
                    SwitchControl(isOn: Binding(
                        get: { model.hideEmails },
                        set: { model.hideEmails = $0 }),
                        label: L.t("Hide email addresses", "隐藏邮箱地址"))
                }
                RowDivider()
                SettingRow(
                    title: L.t("Language", "界面语言"),
                    detail: L.t("Choose Switcher's display language or follow macOS.",
                                "选择 Switcher 的界面语言，或跟随 macOS 系统设置。")
                ) {
                    pickerControl(
                        label: L.t("Language", "界面语言"),
                        selection: Binding(get: { model.language }, set: { model.language = $0 }),
                        cases: AppLanguage.allCases,
                        title: languageName
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(
                    symbol: "bell",
                    title: L.t("Notifications", "系统通知"),
                    detail: L.t("Sent at most once per reset cycle", "同一重置周期内最多提醒一次")
                )
                SettingsCard {
                    SettingRow(
                        title: L.t("Quota warnings (80% / 95%)", "配额预警（80% / 95%）"),
                        detail: L.t("Alerts when an active account runs low and suggests the account with the most room.",
                                    "当前活跃账号配额偏紧时提醒，并提示余量最多的备用账号。")
                    ) {
                        SwitchControl(isOn: Binding(
                            get: { model.notifyQuotaWarning },
                            set: { model.notifyQuotaWarning = $0 }),
                            label: L.t("Quota warnings", "配额预警"), small: true)
                    }
                    RowDivider()
                    SettingRow(
                        title: L.t("Quota reset recovery", "配额重置恢复"),
                        detail: L.t("Notifies when a previously low or exhausted window resets.",
                                    "之前触达预警或耗尽的配额窗口重置后通知恢复可用。")
                    ) {
                        SwitchControl(isOn: Binding(
                            get: { model.notifyQuotaReset },
                            set: { model.notifyQuotaReset = $0 }),
                            label: L.t("Quota reset recovery", "配额重置恢复"), small: true)
                    }
                    RowDivider()
                    SettingRow(
                        title: L.t("Expiring sign-ins", "登录即将过期"),
                        detail: L.t("Reminds before a CLI refresh token or saved desktop sign-in expires.",
                                    "在 CLI 刷新令牌或已保存的桌面登录即将过期前温和提醒。")
                    ) {
                        SwitchControl(isOn: Binding(
                            get: { model.notifySignInExpiry },
                            set: { model.notifySignInExpiry = $0 }),
                            label: L.t("Expiring sign-ins", "登录即将过期"), small: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(
                    title: L.t("Tools in the menu", "菜单中显示的工具"),
                    detail: L.t("Hide tools you don't use", "隐藏不使用的工具")
                )
                SettingsCard {
                    ForEach(Array(ToolID.allCases.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 { RowDivider() }
                        toolVisibilityRow(tool)
                    }
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    MenuBarSketch(model: model)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Switcher lives in the menu bar", "Switcher 常驻菜单栏"))
                            .font(.body.weight(.medium))
                        Text(L.t("Click Switcher in the menu bar (or press your global shortcut) to switch accounts, check usage or add an account. There is no Dock icon and no main window.",
                                 "点击菜单栏中的 Switcher（或按下全局快捷键）即可切换账号、查看用量或添加账号。Switcher 没有程序坞图标，也没有主窗口。"))
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

    @ViewBuilder
    private func pickerControl<T: Identifiable & Hashable>(
        label: String,
        selection: Binding<T>,
        cases: [T],
        title: (T) -> String
    ) -> some View {
        if staticRender {
            HStack(spacing: 4) {
                Text(title(selection.wrappedValue))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Fill.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Picker(label, selection: selection) {
                ForEach(cases) { item in
                    Text(title(item)).tag(item)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func toolVisibilityRow(_ tool: ToolID) -> some View {
        let enabled = !model.hiddenTools.contains(tool)
        let isAbsentCLI = tool.cliKind.map { kind in model.cliBoard(kind)?.isAbsent ?? true } ?? false
        let isOnlyVisible = enabled && model.visibleTools.count <= 1 && model.visibleTools.contains(tool)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: tool.symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.displayName)
                    .font(.body.weight(.medium))
                if isAbsentCLI {
                    Text(L.t("Not detected on this Mac", "此 Mac 上未检测到"))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            SwitchControl(
                isOn: Binding(
                    get: { enabled },
                    set: { model.toggleToolVisibility(tool, visible: $0) }
                ),
                label: tool.displayName,
                small: true
            )
            .disabled(isOnlyVisible)
        }
        .padding(.horizontal, Metrics.cardPad)
        .padding(.vertical, 9)
    }

    private func menuBarStyleName(_ style: MenuBarStyle) -> String {
        switch style {
        case .icon: L.t("Icon only", "仅图标")
        case .bars: L.t("Dual bars", "双柱状条")
        case .barsPercent: L.t("Bars + %", "柱状条 + 百分比")
        }
    }

    private func menuBarSourceName(_ source: MenuBarSource) -> String {
        switch source {
        case .auto: L.t("Auto (tightest)", "自动（最紧张）")
        case .antigravity: "Antigravity"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    private func quotaModeName(_ mode: QuotaDisplayMode) -> String {
        switch mode {
        case .used: L.t("Used %", "已用百分比")
        case .remaining: L.t("Remaining %", "剩余百分比")
        }
    }

    private func languageName(_ lang: AppLanguage) -> String {
        switch lang {
        case .system: L.t("System", "跟随系统")
        case .en: "English"
        case .zhHans: "简体中文"
        }
    }
}

/// The right end of a menu bar, with Switcher's live icon/meter picked out.
private struct MenuBarSketch: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            MenuBarLabel(model: model)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6)
                .frame(minWidth: 30, minHeight: 20)
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
    let model: AppModel
    @Environment(\.openURL) private var openURL

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
                    Text(L.t("Switches the official sign-ins of Claude, Antigravity, Claude Code and Codex on this Mac.",
                             "在这台 Mac 上切换 Claude、Antigravity、Claude Code 和 Codex 的官方登录。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Metrics.cardPad)

            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: L.t("Updates", "软件更新"))
                SettingsCard {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            updateTitle
                            updateSubtitle
                        }
                        Spacer(minLength: 8)
                        if case .updateAvailable(_, let release) = model.updateResult {
                            Button(L.t("View Release", "查看新版本")) {
                                openURL(release.htmlURL)
                            }
                            .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                        }
                        Button {
                            model.checkForUpdates()
                        } label: {
                            if model.checkingUpdate {
                                HStack(spacing: 4) {
                                    Spinner(size: 10)
                                    Text(L.t("Checking…", "检查中…"))
                                }
                            } else {
                                Text(L.t("Check for Updates", "检查更新"))
                            }
                        }
                        .buttonStyle(SoftButtonStyle(compact: true))
                        .disabled(model.checkingUpdate)
                    }
                    .padding(Metrics.cardPad)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: L.t("Privacy", "隐私"))
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Point(symbol: "arrow.left.arrow.right", lead: L.t("Desktop sign-ins stay on this Mac. ", "桌面应用登录只在本机移动。"),
                              text: L.t("Switching moves them between Claude or Antigravity and Switcher's local storage; credentials are never copied or sent elsewhere.",
                                        "切换只在应用与 Switcher 的本地存储之间移动文件与钥匙串项，不复制、不上传。"))
                        Point(symbol: "terminal", lead: L.t("CLI accounts never move credentials. ", "终端账号不移动任何凭据。"),
                              text: L.t("Claude Code and Codex each keep their own profile folder; switching only rewrites a local pointer for new terminal sessions.",
                                        "Claude Code 和 Codex 各自保留独立配置文件夹，切换只改写本地指针，只对新终端会话生效。"))
                        Point(symbol: "gauge.with.dots.needle.33percent", lead: L.t("Quotas come directly from each provider. ", "配额直接向各官方服务读取。"),
                              text: L.t("Antigravity asks Google, Claude Code asks Anthropic's usage endpoint using its own token, and Codex reads through codex app-server. Switcher never refreshes tokens on its own.",
                                        "Antigravity 向 Google 查询，Claude Code 用自身令牌请求官方用量接口，Codex 通过本地 codex app-server 读取。Switcher 从不擅自刷新令牌。"))
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

    @ViewBuilder private var updateTitle: some View {
        switch model.updateResult {
        case nil:
            Text(L.t("Manual update check", "手动检查更新"))
                .font(.body.weight(.medium))
        case .upToDate(_, let latest):
            Label(L.t("You're up to date (\(latest))", "已是最新版本（\(latest)）"), systemImage: "checkmark.circle.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
        case .updateAvailable(_, let release):
            Label(L.t("Version \(release.tagName) available", "发现新版本 \(release.tagName)"), systemImage: "arrow.down.circle.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
        case .noReleases:
            Text(L.t("No GitHub releases published yet", "GitHub 尚未发布正式版本"))
                .font(.body.weight(.medium))
        case .failed:
            Text(L.t("Couldn't check for updates", "无法检查更新"))
                .font(.body.weight(.medium))
        }
    }

    @ViewBuilder private var updateSubtitle: some View {
        switch model.updateResult {
        case nil:
            Text(L.t("Checks GitHub Releases only when you click; never runs in the background.",
                     "仅在手动点击时查询 GitHub Releases，不在后台静默联网。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .upToDate(let current, _):
            Text(L.t("Current version: \(current)", "当前版本：\(current)"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .updateAvailable(let current, let release):
            Text(L.t("Current: \(current) · Release: \(release.name)", "当前：\(current) · 发布：\(release.name)"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .noReleases:
            Text(L.t("Check back after the first tagged release.", "发布首个正式版本后可在此检查。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

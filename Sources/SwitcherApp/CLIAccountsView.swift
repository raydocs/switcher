import SwiftUI
import SwitcherCore

// Claude Code and Codex in the terminal, under the desktop apps in the popover. Choosing an account
// here only changes which one new `claude` / `codex` processes use: nothing quits, running sessions
// keep theirs, and the desktop apps are never touched.

/// One Claude Code or Codex account folder, as the popover shows it.
struct CLIRow: Equatable, Identifiable {
    enum SignIn: Equatable {
        /// Signed in. `until`: when the sign-in runs out unless the CLI is used before then.
        case good(until: Date?)
        case out
        /// Signed in another way (an API key).
        case other(String)

        var isGood: Bool {
            if case .good = self { return true }
            return false
        }
    }

    var kind: CLIKind
    /// 1 is the default account, as in `switcher cli use`.
    var number: Int
    var name: String
    /// Optional display alias stored in `cli-meta.json` (never renames the profile folder).
    var alias: String? = nil
    var isDefault: Bool
    /// The account new processes get.
    var isActive: Bool
    var email: String?
    var plan: String?
    var signIn: SignIn
    /// `kind.loginCommand(profile)`.
    var loginCommand: String
    /// `kind.launchCommand(profile)`.
    var launchCommand: String = ""
    /// The last usage read (kept between runs), and why the newest read failed.
    var quota: CLIQuota?
    var quotaError: CLIQuotaError?
    /// Room left in the tightest main window, after resets.
    var headroom: CLIHeadroom = .unknown
    /// The account to go to: the most room, shown while the active one is low or out.
    var isBest = false

    var id: String { "\(kind.rawValue):\(name)" }
    /// The account in a sentence: its alias, email, or folder name.
    var label: String { alias ?? email ?? name }
    /// Under the email: the folder's name (the email is the title), or nothing when there is no email.
    var secondary: String? {
        guard email != nil else { return nil }
        return isDefault ? L.t("default", "默认") : name
    }
}

/// One CLI: whether its command goes through Switcher, and its accounts.
struct CLIBoard: Equatable, Identifiable {
    var kind: CLIKind
    /// The PATH shim is there, so the chosen account has an effect.
    var shimInstalled: Bool
    /// The command itself is on this Mac.
    var commandFound: Bool
    var rows: [CLIRow]

    var id: String { kind.rawValue }
    var active: CLIRow? { rows.first { $0.isActive } }
    /// Nothing to show: the CLI is not here and nobody is signed in to it.
    var isAbsent: Bool { !commandFound && !rows.contains { $0.signIn != .out || !$0.isDefault } }

    /// `rows` with `isBest` on the account with the most room, only while the active one is low or out.
    static func markingBest(_ rows: [CLIRow]) -> [CLIRow] {
        var rows = rows
        guard let active = rows.first(where: \.isActive), active.headroom.status == .low || active.headroom.status == .out,
              let best = CLIUsage.best(rows.filter { !$0.isActive }.map { ($0.id, $0.headroom) }),
              let i = rows.firstIndex(where: { $0.id == best }) else { return rows }
        rows[i].isBest = true
        return rows
    }
}

extension L {
    static func cliGone(_ name: String) -> String {
        t("The account \(name) is no longer there.", "账号 \(name) 已不存在。")
    }

    static func cliNowUses(_ kind: CLIKind, _ who: String) -> String {
        t("New \(kind.command) sessions now use \(who). Sessions already running keep their account.",
          "新的 \(kind.command) 会话将使用 \(who)，正在运行的会话保持原来的账号。")
    }

    static func cliChosenNoEffect(_ kind: CLIKind, _ who: String) -> String {
        t("\(who) is chosen for \(kind.command), but it has no effect until the terminal setup is installed.",
          "已为 \(kind.command) 选用 \(who)，但要先安装终端设置才会生效。")
    }

    static func cliSignedIn(_ kind: CLIKind, _ who: String) -> String {
        t("Signed in as \(who). Click it to use it for new \(kind.command) sessions.", "已登录 \(who)。点它即可让新的 \(kind.command) 会话使用这个账号。")
    }

    static func cliDuplicate(_ who: String, _ other: String) -> String {
        t("Signed in as \(who), the same account as \(other).", "已登录 \(who)，和 \(other) 是同一个账号。")
    }

    static func cliSignInFailed(status: Int32, detail: String) -> String {
        let d = detail.trimmingCharacters(in: .whitespaces)
        return t("The sign-in did not finish (exit \(status))." + (d.isEmpty ? "" : " " + d), "登录没有完成（退出码 \(status)）。" + (d.isEmpty ? "" : d))
    }

    static func cliNotFound(_ kind: CLIKind) -> String {
        t("The \(kind.command) command was not found on this Mac.", "这台 Mac 上没有找到 \(kind.command) 命令。")
    }

    static func cliRenewFailed(_ who: String) -> String {
        t("The sign-in of \(who) could not be renewed just now. Run claude as that account once, or try again in half an hour.",
          "暂时无法续期 \(who) 的登录。用该账号运行一次 claude，或半小时后再试。")
    }

    /// "Dec 3", with the year when it is not this one.
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style: Date.FormatStyle = sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.year().month(.abbreviated).day()
        return date.formatted(style.locale(zh ? Locale(identifier: "zh-Hans") : Locale(identifier: "en_US")))
    }

    static func cliWindow(_ label: String) -> String {
        switch label {
        case "5h": fiveHour
        case "week": week
        default: label
        }
    }

    /// A model's own weekly window, named beside the Week meter: "week (Opus)" is "Opus" there.
    static func cliScope(_ label: String) -> String { cliScopeParts(label).name }

    /// A window outside the main ones, split into whose limit it is and how long it runs.
    /// Claude's "week (Opus)" is ("Opus", nil): the window is the week, said by the meter beside it.
    /// Codex's "<limit name> <window>" is (limit name, "5h" / "week" / "45m"); the name may hold spaces.
    static func cliScopeParts(_ label: String) -> (name: String, window: String?) {
        if label.hasPrefix("week ("), label.hasSuffix(")") {
            let scope = String(label.dropFirst(6).dropLast())
            return (scope == "scoped" ? t("Model", "模型") : scope, nil)
        }
        guard let space = label.lastIndex(of: " ") else { return (cliWindow(label), nil) }
        let window = String(label[label.index(after: space)...])
        guard CLIUsage.isMain(CLIQuotaWindow(label: window, usedPercent: 0, resetsAt: nil)) else { return (label, nil) }
        return (String(label[..<space]), window)
    }

    /// The tooltip of a separate limit, with its whole name.
    static func cliScopeHelp(_ parts: (name: String, window: String?), percent: Int, mode: QuotaDisplayMode = .used) -> String {
        let shown = mode.shownPercent(used: percent)
        let suffixEn = mode == .used ? "used" : "left"
        let suffixCn = mode == .used ? "已用 \(shown)%" : "剩余 \(shown)%"
        guard let window = parts.window else {
            return t("\(parts.name)'s own weekly limit is \(shown)% \(suffixEn).", "\(parts.name) 单独的每周额度\(suffixCn)。")
        }
        return t("The separate limit “\(parts.name)” (\(cliWindow(window))) is \(shown)% \(suffixEn).",
                 "单独的额度「\(parts.name)」（\(cliWindow(window))）\(suffixCn)。")
    }

    /// Any window's full name, for tooltips and VoiceOver: "Spark (45m)", "Opus (Week)".
    static func cliWindowFull(_ label: String) -> String {
        if CLIUsage.isMain(CLIQuotaWindow(label: label, usedPercent: 0, resetsAt: nil)) { return cliWindow(label) }
        let (name, window) = cliScopeParts(label)
        return "\(name) (\(cliWindow(window ?? "week")))"
    }
}

// MARK: Shared CLI notices

/// Without the shims the pointer changes nothing: say so, and offer the one click that fixes it.
struct CLIShimInstallNotice: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Note(symbol: "info.circle", text: L.t(
                "Not set up yet, so choosing here has no effect. Install adds one line to ~/.zshrc.",
                "尚未设置，在这里选用账号暂不生效。“安装”会在 ~/.zshrc 中加入一行。"))
            Spacer(minLength: 0)
            Button(L.t("Install", "安装")) { model.installCLIShims() }
                .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                .fixedSize()
                .help(L.t(
                    "Adds Switcher's launchers for claude and codex and one line at the end of ~/.zshrc (and ~/.bashrc if you have one). Open a new terminal for it to take effect.",
                    "加入 Switcher 的 claude 和 codex 启动器，并在 ~/.zshrc（以及已有的 ~/.bashrc）末尾加入一行。打开新的终端窗口后生效。"))
        }
        .padding(.horizontal, Metrics.rowH)
        .padding(.vertical, 6)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }
}

// MARK: One account

/// One terminal account: click to make new sessions use it; right-click (or ellipsis on hover)
/// to rename, launch a terminal session, copy command, re-sign in or remove.
struct CLIRowView: View {
    let model: AppModel
    let row: CLIRow
    var index: Int = 0
    @Binding var removing: String?
    @Binding var renaming: String?
    var forcedHover = false

    @State private var hovering = false
    @State private var draftAlias = ""
    @FocusState private var focused: Bool
    @FocusState private var aliasFocused: Bool
    @Environment(\.staticRender) private var staticRender

    private var command: String { row.kind.command }
    private var display: (title: String, subtitle: String?) { model.displayCLILabel(row) }
    private var showMenu: Bool { (hovering || forcedHover) && !model.isBusy && model.cliSigningIn[row.kind] == nil }

    private var timeLeft: TimeInterval? {
        if case .good(let until?) = row.signIn { return until.timeIntervalSinceNow }
        return nil
    }

    private var ranOut: Bool { timeLeft.map { $0 <= 0 } ?? false }
    private var needsSignIn: Bool { row.signIn == .out || ranOut }
    private var usable: Bool { !row.isActive && !needsSignIn }
    private var highlighted: Bool { (hovering || forcedHover || focused) && usable }
    private var needsRenewal: Bool { row.quotaError == .signInExpired && !needsSignIn && row.kind == .claude }

    /// The 5-hour and weekly windows, else the first two the CLI reports.
    private var windows: [CLIQuotaWindow] {
        guard let all = row.quota?.windows, !needsSignIn else { return [] }
        let main = ["5h", "week"].compactMap { label in all.first { $0.label == label } }
        return main.isEmpty ? Array(all.prefix(2)) : main
    }

    var body: some View {
        Group {
            if removing == row.id {
                removeConfirm
            } else if renaming == row.id {
                renameForm
            } else {
                normal
            }
        }
    }

    private var normal: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.useCLI(row)
            } label: {
                HStack(alignment: .top, spacing: Metrics.avatarGap) {
                    Avatar(label: "\(row.number)", seed: row.email ?? row.id)
                    VStack(alignment: .leading, spacing: 5) {
                        VStack(alignment: .leading, spacing: 1) {
                            titleLine
                            if let subtitle = display.subtitle {
                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        if !windows.isEmpty { meters }
                        if needsSignIn { signInNote } else { footnote }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(CLIRowPressStyle())
            .disabled(!usable)
            .focused($focused)
            .focusEffectDisabled()
            .help(usable ? L.t(
                "New \(command) sessions use \(display.title). Running sessions keep theirs, nothing quits, and the desktop apps are not affected.",
                "新的 \(command) 会话将使用 \(display.title)。正在运行的会话保持不变，不会退出任何程序，也不影响桌面应用。") : "")
            .accessibilityLabel("\(row.number), \(display.title)" + (display.subtitle.map { ", \($0)" } ?? ""))
            .accessibilityValue(row.isActive ? L.t("Used by new sessions", "新会话使用") : "")
            if needsSignIn {
                signInSteps
            } else if needsRenewal {
                renewal
            }
        }
        .padding(.horizontal, Metrics.rowH)
        .padding(.vertical, Metrics.rowV)
        .background(highlighted ? Fill.hover : (row.isActive ? Fill.card : .clear),
                    in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showMenu {
                moreMenu
                    .padding(.trailing, Metrics.rowH)
                    .padding(.top, Metrics.rowV)
            }
        }
        .contextMenu { if !model.isBusy && model.cliSigningIn[row.kind] == nil { menuItems } }
        .onHover { hovering = $0 }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(display.title)
                .font(.body.weight(row.isActive ? .semibold : .medium))
                .foregroundStyle(needsSignIn && !row.isActive ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let plan = row.plan, !plan.isEmpty {
                Tag(text: plan.prefix(1).uppercased() + plan.dropFirst())
            }
            Spacer(minLength: 4)
            if row.isBest, !highlighted {
                // A status, so a coloured symbol and plain text, as "Claude is running" is.
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(.green)
                    Text(L.t("Most room", "余量最多")).foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.medium))
                .fixedSize()
                .help(L.t("The active account is nearly out; this one has the most usage left. Click to use it for new \(command) sessions.",
                          "当前账号的额度快用完了，这个账号剩得最多。点它即可让新的 \(command) 会话使用它。"))
            }
            if row.isActive {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark").font(.caption2.weight(.bold))
                    Text(L.t("Active", "使用中")).font(.subheadline.weight(.medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Fill.tint, in: Capsule())
                .fixedSize()
                .help(L.t("New \(command) sessions use this account", "新的 \(command) 会话使用这个账号"))
            } else if highlighted {
                HStack(spacing: 3) {
                    Text(L.t("Use", "选用"))
                    Image(systemName: "arrow.right")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            } else if usable && !row.isBest && index < 9 {
                Text("⌘\(index + 1)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            if showMenu {
                // Room for the ellipsis menu laid over the row.
                Color.clear.frame(width: 16, height: 1)
            }
        }
    }

    // MARK: Menu & inline cards

    @ViewBuilder private var moreMenu: some View {
        let glyph = Image(systemName: "ellipsis.circle").font(.body).foregroundStyle(.secondary)
        if staticRender {
            glyph
        } else {
            Menu { menuItems } label: { glyph }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L.t("More", "更多"))
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button(L.t("Rename…", "设别名…")) {
            draftAlias = row.alias ?? ""
            removing = nil
            renaming = row.id
        }
        if !needsSignIn {
            Button(L.t("Open Terminal as This Account", "用此账号打开终端")) {
                model.openTerminalForCLI(row)
            }
        }
        if !row.launchCommand.isEmpty {
            Button(L.t("Copy Launch Command", "复制启动命令")) {
                model.copy(row.launchCommand)
            }
        }
        Button(L.t("Sign In Again…", "重新登录…")) {
            model.signInCLI(row)
        }
        if row.kind == .claude, row.signIn.isGood {
            Button(L.t("Renew Sign-In", "续期登录")) {
                model.renewCLISignIn(row)
            }
            .disabled(model.cliRenewing.contains(row.id))
        }
        Divider()
        Button(L.t("Remove…", "移除…"), role: .destructive) {
            renaming = nil
            removing = row.id
        }
        .disabled(row.isDefault)
    }

    private var renameForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: Metrics.avatarGap) {
                Avatar(label: "\(row.number)", seed: row.email ?? row.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("Set alias", "设置别名"))
                        .font(.body.weight(.semibold))
                    Text(model.displayEmail(row.email) ?? (row.isDefault ? L.t("default", "默认") : row.name))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if staticRender {
                let shown = draftAlias.isEmpty ? (row.alias ?? "") : draftAlias
                Text(shown.isEmpty ? L.t("e.g. Work, Personal", "例如：工作号、主力") : shown)
                    .font(.body)
                    .foregroundStyle(shown.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Fill.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                TextField(L.t("e.g. Work, Personal", "例如：工作号、主力"), text: $draftAlias)
                    .textFieldStyle(.roundedBorder)
                    .focused($aliasFocused)
                    .onSubmit { saveAlias() }
            }
            HStack(spacing: 6) {
                if row.alias != nil {
                    Button(L.t("Clear", "清除")) {
                        model.setCLIAlias(row, nil)
                        renaming = nil
                    }
                    .buttonStyle(QuietButtonStyle())
                    .font(.subheadline)
                }
                Spacer()
                Button(L.t("Cancel", "取消")) { renaming = nil }
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(L.t("Save", "保存")) { saveAlias() }
                    .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Metrics.rowH)
        .padding(.vertical, Metrics.rowV)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .onAppear {
            if draftAlias.isEmpty { draftAlias = row.alias ?? "" }
            if !staticRender { aliasFocused = true }
        }
    }

    private func saveAlias() {
        let trimmed = draftAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setCLIAlias(row, trimmed.isEmpty ? nil : trimmed)
        renaming = nil
    }

    private var removeConfirm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: Metrics.avatarGap) {
                Avatar(label: "\(row.number)", seed: row.email ?? row.id)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("Remove \(display.title)?", "移除 \(display.title)？"))
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(L.cliRemoveExplained(row.kind))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Spacer()
                Button(L.t("Cancel", "取消")) { removing = nil }
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(L.t("Remove", "移除")) {
                    model.removeCLI(row)
                    removing = nil
                }
                .buttonStyle(SoftButtonStyle(kind: .destructive, compact: true))
            }
        }
        .padding(.horizontal, Metrics.rowH)
        .padding(.vertical, Metrics.rowV)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }

    // MARK: Usage

    private var meters: some View {
        // A separate limit's warning sits beside the meters when its whole name fits there, and on a
        // line of its own below them when it does not: a long Codex limit name is never cut.
        ViewThatFits(in: .horizontal) {
            meterLine(scopedBeside: true)
            VStack(alignment: .leading, spacing: 4) {
                meterLine(scopedBeside: false)
                if let scoped = row.headroom.scopedWarning { scopedLabel(scoped, wraps: true) }
            }
        }
        .opacity(isStale ? 0.75 : 1)
        .help(usageDetail)
    }

    private func meterLine(scopedBeside: Bool) -> some View {
        let beside = scopedBeside ? row.headroom.scopedWarning : nil
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(windows, id: \.label) { window in
                    UsageMeter(title: L.cliWindow(window.label), name: row.kind.displayName + " " + L.cliWindow(window.label),
                               percent: Int(window.usedPercent.rounded()), pace: pace(window),
                               mode: model.quotaDisplayMode,
                               hugsPercent: beside != nil && window.label == windows.last?.label)
                }
            }
            Spacer(minLength: 8)
            if let beside { scopedLabel(beside, wraps: false) }
            if case .unavailable(let why) = row.quotaError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .padding(.leading, 8)
                    .help(L.t("The last usage read failed; these are the previous numbers.\n\(why)",
                              "上次读取用量失败，显示的是之前的数字。\n\(why)"))
                    .accessibilityLabel(L.t("Usage read failed", "用量读取失败"))
            }
        }
    }

    /// A third window without a bar: its name (and window, for a Codex limit), then the percent as
    /// the meters colour it.
    private func scopedLabel(_ scoped: CLIQuotaWindow, wraps: Bool) -> some View {
        let usedPercent = Int(scoped.usedPercent.rounded())
        let shown = model.quotaDisplayMode.shownPercent(used: usedPercent)
        let parts = L.cliScopeParts(scoped.label)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: parts.name)
                .foregroundStyle(.secondary)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: wraps)
            if let window = parts.window {
                Text(L.cliWindow(window))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            Text(verbatim: "\(shown)%")
                .monospacedDigit()
                .foregroundStyle(Fill.usage(usedPercent))
                .fixedSize()
        }
        .font(.subheadline)
        .help(L.cliScopeHelp(parts, percent: usedPercent, mode: model.quotaDisplayMode))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.kind.displayName + " " + L.cliWindowFull(scoped.label))
        .accessibilityValue(model.quotaDisplayMode == .used
            ? L.t("\(shown)% used", "已用 \(shown)%")
            : L.t("\(shown)% left", "剩余 \(shown)%"))
    }

    /// The even-pace mark: on the weekly meter only (a 5-hour window is spent in bursts).
    private func pace(_ w: CLIQuotaWindow) -> Int? {
        guard w.label == "week" || CLIUsage.duration(w) == 7 * 86400 else { return nil }
        return CLIUsage.pace(w, now: Date()).map { Int($0.rounded()) }
    }

    /// Older than this, the numbers say how old they are instead of when they reset.
    private var isStale: Bool { row.quota.map { Date().timeIntervalSince($0.observedAt) > 10 * 60 } ?? false }

    /// The fullest window that says when it resets: the one worth waiting for.
    private var nextReset: CLIQuotaWindow? {
        windows.filter { $0.resetsAt != nil && $0.usedPercent > 0 }.max { $0.usedPercent < $1.usedPercent }
    }

    private var usageDetail: String {
        guard let quota = row.quota else { return "" }
        let mode = model.quotaDisplayMode
        let suffix = mode == .used ? L.t(" used", " 已用") : L.t(" left", " 剩余")
        var lines = quota.windows.map { w in
            let shown = mode.shownPercent(used: Int(w.usedPercent.rounded()))
            return "\(L.cliWindowFull(w.label)): \(shown)%\(suffix)" + (w.resetsAt.map { ", " + L.resets($0) } ?? "")
        }
        if windows.contains(where: { pace($0) != nil }) {
            lines.append(mode == .used
                ? L.t("The mark on \(L.week) is an even pace: use past it runs out before the reset.",
                      "“\(L.week)”上的刻度是匀速使用的位置：超过它，会在重置前用完。")
                : L.t("The mark on \(L.week) is an even pace: remaining below it runs out before the reset.",
                      "“\(L.week)”上的刻度是匀速使用的余量基准：低于它，会在重置前用完。"))
        }
        lines.append(L.t("Read \(L.ago(quota.observedAt))", "读取于\(L.ago(quota.observedAt))"))
        return lines.joined(separator: "\n")
    }

    /// The sign-in on the left, and what the usage is waiting for on the right.
    private var footnote: some View {
        HStack(spacing: 10) {
            signInState
            Spacer(minLength: 0)
            if let quota = row.quota, !windows.isEmpty {
                if isStale {
                    Text(L.t("Read \(L.ago(quota.observedAt))", "读取于\(L.ago(quota.observedAt))"))
                        .foregroundStyle(.tertiary)
                } else if let reset = nextReset, let at = reset.resetsAt {
                    Text(L.cliWindow(reset.label) + " " + L.resets(at))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var signInState: some View {
        switch row.signIn {
        case .good(let until):
            if let until, let left = timeLeft {
                let days = Int((left / 86400).rounded(.up))
                if days < 5 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(days == 1 ? L.t("Runs out in 1 day", "1 天后失效") : L.t("Runs out in \(days) days", "\(days) 天后失效"))
                    }
                    .help(L.t("The sign-in runs out on \(L.day(until)) unless \(command) is used as this account before then.",
                              "如果在此之前没有用这个账号运行过 \(command)，登录将在 \(L.day(until)) 失效。"))
                } else {
                    Text(L.t("Sign-in good until \(L.day(until))", "登录有效至 \(L.day(until))"))
                }
            } else {
                Text(L.t("Signed in", "已登录"))
            }
        case .other(let mode):
            Text(mode.lowercased().contains("key") ? L.t("Signed in with an API key", "使用 API 密钥登录")
                 : L.t("Signed in with \(mode)", "通过 \(mode) 登录"))
        case .out:
            EmptyView()
        }
    }

    // MARK: What needs a terminal

    private var signInNote: some View {
        let lead = ranOut ? L.t("The sign-in has run out.", "登录已失效。") : L.t("Not signed in.", "未登录。")
        let how = L.t("Sign in opens your browser; or run this in a terminal:", "点“登录”会打开浏览器；也可以在终端运行：")
        return Note(symbol: ranOut ? "exclamationmark.circle" : "info.circle", text: lead + (L.zh ? "" : " ") + how, tint: ranOut ? .orange : nil)
    }

    private var signInSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(L.t("Sign In…", "登录…")) { model.signInCLI(row) }
            .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
            .fixedSize()
            CommandBox(model: model, command: row.loginCommand)
        }
        .padding(.leading, Metrics.avatar + Metrics.avatarGap)
    }

    private var renewal: some View {
        HStack(alignment: .center, spacing: 8) {
            Note(symbol: "exclamationmark.circle", text: L.t(
                "Usage is out of date until the sign-in is renewed.",
                "续期登录后才能更新用量。"), tint: .orange)
            Spacer(minLength: 0)
            if model.cliRenewing.contains(row.id) {
                Spinner(size: 12)
            } else {
                Button(L.t("Renew sign-in", "续期登录")) { model.renewCLISignIn(row) }
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .fixedSize()
                    .help(L.t("Runs claude once as this account, so it renews its own sign-in. Uses a few tokens of its plan.",
                              "用这个账号运行一次 claude，让它自己续期登录。会用掉套餐里的少量额度。"))
            }
        }
        .padding(.leading, Metrics.avatar + Metrics.avatarGap)
    }
}

/// The row's own fill shows hover and "active"; a press darkens it, out to the row's edges.
struct CLIRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        .fill(Fill.pressed)
                        .padding(.horizontal, -Metrics.rowH)
                        .padding(.vertical, -Metrics.rowV)
                }
            }
            .contentShape(Rectangle())
    }
}

/// A command to run in a terminal, whole, with Copy.
struct CommandBox: View {
    let model: AppModel
    let command: String

    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(command)
                .font(.subheadline.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? L.t("Copied", "已复制") : L.t("Copy", "复制")) {
                model.copy(command)
                copied = true
            }
            .buttonStyle(SoftButtonStyle(compact: true))
            .fixedSize()
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Adding an account

/// While the CLI's own sign-in runs in the background: the browser is open, finish there.
struct CLISigningInCard: View {
    let model: AppModel
    let kind: CLIKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Spinner(size: 12)
                Text(L.t("Waiting for the browser…", "等待浏览器…"))
                    .font(.body.weight(.semibold))
            }
            Text(L.t("Sign in to the \(kind.displayName) account you want in the browser window that opened. It shows up here when you are done.",
                     "在打开的浏览器窗口里登录想添加的 \(kind.displayName) 账号，完成后会出现在这里。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(L.t("Use Terminal Instead", "改用终端")) { model.continueCLISignInInTerminal(kind) }
                    .buttonStyle(QuietButtonStyle())
                    .font(.subheadline)
                    .help(L.t("If no browser opened: sign in in a Terminal window", "如果没有打开浏览器：在终端窗口里登录"))
                Spacer()
                Button(L.t("Cancel", "取消")) { model.cancelCLISignIn(kind) }
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.gap)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

import SwiftUI
import SwitcherCore

// Claude Code, Codex and Antigravity CLI in the terminal, under the desktop apps in the popover.
// Choosing an account here only changes which one new `claude` / `codex` / `agy` processes use:
// nothing quits, running sessions keep theirs, and the desktop apps are never touched.

/// One Claude Code, Codex or Antigravity CLI account folder, as the popover shows it.
struct CLIRow: Equatable, Identifiable {
    enum SignIn: Equatable {
        /// Signed in. `until`: when the sign-in runs out unless the CLI is used before then.
        case good(until: Date?)
        case out
        /// Signed in another way (an API key).
        case other(String)

        func isGood(at now: Date) -> Bool {
            if case .good(let until) = self { return until.map { $0 > now } ?? true }
            return false
        }

        var isGood: Bool { isGood(at: Date()) }
    }

    var kind: CLIKind
    /// 1 is the default account, as in `switcher cli use`.
    var number: Int
    var name: String
    var isDefault: Bool
    /// The account new processes get.
    var isActive: Bool
    var email: String?
    var plan: String?
    var signIn: SignIn
    /// `kind.loginCommand(profile)`.
    var loginCommand: String
    /// The last usage read (kept between runs), and why the newest read failed.
    var quota: CLIQuota?
    var quotaError: CLIQuotaError?
    /// Room left in the tightest main window, after resets.
    var headroom: CLIHeadroom = .unknown
    /// The account to go to: the most room, shown while the active one is low or out.
    var isBest = false
    /// Non-secret account identifier and credential digest for clearing stale quota errors.
    var accountKey: String? = nil
    var credentialFingerprint: String? = nil

    var id: String { "\(kind.rawValue):\(name)" }
    /// The account in a sentence: its own name, or who the default account is.
    var label: String { email ?? name }
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

    /// `rows` with `isBest` on the account with the most room, only while the active one is low or out
    /// and the candidate strictly improves on the active account's room.
    static func markingBest(_ rows: [CLIRow]) -> [CLIRow] {
        var rows = rows
        guard let active = rows.first(where: \.isActive), active.headroom.status == .low || active.headroom.status == .out,
              let best = CLIUsage.best(rows.filter { !$0.isActive }.map { ($0.id, $0.headroom) }),
              let i = rows.firstIndex(where: { $0.id == best }),
              (rows[i].headroom.percentLeft ?? 0) > (active.headroom.percentLeft ?? 0) else { return rows }
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

    static func cliRemoved(_ who: String) -> String {
        t("Removed \(who) and moved its folder to the Trash.", "已移除 \(who)，并将文件夹移到废纸篓。")
    }

    static func cliRemovedKeychainLeft(_ who: String) -> String {
        t("Moved \(who)'s folder to the Trash. Its Keychain entry could not be signed out automatically.",
          "已将 \(who) 的文件夹移到废纸篓；钥匙串里的登录未能自动退出。")
    }

    static var cliTerminalOpenFailed: String {
        t("Terminal could not be opened for the sign-in.", "无法打开终端进行登录。")
    }

    static var cliRemoveExplained: String {
        t("Switcher signs this account out and moves its folder to the Trash. Shared sessions and settings stay.",
          "Switcher 会退出这个账号并将文件夹移到废纸篓，共享的会话和设置会保留。")
    }

    /// "Dec 3", with the year when it is not this one.
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style: Date.FormatStyle = sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.year().month(.abbreviated).day()
        return date.formatted(style.locale(zh ? Locale(identifier: "zh-Hans") : .current))
    }

    static func cliWindow(_ label: String) -> String {
        switch label {
        case "5h": fiveHour
        case "week": week
        default: label
        }
    }

    /// A window outside the main ones, split into whose limit it is and how long it runs.
    /// Claude's "week (Opus)" is ("Opus", nil, isWeeklyModel: true).
    /// Codex's / Antigravity's "<limit name> <window>" is (limit name, "5h" / "week" / "45m", false).
    static func cliScopeParts(_ label: String) -> CLIUsage.ScopeParts {
        var parts = CLIUsage.scopeParts(label)
        if parts.name.isEmpty {
            parts.name = t("Limit", "额度")
        } else if parts.isWeeklyModel, parts.name == "scoped" {
            parts.name = t("Model", "模型")
        } else if !parts.isWeeklyModel, parts.window == nil, !parts.name.contains(" ") {
            parts.name = cliWindow(parts.name)
        }
        return parts
    }

    /// The tooltip of a separate limit, with its whole name.
    static func cliScopeHelp(_ parts: CLIUsage.ScopeParts, percent: Int) -> String {
        if parts.isWeeklyModel {
            return t("\(parts.name)'s own weekly limit is \(percent)% used.", "\(parts.name) 单独的每周额度已用 \(percent)%。")
        }
        if let window = parts.window {
            return t("The separate limit “\(parts.name)” (\(cliWindow(window))) is \(percent)% used.",
                     "单独的额度「\(parts.name)」（\(cliWindow(window))）已用 \(percent)%。")
        }
        return t("The separate limit “\(parts.name)” is \(percent)% used.",
                 "单独的额度「\(parts.name)」已用 \(percent)%。")
    }

    /// Any window's full name, for tooltips and VoiceOver: "Spark (45m)", "Opus (Week)".
    static func cliWindowFull(_ label: String) -> String {
        if CLIUsage.isMain(CLIQuotaWindow(label: label, usedPercent: 0, resetsAt: nil)) { return cliWindow(label) }
        let parts = cliScopeParts(label)
        if parts.isWeeklyModel { return "\(parts.name) (\(week))" }
        if let window = parts.window { return "\(parts.name) (\(cliWindow(window)))" }
        return parts.name
    }
}

// MARK: The section

struct CLISection: View {
    let model: AppModel
    /// Its height, so the popover can share the screen between the app's accounts and these.
    @Binding var height: CGFloat

    /// States a still image cannot reach by itself, for captures.
    struct Staged {
        var expanded: Set<CLIKind>?
        var adding: CLIKind?
        var hover: String?
    }

    private let staged: Staged
    @AppStorage("cliExpanded") private var stored = ""
    @State private var adding: CLIKind?
    @State private var removing: String?
    @State private var groupsHeight: CGFloat = 0
    @Environment(\.staticRender) private var staticRender

    init(model: AppModel, height: Binding<CGFloat>, staged: Staged = Staged()) {
        self.model = model
        self.staged = staged
        _height = height
        _adding = State(initialValue: staged.adding)
    }

    private var boards: [CLIBoard] { model.cliBoards.filter { !$0.isAbsent } }

    private var expanded: Set<CLIKind> {
        staged.expanded ?? Set(stored.split(separator: ",").compactMap { CLIKind(rawValue: String($0)) })
    }

    private var needsInstall: Bool { boards.contains { !$0.shimInstalled && $0.commandFound } }

    var body: some View {
        if !boards.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(L.t("Terminal", "终端"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(L.t("Applies to new sessions", "只对新会话生效"))
                        .font(.subheadline)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.rowH)
                .help(L.t(
                    "Accounts for the claude, codex and agy commands, apart from the desktop apps. The one you choose is used by sessions you start afterwards: running sessions keep theirs and nothing quits.",
                    "claude、codex 和 agy 命令使用的账号，与桌面应用无关。选用的账号只用于之后启动的会话：正在运行的会话保持不变，也不会退出任何程序。"))
                if needsInstall {
                    installNotice
                } else if model.cliJustInstalled {
                    Note(symbol: "checkmark.circle", text: L.t(
                        "Installed. Open a new terminal for it to take effect.", "已安装。打开新的终端窗口后生效。"), tint: .green)
                        .padding(.horizontal, Metrics.rowH)
                }
                if staticRender {
                    groups
                } else {
                    ScrollView {
                        groups
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { groupsHeight = $0 }
                    }
                    .frame(height: groupsHeight > 0 ? min(groupsHeight, Metrics.cliMaxHeight) : nil)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .onAppear { model.refreshCLI(quotaFor: expanded) }
        }
    }

    /// Without the shims the choice below changes nothing: say so, and offer the one click that fixes it.
    private var installNotice: some View {
        HStack(alignment: .center, spacing: 8) {
            Note(symbol: "info.circle", text: L.t(
                "Not set up yet, so choosing here has no effect. Install adds one line to ~/.zshrc.",
                "尚未设置，在这里选用账号暂不生效。“安装”会在 ~/.zshrc 中加入一行。"))
            Spacer(minLength: 0)
            Button(L.t("Install", "安装")) { model.installCLIShims() }
                .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                .fixedSize()
                .help(L.t(
                    "Adds Switcher's launchers for claude, codex and agy and one line at the end of ~/.zshrc (and ~/.bashrc if you have one). Open a new terminal for it to take effect.",
                    "加入 Switcher 的 claude、codex 和 agy 启动器，并在 ~/.zshrc（以及已有的 ~/.bashrc）末尾加入一行。打开新的终端窗口后生效。"))
        }
        .padding(.horizontal, Metrics.rowH)
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            ForEach(boards) { board in
                group(board)
            }
        }
    }

    @ViewBuilder private func group(_ board: CLIBoard) -> some View {
        let open = expanded.contains(board.kind)
        let reading = model.cliReading.contains(board.kind)
        let canRefresh = open && !reading && board.rows.contains(where: \.signIn.isGood) && !staticRender
        CLIGroupHeader(board: board, expanded: open, reading: reading,
                       onRefresh: canRefresh ? { model.refreshCLIUsage(board.kind) } : nil) {
            toggle(board.kind)
        }
        if open {
            if !board.commandFound {
                Note(symbol: "info.circle", text: L.cliNotFound(board.kind))
                    .padding(.leading, Metrics.rowH + Metrics.avatar + Metrics.avatarGap)
                    .padding(.vertical, 2)
            }
            let visibleRows = board.rows.filter { row in
                !(model.cliSignInCreatedNow.contains(board.kind) && model.cliSigningIn[board.kind] == row.name && row.signIn == .out)
            }
            ForEach(visibleRows) { row in
                CLIRowView(model: model, row: row, removing: $removing, forcedHover: staged.hover == row.id)
            }
            if model.cliSigningIn[board.kind] != nil || adding == board.kind {
                CLISigningInCard(model: model, kind: board.kind)
                    .padding(.vertical, 4)
            } else {
                Button {
                    model.addCLIAccount(board.kind)
                } label: {
                    // A last, quiet line of the list: the plus under the numbers, the words under the names.
                    HStack(spacing: Metrics.avatarGap) {
                        Image(systemName: "plus")
                            .frame(width: Metrics.avatar)
                        Text(L.t("Add Account…", "添加账号…"))
                    }
                    .padding(.horizontal, Metrics.rowH)
                    .padding(.vertical, 4)
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.cliStarting.contains(board.kind))
                .font(.callout)
                .help(L.t("Sign in to another \(board.kind.displayName) account in your browser",
                          "在浏览器里登录另一个 \(board.kind.displayName) 账号"))
                .padding(.bottom, 4)
            }
        }
    }

    private func toggle(_ kind: CLIKind) {
        var now = expanded
        if now.contains(kind) {
            now.remove(kind)
        } else {
            now.insert(kind)
            model.loadCLIQuota(kind)
        }
        stored = CLIKind.allCases.filter(now.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// "Claude Code" with the account new sessions get: click to show or hide its accounts.
struct CLIGroupHeader: View {
    let board: CLIBoard
    let expanded: Bool
    let reading: Bool
    var onRefresh: (() -> Void)? = nil
    let toggle: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Metrics.avatarGap) {
                Image(systemName: "terminal")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: Metrics.avatar)
                Text(board.kind.displayName)
                    .font(.body.weight(.semibold))
                    .fixedSize()
                Spacer(minLength: 4)
                if reading {
                    Spinner(size: 10)
                } else if !expanded, let active = board.active {
                    if active.signIn == .out {
                        Image(systemName: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .help(L.t("Not signed in", "未登录"))
                    }
                    Text(active.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, -4)
                } else if onRefresh != nil {
                    Color.clear.frame(width: 18, height: 1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                    .padding(.leading, -2)
            }
            .padding(.horizontal, Metrics.rowH)
            .padding(.vertical, Metrics.rowV)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle(highlighted: hovering || focused, current: false, focused: focused))
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .overlay(alignment: .trailing) {
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .frame(width: Metrics.controlCompact, height: Metrics.controlCompact)
                }
                .buttonStyle(QuietButtonStyle())
                .padding(.trailing, Metrics.rowH + 16)
                .help(L.t("Refresh \(board.kind.displayName) usage", "刷新 \(board.kind.displayName) 用量"))
                .accessibilityLabel(L.t("Refresh \(board.kind.displayName) usage", "刷新 \(board.kind.displayName) 用量"))
            }
        }
        .accessibilityLabel(board.kind.displayName)
        .accessibilityValue(board.active?.label ?? "")
        .accessibilityHint(expanded ? L.t("Hide accounts", "收起账号") : L.t("Show accounts", "展开账号"))
    }
}

// MARK: One account

/// One terminal account: click to make new sessions use it. What needs a terminal (signing in,
/// renewing) sits under the row with its own control.
struct CLIRowView: View {
    let model: AppModel
    let row: CLIRow
    @Binding var removing: String?
    var forcedHover = false

    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.staticRender) private var staticRender

    private var command: String { row.kind.command }

    private var timeLeft: TimeInterval? {
        if case .good(let until?) = row.signIn { return until.timeIntervalSinceNow }
        return nil
    }

    private var ranOut: Bool { timeLeft.map { $0 <= 0 } ?? false }
    private var needsSignIn: Bool { row.signIn == .out || ranOut }
    private var isRemoving: Bool { model.cliRemoving.contains(row.id) }
    private var isProfileBusy: Bool { model.isCLIProfileBusy(row.kind, name: row.name) }
    private var usable: Bool { !row.isActive && !needsSignIn && !isRemoving && model.cliSigningIn[row.kind] != row.name }
    private var highlighted: Bool { (hovering || forcedHover || focused) && usable }
    private var needsRenewal: Bool { row.quotaError == .signInExpired && !needsSignIn && row.kind == .claude }
    private var canRemove: Bool { !row.isDefault && !isProfileBusy }
    private var signInBusy: Bool { model.cliStarting.contains(row.kind) || model.cliSigningIn[row.kind] != nil }

    /// The main windows (short before weekly), else up to two non-warned windows if none are main.
    private var windows: [CLIQuotaWindow] {
        guard let all = row.quota?.windows, !needsSignIn else { return [] }
        let main = all.filter(CLIUsage.isMain).sorted {
            (CLIUsage.duration($0) ?? .infinity) < (CLIUsage.duration($1) ?? .infinity)
        }
        if !main.isEmpty { return Array(main.prefix(2)) }
        let warned = row.headroom.scopedWarning?.label
        return Array(all.filter { $0.label != warned }.prefix(2))
    }

    var body: some View {
        if removing == row.id {
            removeConfirm
        } else {
            normalRow
        }
    }

    private var normalRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.useCLI(row)
            } label: {
                HStack(alignment: .top, spacing: Metrics.avatarGap) {
                    Avatar(label: "\(row.number)", seed: row.email ?? row.id)
                    VStack(alignment: .leading, spacing: 5) {
                        VStack(alignment: .leading, spacing: 1) {
                            titleLine
                            if let tag = row.secondary {
                                Text(tag)
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
                "New \(command) sessions use \(row.label). Running sessions keep theirs, nothing quits, and the desktop apps are not affected.",
                "新的 \(command) 会话将使用 \(row.label)。正在运行的会话保持不变，不会退出任何程序，也不影响桌面应用。") : "")
            .accessibilityLabel("\(row.number), \(row.name)" + (row.email.map { ", \($0)" } ?? ""))
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
            if (hovering || forcedHover) && canRemove {
                moreMenu
                    .padding(.trailing, Metrics.rowH)
                    .padding(.top, Metrics.rowV)
            }
        }
        .contextMenu {
            if !row.isDefault {
                Button(L.t("Remove…", "移除…"), role: .destructive) { removing = row.id }
                    .disabled(!canRemove)
            }
        }
        .accessibilityAction(named: L.t("Remove…", "移除…")) {
            if canRemove { removing = row.id }
        }
        .onHover { hovering = $0 }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(row.email ?? row.name)
                .font(.body.weight(row.isActive ? .semibold : .medium))
                .foregroundStyle(needsSignIn && !row.isActive ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let plan = row.plan, !plan.isEmpty {
                Tag(text: plan.prefix(1).uppercased() + plan.dropFirst())
            }
            Spacer(minLength: 4)
            if isRemoving {
                Spinner(size: 12)
            } else {
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
                }
                if (hovering || forcedHover) && canRemove {
                    Color.clear.frame(width: 16, height: 1)
                }
            }
        }
    }

    @ViewBuilder private var moreMenu: some View {
        let glyph = Image(systemName: "ellipsis.circle").font(.body).foregroundStyle(.secondary)
        if staticRender {
            glyph
        } else {
            Menu {
                Button(L.t("Remove…", "移除…"), role: .destructive) { removing = row.id }
                    .disabled(!canRemove)
            } label: { glyph }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L.t("More", "更多"))
        }
    }

    private var removeConfirm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: Metrics.avatarGap) {
                Avatar(label: "\(row.number)", seed: row.email ?? row.id)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("Remove \(row.label)?", "移除 \(row.label)？"))
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(L.cliRemoveExplained)
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
                    model.removeCLIAccount(row)
                    removing = nil
                }
                .buttonStyle(SoftButtonStyle(kind: .destructive, compact: true))
                .disabled(!canRemove)
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
        let percent = Int(scoped.usedPercent.rounded())
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
            Text(verbatim: "\(percent)%")
                .monospacedDigit()
                .foregroundStyle(Fill.usage(percent))
                .fixedSize()
        }
        .font(.subheadline)
        .help(L.cliScopeHelp(parts, percent: percent))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.kind.displayName + " " + L.cliWindowFull(scoped.label))
        .accessibilityValue("\(percent)%")
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
        var lines = quota.windows.map { w in
            "\(L.cliWindowFull(w.label)): \(Int(w.usedPercent.rounded()))%" + (w.resetsAt.map { ", " + L.resets($0) } ?? "")
        }
        if windows.contains(where: { pace($0) != nil }) {
            lines.append(L.t("The mark on \(L.week) is an even pace: use past it runs out before the reset.",
                             "“\(L.week)”上的刻度是匀速使用的位置：超过它，会在重置前用完。"))
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
            HStack(spacing: 6) {
                Button(L.t("Sign In…", "登录…")) { model.signInCLI(row) }
                    .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                    .disabled(signInBusy || isProfileBusy)
                    .fixedSize()
                if !row.isDefault {
                    Button(L.t("Remove…", "移除…")) { removing = row.id }
                        .buttonStyle(SoftButtonStyle(compact: true))
                        .disabled(!canRemove)
                        .fixedSize()
                }
            }
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
                    .disabled(isProfileBusy)
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
    @Environment(\.staticRender) private var staticRender

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
                    .disabled(!model.cliCanHandoff.contains(kind) && !staticRender)
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

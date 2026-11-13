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

    var id: String { "\(kind.rawValue):\(name)" }
    /// The account in a sentence: its own name, or who the default account is.
    var label: String { isDefault ? (email ?? name) : name }
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

    static var cliNameRule: String {
        t("Use letters, digits, - _ or . for the name (and not \"default\").", "名称只能用字母、数字、- _ 和 .（不能是 default）。")
    }

    static func cliAdded(_ kind: CLIKind, _ name: String) -> String {
        t("Added \(name). Sign in to it with the command under its name.", "已添加 \(name)，用它名字下方的命令登录即可。")
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
        return date.formatted(style.locale(zh ? Locale(identifier: "zh-Hans") : .current))
    }

    static func cliWindow(_ label: String) -> String {
        switch label {
        case "5h": fiveHour
        case "week": week
        default: label
        }
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
        var name = ""
        var hover: String?
    }

    private let staged: Staged
    @AppStorage("cliExpanded") private var stored = ""
    @State private var adding: CLIKind?
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
                    "Accounts for the claude and codex commands, apart from the desktop apps. The one you choose is used by sessions you start afterwards: running sessions keep theirs and nothing quits.",
                    "claude 和 codex 命令使用的账号，与桌面应用无关。选用的账号只用于之后启动的会话：正在运行的会话保持不变，也不会退出任何程序。"))
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
                    "Adds Switcher's launchers for claude and codex and one line at the end of ~/.zshrc (and ~/.bashrc if you have one). Open a new terminal for it to take effect.",
                    "加入 Switcher 的 claude 和 codex 启动器，并在 ~/.zshrc（以及已有的 ~/.bashrc）末尾加入一行。打开新的终端窗口后生效。"))
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
        CLIGroupHeader(board: board, expanded: open, reading: model.cliReading.contains(board.kind)) { toggle(board.kind) }
        if open {
            if !board.commandFound {
                Note(symbol: "info.circle", text: L.cliNotFound(board.kind))
                    .padding(.leading, Metrics.rowH + Metrics.avatar + Metrics.avatarGap)
                    .padding(.vertical, 2)
            }
            ForEach(board.rows) { row in
                CLIRowView(model: model, row: row, forcedHover: staged.hover == row.id)
            }
            if adding == board.kind {
                CLIAddCard(model: model, kind: board.kind, stagedName: staged.name) { adding = nil }
                    .padding(.vertical, 4)
            } else {
                Button {
                    adding = board.kind
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
                .font(.callout)
                .help(L.t("Make another \(board.kind.displayName) account for the terminal, then sign in to it there",
                          "为终端新建一个 \(board.kind.displayName) 账号，然后在终端里登录"))
                .padding(.bottom, 4)
            }
        }
    }

    private func toggle(_ kind: CLIKind) {
        var now = expanded
        if now.contains(kind) {
            now.remove(kind)
            if adding == kind { adding = nil }
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
    var forcedHover = false

    @State private var hovering = false
    @FocusState private var focused: Bool

    private var command: String { row.kind.command }

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
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.useCLI(row)
            } label: {
                HStack(alignment: .top, spacing: Metrics.avatarGap) {
                    Avatar(label: "\(row.number)", seed: row.email ?? row.id)
                    VStack(alignment: .leading, spacing: 5) {
                        VStack(alignment: .leading, spacing: 1) {
                            titleLine
                            if let email = row.email {
                                Text(email)
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
        .onHover { hovering = $0 }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(row.name)
                .font(.body.weight(row.isActive ? .semibold : .medium))
                .foregroundStyle(needsSignIn && !row.isActive ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let plan = row.plan, !plan.isEmpty {
                Tag(text: plan.prefix(1).uppercased() + plan.dropFirst())
            }
            Spacer(minLength: 4)
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
        }
    }

    // MARK: Usage

    private var meters: some View {
        HStack(spacing: 8) {
            ForEach(windows, id: \.label) { window in
                UsageMeter(title: L.cliWindow(window.label), name: row.kind.displayName + " " + L.cliWindow(window.label),
                           percent: Int(window.usedPercent.rounded()))
            }
            Spacer(minLength: 0)
            if case .unavailable(let why) = row.quotaError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .help(L.t("The last usage read failed; these are the previous numbers.\n\(why)",
                              "上次读取用量失败，显示的是之前的数字。\n\(why)"))
                    .accessibilityLabel(L.t("Usage read failed", "用量读取失败"))
            }
        }
        .opacity(isStale ? 0.75 : 1)
        .help(usageDetail)
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
            "\(L.cliWindow(w.label)): \(Int(w.usedPercent.rounded()))%" + (w.resetsAt.map { ", " + L.resets($0) } ?? "")
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

    /// The command as typed: `loginCommand` without its trailing comment (an interactive zsh would
    /// pass the comment on as arguments).
    private var shellCommand: String {
        guard let comment = row.loginCommand.range(of: "#", options: .backwards) else { return row.loginCommand }
        return row.loginCommand[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    private var signInNote: some View {
        let lead = ranOut ? L.t("The sign-in has run out.", "登录已失效。") : L.t("Not signed in.", "未登录。")
        let how = row.kind == .claude
            ? L.t("Run this in a terminal, then type /login:", "在终端运行这条命令，然后输入 /login：")
            : L.t("Run this in a terminal:", "在终端运行这条命令：")
        return Note(symbol: ranOut ? "exclamationmark.circle" : "info.circle", text: lead + (L.zh ? "" : " ") + how, tint: ranOut ? .orange : nil)
    }

    private var signInSteps: some View {
        CommandBox(model: model, command: shellCommand)
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

/// A short name for the new account's folder. Signing in happens in a terminal afterwards: the new
/// row shows the command.
struct CLIAddCard: View {
    let model: AppModel
    let kind: CLIKind
    let close: () -> Void

    @State private var name: String
    @State private var problem: String?
    @State private var working = false
    @FocusState private var focused: Bool
    @Environment(\.staticRender) private var staticRender

    init(model: AppModel, kind: CLIKind, stagedName: String = "", close: @escaping () -> Void) {
        self.model = model
        self.kind = kind
        self.close = close
        _name = State(initialValue: stagedName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var placeholder: String { L.t("Name, like work", "名称，例如 work") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("Add a \(kind.displayName) account", "添加 \(kind.displayName) 账号"))
                .font(.body.weight(.semibold))
            Text(L.t("Give it a short name. It gets its own folder, and you sign in to it in a terminal next. Nothing running changes.",
                     "起一个简短的名称。它会有自己的文件夹，接着在终端里登录即可。正在运行的会话不受影响。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if staticRender {
                    Text(name.isEmpty ? placeholder : name)
                        .foregroundStyle(name.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholder, text: $name)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit(add)
                }
            }
            .font(.body)
            .padding(.horizontal, 8)
            .frame(height: Metrics.control)
            .background(Fill.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if focused || staticRender {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                }
            }
            if let problem {
                Note(symbol: "exclamationmark.circle", text: problem, tint: .orange)
            }
            HStack(spacing: 6) {
                Spacer()
                Button(L.t("Cancel", "取消"), action: close)
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(L.t("Add", "添加"), action: add)
                    .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || working)
            }
        }
        .padding(Metrics.gap)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .onAppear { focused = true }
        .onChange(of: name) { problem = nil }
    }

    private func add() {
        guard !trimmed.isEmpty, !working else { return }
        working = true
        model.addCLIProfile(kind, name: trimmed) { failure in
            working = false
            if let failure { problem = failure } else { close() }
        }
    }
}

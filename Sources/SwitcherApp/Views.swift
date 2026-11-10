import AppKit
import SwiftUI
import SwitcherCore

/// The menu bar popover: both apps as tabs, the selected app's accounts, and its actions.
struct MenuView: View {
    let model: AppModel

    /// States a still image cannot reach by itself (hover, a confirmation), for captures.
    struct Staged {
        var hover: String?
        var confirmRemove: String?
        var confirmAdd = false
    }

    private let staged: Staged
    @State private var removing: String?
    @State private var confirmingAdd: Bool
    @State private var listHeight: CGFloat = 0
    @AppStorage("ccSameOfferDismissed") private var ccSameDismissed = false
    @Environment(\.staticRender) private var staticRender

    init(model: AppModel, staged: Staged = Staged()) {
        self.model = model
        self.staged = staged
        _removing = State(initialValue: staged.confirmRemove)
        _confirmingAdd = State(initialValue: staged.confirmAdd)
    }

    private var busy: Bool { model.isBusy }
    private var board: AppBoard? { model.board(model.selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                AppTabs(model: model)
                    .inert(busy)
                if let job = model.job {
                    SwitchProgress(job: job, cancel: model.cancelSwitch)
                }
                if let banner = model.banner {
                    BannerView(banner: banner) { model.banner = nil }
                        .allowsHitTesting(!busy)
                }
                if let found = model.ccSame, model.selected == .claude, !ccSameDismissed || staticRender {
                    CCSameOffer(found: found, importNow: model.importCCSame) { ccSameDismissed = true }
                        .inert(busy)
                }
                if let board {
                    section(board)
                } else {
                    Note(symbol: "ellipsis", text: L.t("Reading your accounts…", "正在读取账号…"))
                        .padding(.vertical, Metrics.rowV)
                }
            }
            .padding(Metrics.pad)
            Divider()
            Footer()
                .inert(busy)
        }
        .frame(width: Metrics.width)
        .background { if !staticRender { shortcuts } }
        .onAppear { model.refresh() }
        .onChange(of: model.selected) {
            removing = nil
            confirmingAdd = false
        }
        .task(id: model.banner?.id) {
            // A success message leaves by itself; errors and notes stay until dismissed.
            guard let banner = model.banner, banner.kind == .success else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, model.banner?.id == banner.id { model.banner = nil }
        }
    }

    // MARK: The selected app

    @ViewBuilder private func section(_ board: AppBoard) -> some View {
        let app = board.provider.displayName
        if !board.installed {
            EmptyState(
                symbol: board.provider.symbol,
                title: L.t("\(app) is not installed", "未安装 \(app)"),
                text: L.t("Install \(app) and sign in. Its accounts then appear here.", "安装 \(app) 并登录后，账号会出现在这里。"))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(L.t("Accounts", "账号"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    StatusDot(running: board.running)
                    Text(board.running ? L.t("\(app) is running", "\(app) 运行中") : L.t("\(app) is not running", "\(app) 未运行"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Metrics.rowH)
                .opacity(busy ? 0.4 : 1)
                if board.interrupted {
                    Note(symbol: "exclamationmark.circle", text: L.t(
                        "A switch was cut short. It is finished or undone the next time \(app) quits.",
                        "有一次切换被中断，下次退出 \(app) 时会自动完成或撤销。"), tint: .orange)
                        .padding(.horizontal, Metrics.rowH)
                }
                if board.rows.isEmpty {
                    EmptyState(
                        symbol: "person.crop.circle.badge.plus",
                        title: L.t("No accounts yet", "还没有账号"),
                        text: L.t("Sign in to \(app). The account appears here, and Add Account brings in the next one.",
                                  "登录 \(app) 后账号会出现在这里，再用“添加账号…”加入下一个。"))
                } else if staticRender {
                    rows(board)
                } else {
                    // A menu-bar window gives a ScrollView no height of its own, so it shrank to a
                    // couple of rows: measure the rows and ask for exactly that, up to the cap.
                    ScrollView {
                        rows(board)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    }
                    .frame(height: listHeight > 0 ? min(listHeight, Metrics.listMaxHeight) : nil)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            actions(board)
        }
    }

    private func rows(_ board: AppBoard) -> some View {
        VStack(spacing: Metrics.rowGap) {
            ForEach(Array(board.rows.enumerated()), id: \.element.id) { index, row in
                AccountRowView(
                    model: model, provider: board.provider, row: row, index: index,
                    removing: $removing, forcedHover: staged.hover == row.id)
            }
        }
        .disabled(busy)
        .allowsHitTesting(!busy)
    }

    @ViewBuilder private func actions(_ board: AppBoard) -> some View {
        let app = board.provider.displayName
        if confirmingAdd && !busy {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("Add another \(app) account", "添加另一个 \(app) 账号"))
                    .font(.body.weight(.semibold))
                Text(board.running
                    ? L.t("\(app) restarts signed out. Sign in there to the account you want to add. Your current sign-in is saved first.",
                          "\(app) 会以未登录状态重新启动，在其中登录要添加的账号即可。当前登录会先保存好。")
                    : L.t("\(app) opens signed out. Sign in there to the account you want to add. Your current sign-in is saved first.",
                          "\(app) 会以未登录状态打开，在其中登录要添加的账号即可。当前登录会先保存好。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Spacer()
                    Button(L.t("Cancel", "取消")) { confirmingAdd = false }
                        .buttonStyle(SoftButtonStyle(compact: true))
                        .keyboardShortcut(.cancelAction)
                    Button(board.running ? L.t("Restart \(app)", "重启 \(app)") : L.t("Open \(app)", "打开 \(app)")) {
                        confirmingAdd = false
                        model.addAccount(board.provider)
                    }
                    .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Metrics.gap)
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        } else {
            HStack(spacing: 8) {
                Button {
                    model.next(board.provider)
                } label: {
                    Label(L.t("Next Account", "下一个账号"), systemImage: "arrow.right")
                }
                .buttonStyle(SoftButtonStyle(kind: .tinted))
                .disabled(!board.rows.contains { !$0.isCurrent && $0.canSwitch && !$0.slot.disabled })
                .help(L.t("Switch \(app) to the next account with a saved sign-in (⌘↩)", "将 \(app) 切换到下一个已保存登录的账号（⌘↩）"))
                Button {
                    confirmingAdd = true
                } label: {
                    Label(L.t("Add Account…", "添加账号…"), systemImage: "plus")
                }
                .buttonStyle(SoftButtonStyle())
                .help(L.t("Open \(app) signed out, to sign in to another account (⌘N)", "以未登录状态打开 \(app)，登录另一个账号（⌘N）"))
            }
            .inert(busy)
        }
    }

    // MARK: Keyboard

    /// ⌘1…⌘9 pick a row, ⌘↩ is Next Account, ⌘N adds, ⌃Tab changes app.
    private var shortcuts: some View {
        ZStack {
            if let board, board.installed, !busy {
                ForEach(Array(board.rows.prefix(9).enumerated()), id: \.element.id) { index, row in
                    Button("") { model.switchTo(board.provider, row) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Button("") { model.next(board.provider) }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("") { confirmingAdd = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            if !busy {
                Button("") { model.selected = model.selected == .claude ? .antigravity : .claude }
                    .keyboardShortcut(.tab, modifiers: .control)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

extension ProviderID {
    /// A neutral glyph for the app (no brand marks): a chat app and a code editor.
    var symbol: String {
        switch self {
        case .claude: "text.bubble"
        case .antigravity: "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: Tabs

/// Both apps at a glance: the name, whether it runs, and who is signed in. Click one to see its accounts.
struct AppTabs: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProviderID.allCases) { p in
                tab(p)
            }
        }
        .padding(3)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius + 3, style: .continuous))
    }

    private func tab(_ p: ProviderID) -> some View {
        let board = model.board(p)
        let selected = model.selected == p
        let installed = board?.installed ?? true
        let who: String = {
            guard let board else { return " " }
            if !board.installed { return L.t("Not installed", "未安装") }
            if let row = board.currentRow { return row.slot.label }
            return board.current == nil ? L.t("Signed out", "未登录") : L.t("Signed in", "已登录")
        }()
        let state: String = {
            guard let board, board.installed else { return L.t("Not installed", "未安装") }
            return board.running ? L.t("Running", "运行中") : L.t("Not running", "未运行")
        }()
        return Button {
            model.selected = p
        } label: {
            HStack(spacing: 8) {
                Image(systemName: p.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(p.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(selected ? .primary : .secondary)
                        if let board, board.installed { StatusDot(running: board.running) }
                    }
                    Text(who)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .opacity(installed ? 1 : 0.6)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        .fill(Fill.raised(scheme))
                        .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(p.displayName): \(state)")
        .accessibilityLabel("\(p.displayName), \(state), \(who)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: A switch in progress

/// What the switch is doing right now, as three named steps, with the one way out.
struct SwitchProgress: View {
    let job: SwitchJob
    let cancel: () -> Void

    private var app: String { job.provider.displayName }

    private var step: Int {
        switch job.phase {
        case .quitting: 0
        case .swapping: 1
        case .opening: 2
        }
    }

    private var waited: Int {
        if case .quitting(_, let waited) = job.phase { return waited }
        return 0
    }

    private var title: String {
        if let who = job.targetLabel, job.target != nil {
            return L.t("Switching \(app) to \(who)", "正在将 \(app) 切换到 \(who)")
        }
        return L.t("Opening \(app) signed out", "正在以未登录状态打开 \(app)")
    }

    private var steps: [String] {
        [
            L.t("Quit \(app)", "退出 \(app)"),
            job.target == nil ? L.t("Save sign-in", "保存登录") : L.t("Swap sign-in", "换入登录"),
            L.t("Open \(app)", "打开 \(app)"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Spinner()
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(L.t("Cancel", "取消"), action: cancel)
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .disabled(step != 0)
                    .help(step == 0
                        ? L.t("Stop waiting. \(app) stays as it is.", "不再等待，\(app) 保持原样。")
                        : L.t("Too late to cancel: the sign-in is being swapped.", "登录正在换入，已无法取消。"))
            }
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, name in
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule()
                            .fill(i < step ? Color.accentColor.opacity(0.45) : (i == step ? Color.accentColor : Fill.track))
                            .frame(height: 3)
                        HStack(spacing: 3) {
                            if i < step { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                            Text(name).lineLimit(1)
                        }
                        .font(.subheadline.weight(i == step ? .semibold : .regular))
                        .foregroundStyle(i == step ? AnyShapeStyle(.primary) : (i < step ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if waited > 3 {
                Note(symbol: "exclamationmark.bubble", text: L.t(
                    "\(app) is asking whether to quit. Answer it there.",
                    "\(app) 正在询问是否退出，请到它的窗口里回答。"), tint: .orange)
            }
        }
        .padding(Metrics.gap)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: Messages

struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    private var symbol: String {
        switch banner.kind {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .success: .green
        case .error: .red
        case .info: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(banner.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(QuietButtonStyle())
            .help(L.t("Dismiss", "关闭"))
            .accessibilityLabel(L.t("Dismiss", "关闭"))
        }
        .font(.callout)
        .padding(Metrics.gap)
        .background(banner.kind == .info ? Fill.card : tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }
}

/// Shown once while CC Same's saved sign-ins are still there to take over.
struct CCSameOffer: View {
    let found: CCSameImport.Found
    let importNow: () -> Void
    /// nil where the offer stays (the Settings window): no "Not Now".
    let dismiss: (() -> Void)?

    private var title: String {
        let n = found.logins.count
        if n == 0 { return L.t("Import your account list from CC Same", "从 CC Same 导入账号列表") }
        return n == 1
            ? L.t("Import 1 saved Claude sign-in from CC Same", "从 CC Same 导入 1 个已保存的 Claude 登录")
            : L.t("Import \(n) saved Claude sign-ins from CC Same", "从 CC Same 导入 \(n) 个已保存的 Claude 登录")
    }

    private var text: String {
        if found.running {
            return L.t("Quit CC Same first (its app and its background sync). Then import.",
                       "请先退出 CC Same（应用和后台同步），再导入。")
        }
        if found.interruptedSwitch {
            return L.t("CC Same has a switch it did not finish. Open CC Same once, quit it, then import.",
                       "CC Same 有一次未完成的切换。先打开一次 CC Same 再退出，然后导入。")
        }
        return L.t("Switcher takes over the accounts, numbers and aliases CC Same kept. Nothing is signed out.",
                   "Switcher 会接管 CC Same 保存的账号、编号和别名，不会退出任何登录。")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button(L.t("Import", "导入"), action: importNow)
                        .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                        .disabled(found.running || found.interruptedSwitch)
                    if let dismiss {
                        Button(L.t("Not Now", "以后再说"), action: dismiss)
                            .buttonStyle(SoftButtonStyle(compact: true))
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.gap)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(.body.weight(.semibold))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.pad)
        .padding(.vertical, Metrics.pad * 2)
    }
}

// MARK: Footer

struct Footer: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            Button(L.t("Settings…", "设置…")) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button(L.t("Quit Switcher", "退出 Switcher")) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(QuietButtonStyle())
        .font(.callout)
        .padding(.horizontal, Metrics.pad + Metrics.rowH)
        .padding(.vertical, 9)
    }
}

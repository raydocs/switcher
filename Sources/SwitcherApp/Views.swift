import AppKit
import SwiftUI
import SwitcherCore

/// The menu bar popover: unified top tool switcher, a single scrolling list, and unified actions.
struct MenuView: View {
    let model: AppModel

    /// States a still image cannot reach by itself (hover, a confirmation), for captures.
    struct Staged {
        var hover: String?
        var confirmRemove: String?
        var rename: String?
        var confirmAdd = false
        var addingCLI: CLIKind?
    }

    private let staged: Staged
    @State private var removing: String?
    @State private var renaming: String?
    @State private var confirmingAdd: Bool
    @State private var listHeight: CGFloat = 0
    @AppStorage("ccSameOfferDismissed") private var ccSameDismissed = false
    @Environment(\.staticRender) private var staticRender

    init(model: AppModel, staged: Staged = Staged()) {
        self.model = model
        self.staged = staged
        _removing = State(initialValue: staged.confirmRemove)
        _renaming = State(initialValue: staged.rename)
        _confirmingAdd = State(initialValue: staged.confirmAdd)
    }

    private var busy: Bool { model.isBusy }
    private var tab: MenuTab { model.activeTab }

    var body: some View {
        let _ = model.language
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                ToolTabs(model: model)
                    .inert(busy)
                if let job = model.job {
                    SwitchProgress(job: job, cancel: model.cancelSwitch)
                }
                if let banner = model.banner {
                    BannerView(banner: banner) { model.banner = nil }
                        .allowsHitTesting(!busy)
                }
                if let found = model.ccSame, tab == .claude || tab == .overview, !ccSameDismissed || staticRender {
                    CCSameOffer(found: found, importNow: model.importCCSame) { ccSameDismissed = true }
                        .inert(busy)
                }
                activeContent
            }
            .padding(Metrics.pad)
            Divider()
            Footer(model: model)
                .inert(busy)
        }
        .frame(width: Metrics.width)
        .background { if !staticRender { shortcuts } }
        .onDisappear { if !staticRender { model.surfaceDisappeared() } }
        .onAppear {
            if !staticRender {
                model.surfaceAppeared()
                let quotaKinds: Set<CLIKind>
                if let kind = tab.tool?.cliKind {
                    quotaKinds = [kind]
                } else if tab == .overview {
                    quotaKinds = Set(CLIKind.allCases)
                } else {
                    quotaKinds = []
                }
                model.refreshCLI(quotaFor: quotaKinds)
            }
        }
        .onChange(of: model.selectedTab) {
            removing = nil
            renaming = nil
            confirmingAdd = false
            listHeight = 0
        }
        .task(id: model.banner?.id) {
            // A success message leaves by itself; errors and notes stay until dismissed.
            guard let banner = model.banner, banner.kind == .success else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, model.banner?.id == banner.id { model.banner = nil }
        }
    }

    // MARK: Active tab content

    @ViewBuilder private var activeContent: some View {
        switch tab {
        case .overview:
            singleScroll { OverviewSection(model: model) }
                .inert(busy)
        case .claude:
            desktopContent(.claude)
        case .antigravity:
            desktopContent(.antigravity)
        case .claudeCode:
            cliContent(.claude)
        case .codex:
            cliContent(.codex)
        }
    }

    @ViewBuilder private func desktopContent(_ provider: ProviderID) -> some View {
        if let board = model.board(provider) {
            desktopSection(board)
        } else {
            Note(symbol: "ellipsis", text: L.t("Reading your accounts…", "正在读取账号…"))
                .padding(.vertical, Metrics.rowV)
        }
    }

    @ViewBuilder private func desktopSection(_ board: AppBoard) -> some View {
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
                    if board.provider == .antigravity,
                       let latest = board.rows.compactMap({ $0.quota?.fetchedAt }).max() {
                        Text("· \(L.ago(latest))")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
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
                } else {
                    singleScroll { desktopRows(board) }
                }
            }
            desktopActions(board)
        }
    }

    private func desktopRows(_ board: AppBoard) -> some View {
        let bestAG = board.provider == .antigravity ? model.bestAntigravityAccount : nil
        return VStack(spacing: Metrics.rowGap) {
            ForEach(Array(board.rows.enumerated()), id: \.element.id) { index, row in
                AccountRowView(
                    model: model, provider: board.provider, row: row, index: index,
                    removing: $removing, renaming: $renaming,
                    isBest: bestAG == row.id,
                    forcedHover: staged.hover == row.id)
            }
        }
        .disabled(busy)
        .allowsHitTesting(!busy)
    }

    @ViewBuilder private func desktopActions(_ board: AppBoard) -> some View {
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

    // MARK: CLI tab

    @ViewBuilder private func cliContent(_ kind: CLIKind) -> some View {
        if let board = model.cliBoard(kind) {
            cliSection(board)
        } else {
            Note(symbol: "ellipsis", text: L.t("Reading terminal accounts…", "正在读取终端账号…"))
                .padding(.vertical, Metrics.rowV)
        }
    }

    @ViewBuilder private func cliSection(_ board: CLIBoard) -> some View {
        let reading = model.cliReading.contains(board.kind)
        let signingIn = model.cliSigningIn[board.kind] != nil || staged.addingCLI == board.kind
        let latest = board.rows.compactMap { $0.quota?.observedAt }.max()
        let hasOtherUsable = board.rows.contains { !$0.isActive && $0.signIn.isGood }
        let hasBest = board.rows.contains { $0.isBest && !$0.isActive && $0.signIn.isGood }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(L.t("Accounts", "账号"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                if let latest {
                    Text("· \(L.ago(latest))")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if reading {
                    Spinner(size: 10)
                }
                Text(L.t("Applies to new sessions", "只对新会话生效"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Metrics.rowH)
            .help(L.t(
                "Chosen account applies to new \(board.kind.command) sessions. Running sessions keep theirs and nothing quits.",
                "选用的账号只对之后启动的 \(board.kind.command) 会话生效；正在运行的会话保持不变，不会退出任何程序。"))

            if !board.commandFound {
                Note(symbol: "info.circle", text: L.cliNotFound(board.kind))
                    .padding(.horizontal, Metrics.rowH)
            } else if !board.shimInstalled {
                CLIShimInstallNotice(model: model)
            } else if model.cliJustInstalled {
                Note(symbol: "checkmark.circle", text: L.t(
                    "Installed. Open a new terminal for it to take effect.", "已安装。打开新的终端窗口后生效。"), tint: .green)
                    .padding(.horizontal, Metrics.rowH)
            }

            singleScroll {
                VStack(spacing: Metrics.rowGap) {
                    ForEach(Array(board.rows.enumerated()), id: \.element.id) { index, row in
                        CLIRowView(
                            model: model, row: row, index: index,
                            removing: $removing, renaming: $renaming,
                            forcedHover: staged.hover == row.id)
                    }
                    if signingIn {
                        CLISigningInCard(model: model, kind: board.kind)
                            .padding(.top, 4)
                    }
                }
            }
        }
        .inert(busy)

        HStack(spacing: 8) {
            Button {
                model.nextCLI(board.kind)
            } label: {
                Label(hasBest ? L.t("Best Account", "切到余量最多") : L.t("Next Account", "下一个账号"), systemImage: "arrow.right")
            }
            .buttonStyle(SoftButtonStyle(kind: .tinted))
            .disabled(!hasOtherUsable || signingIn)
            .help(hasBest
                ? L.t("Switch new \(board.kind.command) sessions to the account with the most room (⌘↩)",
                      "让新的 \(board.kind.command) 会话切到余量最多的账号（⌘↩）")
                : L.t("Switch new \(board.kind.command) sessions to the next signed-in account (⌘↩)",
                      "让新的 \(board.kind.command) 会话切到下一个已登录账号（⌘↩）"))
            Button {
                model.addCLIAccount(board.kind)
            } label: {
                Label(L.t("Add Account…", "添加账号…"), systemImage: "plus")
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(!board.commandFound || signingIn)
            .help(L.t("Sign in to another \(board.kind.displayName) account in your browser (⌘N)",
                      "在浏览器里登录另一个 \(board.kind.displayName) 账号（⌘N）"))
        }
        .inert(busy)
    }

    @ViewBuilder private func singleScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if staticRender {
            content()
        } else {
            ScrollView {
                content()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: listHeight > 0 ? min(listHeight, Metrics.listMaxHeight) : nil)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: Keyboard

    /// ⌘1…⌘9 pick a row (or jump to a tool from Overview), ⌘↩ Next, ⌘N Add, ⌘R Refresh, ⌃Tab / ⌘[ / ⌘] switch tabs.
    private var shortcuts: some View {
        ZStack {
            if !busy {
                switch tab {
                case .overview:
                    ForEach(Array(model.visibleTools.prefix(9).enumerated()), id: \.element.id) { index, tool in
                        Button("") { model.selectedTab = MenuTab(tool) }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                case .claude, .antigravity:
                    if let provider = tab.tool?.desktopProvider, let board = model.board(provider), board.installed {
                        ForEach(Array(board.rows.prefix(9).enumerated()), id: \.element.id) { index, row in
                            Button("") { model.switchTo(board.provider, row) }
                                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        }
                        Button("") { model.next(board.provider) }
                            .keyboardShortcut(.return, modifiers: .command)
                        Button("") { confirmingAdd = true }
                            .keyboardShortcut("n", modifiers: .command)
                    }
                case .claudeCode, .codex:
                    if let kind = tab.tool?.cliKind, let board = model.cliBoard(kind) {
                        ForEach(Array(board.rows.prefix(9).enumerated()), id: \.element.id) { index, row in
                            Button("") {
                                if !row.isActive && row.signIn.isGood { model.useCLI(row) }
                            }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        }
                        Button("") { model.nextCLI(kind) }
                            .keyboardShortcut(.return, modifiers: .command)
                        Button("") { if board.commandFound { model.addCLIAccount(kind) } }
                            .keyboardShortcut("n", modifiers: .command)
                    }
                }
                Button("") { model.refreshAllNow() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("") { model.stepTab(delta: 1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("") { model.stepTab(delta: -1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("") { model.stepTab(delta: 1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("") { model.stepTab(delta: -1) }
                    .keyboardShortcut("[", modifiers: .command)
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

// MARK: Unified top tabs

/// Compact icon-over-label segmented bar covering Overview + all visible desktop and CLI tools.
struct ToolTabs: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tabs = model.visibleTabs
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius + 3, style: .continuous))
    }

    private func indicatorColor(for tab: MenuTab) -> Color? {
        switch tab {
        case .overview:
            let statuses: [CLIHeadroom.Status] = [
                model.board(.antigravity)?.currentRow?.quota?.status() ?? .unknown,
                model.cliBoard(.claude)?.active?.headroom.status ?? .unknown,
                model.cliBoard(.codex)?.active?.headroom.status ?? .unknown,
            ]
            if statuses.contains(.out) { return .red }
            if statuses.contains(.low) { return .orange }
            return nil
        case .claude:
            return model.board(.claude)?.running == true ? .green : nil
        case .antigravity:
            if let st = model.board(.antigravity)?.currentRow?.quota?.status() {
                if st == .out { return .red }
                if st == .low { return .orange }
            }
            return model.board(.antigravity)?.running == true ? .green : nil
        case .claudeCode:
            return cliDot(.claude)
        case .codex:
            return cliDot(.codex)
        }
    }

    private func cliDot(_ kind: CLIKind) -> Color? {
        guard let board = model.cliBoard(kind) else { return nil }
        if !board.shimInstalled && board.commandFound { return .orange }
        guard let active = board.active else { return nil }
        switch active.headroom.status {
        case .out: return .red
        case .low: return .orange
        case .ok, .unknown: return nil
        }
    }

    private func tabHelp(_ tab: MenuTab) -> String {
        switch tab {
        case .overview:
            return L.t("Overview of all tools and current accounts", "所有工具与当前账号总览")
        case .claude, .antigravity:
            guard let p = tab.tool?.desktopProvider, let b = model.board(p) else { return tab.title }
            if !b.installed { return "\(tab.title): \(L.t("Not installed", "未安装"))" }
            let who = b.currentRow.map { model.displayTabLabel($0.slot) } ?? L.t("Signed out", "未登录")
            let st = b.running ? L.t("Running", "运行中") : L.t("Not running", "未运行")
            return "\(tab.title) · \(st) · \(who)"
        case .claudeCode, .codex:
            guard let k = tab.tool?.cliKind, let b = model.cliBoard(k) else { return tab.title }
            let who = b.active.map { model.displayCLIActiveLabel($0) } ?? L.t("Signed out", "未登录")
            return "\(tab.title) · \(who)"
        }
    }

    private func tabButton(_ tab: MenuTab) -> some View {
        let selected = model.activeTab == tab
        let dot = indicatorColor(for: tab)
        let installed: Bool = {
            if let p = tab.tool?.desktopProvider { return model.board(p)?.installed ?? true }
            if let k = tab.tool?.cliKind { return model.cliBoard(k)?.commandFound ?? true }
            return true
        }()
        return Button {
            model.selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(height: 16)
                    if let dot {
                        Circle()
                            .fill(dot)
                            .frame(width: 5.5, height: 5.5)
                            .offset(x: 6, y: -1)
                    }
                }
                Text(tab.title)
                    .font(.caption.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .opacity(installed ? 1 : 0.55)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
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
        .help(tabHelp(tab))
        .accessibilityLabel(tabHelp(tab))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Overview tab

/// At-a-glance summary of every visible tool: active account, running/shim state, and tightest quota.
struct OverviewSection: View {
    let model: AppModel

    private var needsInstall: Bool {
        model.cliBoards.contains { !$0.isAbsent && !$0.shimInstalled && $0.commandFound }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(L.t("All tools", "全部工具"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L.t("Click a tool to switch", "点击进入切换"))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Metrics.rowH)

            if needsInstall {
                CLIShimInstallNotice(model: model)
            }

            VStack(spacing: 4) {
                ForEach(Array(model.visibleTools.enumerated()), id: \.element.id) { index, tool in
                    OverviewToolCard(model: model, tool: tool, index: index)
                }
            }
        }
    }
}

private struct OverviewToolCard: View {
    let model: AppModel
    let tool: ToolID
    let index: Int
    @State private var hovering = false

    var body: some View {
        Button {
            model.selectedTab = MenuTab(tool)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: tool.symbol)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(tool.displayName)
                                .font(.body.weight(.semibold))
                            statusTag
                        }
                        Text(activeAccountLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if let bestHint {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.right.circle.fill").foregroundStyle(.green)
                            Text(bestHint)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: 96, alignment: .trailing)
                    } else if index < 9 {
                        Text("⌘\(index + 1)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if let meter = summaryMeters {
                    meter
                        .padding(.leading, 30)
                }
            }
            .padding(.horizontal, Metrics.rowH)
            .padding(.vertical, Metrics.rowV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Fill.hover : Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var statusTag: some View {
        if let p = tool.desktopProvider, let b = model.board(p) {
            if !b.installed {
                Tag(text: L.t("Not installed", "未安装"))
            } else {
                StatusDot(running: b.running)
            }
        } else if let k = tool.cliKind, let b = model.cliBoard(k) {
            if !b.shimInstalled && b.commandFound {
                Tag(text: L.t("Setup needed", "未设置"))
            } else if let plan = b.active?.plan, !plan.isEmpty {
                Tag(text: plan.prefix(1).uppercased() + plan.dropFirst())
            }
        }
    }

    private var activeAccountLine: String {
        if let p = tool.desktopProvider {
            guard let b = model.board(p) else { return L.t("Reading…", "读取中…") }
            if !b.installed { return L.t("Not installed", "未安装") }
            guard let row = b.currentRow else { return L.t("Signed out", "未登录") }
            let d = model.displayLabel(row.slot)
            return d.subtitle.map { "\(d.title) · \($0)" } ?? d.title
        }
        if let k = tool.cliKind {
            guard let b = model.cliBoard(k), let active = b.active else { return L.t("Signed out", "未登录") }
            if active.signIn == .out { return L.t("Not signed in", "未登录") }
            let d = model.displayCLILabel(active)
            return d.subtitle.map { "\(d.title) · \($0)" } ?? d.title
        }
        return ""
    }

    /// Name of the recommended fallback account when the active account is tight.
    private var bestHint: String? {
        if tool == .antigravity,
           let bestID = model.bestAntigravityAccount,
           let row = model.board(.antigravity)?.rows.first(where: { $0.id == bestID }) {
            return model.displayTabLabel(row.slot)
        }
        if let k = tool.cliKind,
           let best = model.cliBoard(k)?.rows.first(where: \.isBest) {
            return model.displayCLIActiveLabel(best)
        }
        return nil
    }

    private var summaryMeters: AnyView? {
        let mode = model.quotaDisplayMode
        if tool == .antigravity, let q = model.board(.antigravity)?.currentRow?.quota {
            let g5 = q.bucket(.gemini5h), gw = q.bucket(.geminiWeekly)
            let c5 = q.bucket(.claude5h), cw = q.bucket(.claudeWeekly)
            let tightestPair: (String, QuotaBucket?, QuotaBucket?) = {
                let gMax = max(g5?.used ?? -1, gw?.used ?? -1)
                let cMax = max(c5?.used ?? -1, cw?.used ?? -1)
                return cMax > gMax ? ("Claude", c5, cw) : ("Gemini", g5, gw)
            }()
            return AnyView(
                HStack(spacing: 8) {
                    Text(tightestPair.0)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .leading)
                        .padding(.trailing, -4)
                    UsageMeter(title: L.fiveHour, name: "\(tightestPair.0) \(L.fiveHour)", percent: tightestPair.1?.used, mode: mode)
                    UsageMeter(title: L.week, name: "\(tightestPair.0) \(L.week)", percent: tightestPair.2?.used,
                               pace: tightestPair.2?.pace().map { Int($0.rounded()) }, mode: mode)
                    Spacer(minLength: 0)
                }
            )
        }
        if tool == .claude,
           let email = model.board(.claude)?.currentRow?.slot.email,
           let q = model.matchingCLIQuota(forDesktopEmail: email) {
            return AnyView(ClaudeCLIReferenceLine(quota: q, mode: mode))
        }
        if let k = tool.cliKind,
           let active = model.cliBoard(k)?.active,
           active.signIn.isGood,
           let q = active.quota {
            let main = ["5h", "week"].compactMap { lbl in q.windows.first { $0.label == lbl } }
            let shown = main.isEmpty ? Array(q.windows.prefix(2)) : main
            guard !shown.isEmpty else { return nil }
            return AnyView(
                HStack(spacing: 8) {
                    ForEach(shown, id: \.label) { w in
                        let pace = (w.label == "week" || CLIUsage.duration(w) == 7 * 86400)
                            ? CLIUsage.pace(w, now: Date()).map { Int($0.rounded()) } : nil
                        UsageMeter(title: L.cliWindow(w.label), name: "\(k.displayName) \(L.cliWindow(w.label))",
                                   percent: Int(w.usedPercent.rounded()), pace: pace, mode: mode)
                    }
                    Spacer(minLength: 0)
                }
            )
        }
        return nil
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
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 12) {
            Button(L.t("Settings…", "设置…")) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button {
                model.refreshAllNow()
            } label: {
                if model.isRefreshing {
                    Spinner(size: 11)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16, height: 16)
                }
            }
            .disabled(model.isRefreshing)
            .help(L.t("Refresh accounts and quotas now (⌘R)", "立即刷新账号与配额（⌘R）"))
            .accessibilityLabel(L.t("Refresh", "刷新"))
            Button {
                model.hideEmails.toggle()
            } label: {
                Image(systemName: model.hideEmails ? "eye.slash" : "eye")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(QuietButtonStyle(tinted: model.hideEmails))
            .help(model.hideEmails
                ? L.t("Show email addresses", "显示邮箱地址")
                : L.t("Hide email addresses for screenshots or screen sharing", "隐藏邮箱地址（便于录屏或共享屏幕）"))
            .accessibilityLabel(model.hideEmails ? L.t("Show email addresses", "显示邮箱地址") : L.t("Hide email addresses", "隐藏邮箱地址"))
            Button(L.t("Quit Switcher", "退出 Switcher")) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(QuietButtonStyle())
        .font(.callout)
        .padding(.horizontal, Metrics.pad + Metrics.rowH)
        .padding(.vertical, 9)
    }
}

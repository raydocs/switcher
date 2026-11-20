import SwiftUI
import SwitcherCore
import UniformTypeIdentifiers

/// Accounts: each app's numbered list. Drag a row (or move it up and down) to reorder, keep it out of Next Account, or remove it.
struct AccountsSettings: View {
    let model: AppModel
    private let staged: SettingsPage.Staged
    @State private var removing: String?
    @State private var renaming: String?
    @State private var dragging: String?
    @State private var dropTarget: String?
    @State private var creatingSandbox = false

    init(model: AppModel, staged: SettingsPage.Staged = .init()) {
        self.model = model
        self.staged = staged
        _removing = State(initialValue: staged.confirmRemove)
        _renaming = State(initialValue: staged.rename)
    }

    private var visibleCLIBoards: [CLIBoard] { model.cliBoards.filter { !$0.isAbsent } }
    private var showSandboxes: Bool {
        !model.sandboxes.isEmpty || (model.board(.antigravity)?.installed == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.settingsGap) {
            if let found = model.ccSame {
                CCSameOffer(found: found, importNow: model.importCCSame, dismiss: nil)
            }
            if model.boards.isEmpty {
                Note(symbol: "ellipsis", text: L.t("Reading your accounts…", "正在读取账号…"))
                    .padding(.horizontal, Metrics.cardPad)
            }
            ForEach(model.boards) { board in
                section(board)
            }
            if model.boards.contains(where: { $0.rows.count > 1 }) {
                Note(symbol: "line.3.horizontal", text: L.t(
                    "Drag a desktop account to reorder it. The order here is the order in the menu, and the order Next Account follows.",
                    "拖动桌面应用账号可以调整顺序。这里的顺序就是菜单里的顺序，也是“下一个账号”依次切换的顺序。"))
                    .padding(.horizontal, Metrics.cardPad)
            }
            if showSandboxes {
                sandboxesSection
            }
            ForEach(visibleCLIBoards) { board in
                cliSection(board)
            }
        }
        .inert(model.isBusy)
        .onAppear {
            model.surfaceAppeared()
            model.refreshCLI()
        }
        .onDisappear { model.surfaceDisappeared() }
    }

    @ViewBuilder private var sandboxesSection: some View {
        let n = model.sandboxes.count
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                symbol: "square.on.square",
                title: L.t("Antigravity Parallel Sandboxes", "Antigravity 并行分身"),
                detail: n == 0 ? nil : (n == 1 ? L.t("1 sandbox", "1 个分身") : L.t("\(n) sandboxes", "\(n) 个分身"))
            ) {
                if !creatingSandbox {
                    Button {
                        removing = nil
                        renaming = nil
                        creatingSandbox = true
                    } label: {
                        Label(L.t("New…", "新建…"), systemImage: "plus")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .font(.subheadline)
                }
            }
            if creatingSandbox {
                NewSandboxCard(model: model, creating: $creatingSandbox)
            }
            SettingsCard {
                if model.sandboxes.isEmpty {
                    EmptyState(
                        symbol: "square.on.square",
                        title: L.t("No parallel sandboxes yet", "还没有并行分身"),
                        text: L.t(
                            "Create a sandbox to run extra Antigravity desktop windows and `agy` CLI terminals side-by-side on separate accounts.",
                            "创建分身后，可同时运行多个独立账号的 Antigravity 桌面窗口与 agy 终端。"))
                } else {
                    ForEach(Array(model.sandboxes.enumerated()), id: \.element.id) { index, sandbox in
                        if index > 0 { RowDivider() }
                        SandboxRowView(
                            model: model,
                            sandbox: sandbox,
                            removing: $removing,
                            renaming: $renaming,
                            forcedHover: staged.hover == AntigravitySandboxesSection.rowKey(sandbox)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder private func cliSection(_ board: CLIBoard) -> some View {
        let n = board.rows.count
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                symbol: board.kind == .claude ? ToolID.claudeCode.symbol : ToolID.codex.symbol,
                title: board.kind.displayName,
                detail: n == 1 ? L.t("1 account", "1 个账号") : L.t("\(n) accounts", "\(n) 个账号")
            ) {
                HStack(spacing: 8) {
                    if !board.shimInstalled && board.commandFound {
                        Tag(text: L.t("Setup needed", "未设置"))
                    }
                    Button {
                        model.addCLIAccount(board.kind)
                    } label: {
                        Label(L.t("Add…", "添加…"), systemImage: "plus")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .font(.subheadline)
                    .disabled(!board.commandFound || model.cliSigningIn[board.kind] != nil)
                }
            }
            SettingsCard {
                ForEach(Array(board.rows.enumerated()), id: \.element.id) { index, row in
                    let key = Self.cliKey(row)
                    if index > 0 { RowDivider() }
                    CLIAccountSettingsRow(
                        model: model, row: row, key: key,
                        removing: $removing, renaming: $renaming,
                        forcedHover: staged.hover == key)
                }
            }
        }
    }

    static func cliKey(_ row: CLIRow) -> String { "cli/\(row.id)" }

    @ViewBuilder private func section(_ board: AppBoard) -> some View {
        let app = board.provider.displayName
        let n = board.rows.count
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                symbol: board.provider.symbol, title: app,
                detail: !board.installed || n == 0 ? nil : (n == 1 ? L.t("1 account", "1 个账号") : L.t("\(n) accounts", "\(n) 个账号"))
            ) {
                if n > 0 {
                    Text(L.t("Next Account", "下一个账号"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .help(L.t("Off: Next Account skips the account. Clicking it in the menu still switches.", "关闭后，“下一个账号”会跳过它；在菜单里点击它仍可切换。"))
                }
            }
            SettingsCard {
                if !board.installed {
                    EmptyState(
                        symbol: board.provider.symbol,
                        title: L.t("\(app) is not installed", "未安装 \(app)"),
                        text: L.t("Install \(app) and sign in. Its accounts then appear here.", "安装 \(app) 并登录后，账号会出现在这里。"))
                } else if board.rows.isEmpty {
                    EmptyState(
                        symbol: "person.crop.circle.badge.plus",
                        title: L.t("No accounts yet", "还没有账号"),
                        text: L.t("Sign in to \(app). The account appears here; Add Account in the menu brings in the next one.",
                                  "登录 \(app) 后账号会出现在这里，再用菜单里的“添加账号…”加入下一个。"))
                } else {
                    ForEach(Array(board.rows.enumerated()), id: \.element.id) { index, row in
                        let key = Self.key(board.provider, row.id)
                        if index > 0 { RowDivider() }
                        AccountSettingsRow(
                            model: model, board: board, row: row, index: index, key: key,
                            removing: $removing, renaming: $renaming, dragging: $dragging, dropTarget: $dropTarget,
                            forcedHover: staged.hover == key,
                            place: { place(board, $0, at: $1) })
                    }
                }
            }
        }
    }

    static func key(_ p: ProviderID, _ account: String) -> String { "\(p.rawValue)/\(account)" }

    /// Put `account` at `index` atomically in a single locked write.
    private func place(_ board: AppBoard, _ account: String, at index: Int) {
        guard let from = board.rows.firstIndex(where: { $0.id == account }),
              board.rows.indices.contains(index), from != index else { return }
        model.reorder(board.provider, account, toIndex: index)
    }
}

/// One account in the Settings list.
struct AccountSettingsRow: View {
    let model: AppModel
    let board: AppBoard
    let row: AccountRow
    let index: Int
    let key: String
    @Binding var removing: String?
    @Binding var renaming: String?
    @Binding var dragging: String?
    @Binding var dropTarget: String?
    var forcedHover = false
    /// Move an account of this list to a place in it (0 is the top).
    let place: (_ account: String, _ index: Int) -> Void

    @State private var hovering = false
    @State private var draftAlias = ""
    /// The switch as just set, until the list catches up (edits land after a re-read).
    @State private var included: Bool?
    @FocusState private var aliasFocused: Bool
    @Environment(\.staticRender) private var staticRender

    private var provider: ProviderID { board.provider }
    private var app: String { provider.displayName }
    private var display: (title: String, subtitle: String?) { model.displayLabel(row.slot) }
    private var isFirst: Bool { index == 0 }
    private var isLast: Bool { index == board.rows.count - 1 }
    private var draggedIndex: Int? {
        guard let dragging else { return nil }
        return board.rows.firstIndex { AccountsSettings.key(provider, $0.id) == dragging }
    }

    var body: some View {
        // Drag and drop are AppKit's: not there in a drawn image.
        if staticRender {
            content
        } else {
            content.onDrop(of: [UTType.text], delegate: RowDrop(
                key: key, accepts: draggedIndex != nil && draggedIndex != index,
                dragging: $dragging, target: $dropTarget, perform: { if let from = draggedIndex { place(board.rows[from].id, index) } }))
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            grip
            Text(verbatim: "\(row.slot.number)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, minHeight: Metrics.avatar)
                .accessibilityLabel(L.t("Number \(row.slot.number)", "编号 \(row.slot.number)"))
            Avatar(label: display.title, seed: row.id)
            Group {
                if removing == key {
                    removeConfirm
                } else if renaming == key {
                    renameForm
                } else {
                    normal
                }
            }
            .frame(minHeight: Metrics.avatar)
        }
        .padding(.horizontal, Metrics.cardPad)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(alignment: (draggedIndex ?? 0) < index ? .bottom : .top) {
            if dropTarget == key {
                Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, Metrics.cardPad)
            }
        }
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: L.t("Move Up", "上移")) { place(row.id, index - 1) }
        .accessibilityAction(named: L.t("Move Down", "下移")) { place(row.id, index + 1) }
    }

    // MARK: Parts

    @ViewBuilder private var grip: some View {
        let glyph = Image(systemName: "line.3.horizontal")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .frame(width: 14, height: Metrics.avatar)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        if board.rows.count > 1 && staticRender {
            glyph
        } else if board.rows.count > 1 {
            glyph
                .onDrag {
                    dragging = key
                    return NSItemProvider(object: key as NSString)
                }
                .help(L.t("Drag to reorder", "拖动以调整顺序"))
        } else {
            Color.clear.frame(width: 14, height: Metrics.avatar)
        }
    }

    private var normal: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(display.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
                if let subtitle = display.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                status
            }
            Spacer(minLength: 8)
            if hovering || forcedHover { actions }
            SwitchControl(isOn: Binding(
                get: { included ?? !row.slot.disabled },
                set: {
                    included = $0
                    model.setDisabled(provider, row.id, !$0)
                }),
                label: L.t("Take part in Next Account", "参与“下一个账号”"), small: true)
                .onChange(of: row.slot.disabled) { included = nil }
                .task(id: included) {
                    // If the edit did not take, fall back to what the list says.
                    guard included != nil else { return }
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { included = nil }
                }
                .help(row.slot.disabled
                    ? L.t("Next Account skips this account. Clicking it in the menu still switches.", "“下一个账号”会跳过它，在菜单里点击仍可切换。")
                    : L.t("Next Account includes this account.", "“下一个账号”会轮到它。"))
        }
    }

    private var status: some View {
        let s: (symbol: String, text: String, tint: Color?) = {
            if row.isCurrent {
                return ("checkmark.circle.fill", L.t("Signed in now", "当前登录"), .accentColor)
            }
            if !row.canSwitch {
                return ("circle.dashed", L.t("Sign in once to switch: choose Add Account in the menu", "登录一次后可切换：在菜单里点“添加账号…”"), nil)
            }
            if row.probablyExpired {
                return ("exclamationmark.circle", L.t("May have expired: \(app) may ask you to sign in again", "可能已过期：切换后 \(app) 可能要求重新登录"), .orange)
            }
            if let at = row.setAsideAt {
                return ("checkmark.circle", L.t("Can switch · sign-in saved \(L.ago(at))", "可切换 · 登录保存于\(L.ago(at))"), nil)
            }
            return ("checkmark.circle", L.t("Can switch", "可切换"), nil)
        }()
        return HStack(spacing: 4) {
            Image(systemName: s.symbol)
                .foregroundStyle(s.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            Text(s.text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.subheadline)
    }

    private var actions: some View {
        HStack(spacing: 0) {
            icon("pencil", L.t("Rename…", "设别名…")) {
                draftAlias = row.slot.alias ?? ""
                removing = nil
                renaming = key
            }
            icon("chevron.up", L.t("Move Up", "上移"), disabled: isFirst) { place(row.id, index - 1) }
            icon("chevron.down", L.t("Move Down", "下移"), disabled: isLast) { place(row.id, index + 1) }
            icon("trash", row.isCurrent
                ? L.t("This account is signed in. Switch to another one before removing it.", "这个账号正在登录中，先切换到其他账号再移除。")
                : L.t("Remove…", "移除…"), disabled: row.isCurrent) {
                renaming = nil
                removing = key
            }
        }
        .buttonStyle(QuietButtonStyle())
    }

    private func icon(_ symbol: String, _ name: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout.weight(.medium))
                .frame(width: Metrics.controlCompact, height: Metrics.controlCompact)
        }
        .disabled(disabled)
        .help(name)
        .accessibilityLabel(name)
    }

    @ViewBuilder private var menuItems: some View {
        Button(L.t("Rename…", "设别名…")) {
            draftAlias = row.slot.alias ?? ""
            removing = nil
            renaming = key
        }
        Divider()
        Button(L.t("Move Up", "上移")) { place(row.id, index - 1) }
            .disabled(isFirst)
        Button(L.t("Move Down", "下移")) { place(row.id, index + 1) }
            .disabled(isLast)
        Divider()
        Button(L.t("Remove…", "移除…"), role: .destructive) {
            renaming = nil
            removing = key
        }
        .disabled(row.isCurrent)
    }

    private var renameForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L.t("Set alias", "设置别名"))
                    .font(.body.weight(.semibold))
                if let email = model.displayEmail(row.slot.email) {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if staticRender {
                let shown = draftAlias.isEmpty ? (row.slot.alias ?? "") : draftAlias
                Text(shown.isEmpty ? L.t("e.g. work, personal", "例如：工作、个人") : shown)
                    .font(.body)
                    .foregroundStyle(shown.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Fill.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                TextField(L.t("e.g. work, personal", "例如：工作、个人"), text: $draftAlias)
                    .textFieldStyle(.roundedBorder)
                    .focused($aliasFocused)
                    .onSubmit { saveAlias() }
            }
            HStack(spacing: 6) {
                if row.slot.alias != nil {
                    Button(L.t("Clear", "清除")) {
                        model.setAlias(provider, row.id, nil)
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
        .padding(.top, 4)
        .onAppear {
            if draftAlias.isEmpty { draftAlias = row.slot.alias ?? "" }
            if !staticRender { aliasFocused = true }
        }
    }

    private func saveAlias() {
        let trimmed = draftAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setAlias(provider, row.id, trimmed.isEmpty ? nil : trimmed)
        renaming = nil
    }

    private var removeConfirm: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L.t("Remove \(display.title)?", "移除 \(display.title)？"))
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(L.removeExplained)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer()
                Button(L.t("Cancel", "取消")) { removing = nil }
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(L.t("Remove", "移除")) {
                    model.remove(provider, row.id)
                    removing = nil
                }
                .buttonStyle(SoftButtonStyle(kind: .destructive, compact: true))
            }
        }
        .padding(.top, 4)
    }
}

/// A row as the place to drop the dragged one.
private struct RowDrop: DropDelegate {
    let key: String
    let accepts: Bool
    @Binding var dragging: String?
    @Binding var target: String?
    let perform: () -> Void

    func validateDrop(info: DropInfo) -> Bool { accepts }

    func dropEntered(info: DropInfo) {
        if accepts { target = key }
    }

    func dropExited(info: DropInfo) {
        if target == key { target = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard accepts else { return false }
        perform()
        dragging = nil
        target = nil
        return true
    }
}

/// One terminal CLI account in Settings → Accounts.
struct CLIAccountSettingsRow: View {
    let model: AppModel
    let row: CLIRow
    let key: String
    @Binding var removing: String?
    @Binding var renaming: String?
    var forcedHover = false

    @State private var hovering = false
    @State private var draftAlias = ""
    @FocusState private var aliasFocused: Bool
    @Environment(\.staticRender) private var staticRender

    private var display: (title: String, subtitle: String?) { model.displayCLILabel(row) }
    private var showActions: Bool { (hovering || forcedHover) && removing == nil && renaming == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(row.number)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, minHeight: Metrics.avatar)
                .accessibilityLabel(L.t("Number \(row.number)", "编号 \(row.number)"))
            Avatar(label: "\(row.number)", seed: row.email ?? row.id)
            Group {
                if removing == key {
                    removeConfirm
                } else if renaming == key {
                    renameForm
                } else {
                    normal
                }
            }
            .frame(minHeight: Metrics.avatar)
        }
        .padding(.horizontal, Metrics.cardPad)
        .padding(.vertical, 9)
        .background(hovering || forcedHover ? Fill.hover.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    private var normal: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(display.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if let plan = row.plan, !plan.isEmpty {
                        Tag(text: plan.prefix(1).uppercased() + plan.dropFirst())
                    }
                    if row.isDefault {
                        Tag(text: L.t("Default", "默认"))
                    }
                }
                if let subtitle = display.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                status
            }
            Spacer(minLength: 8)
            if showActions {
                actions
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
            } else if row.signIn.isGood {
                Button(L.t("Use", "选用")) { model.useCLI(row) }
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .fixedSize()
            } else {
                Button(L.t("Sign In…", "登录…")) { model.signInCLI(row) }
                    .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch row.signIn {
        case .good(let until):
            if let until {
                let days = Int((until.timeIntervalSinceNow / 86400).rounded(.up))
                if days <= 0 {
                    Label(L.t("Sign-in expired", "登录已失效"), systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else if days < 5 {
                    Label(days == 1 ? L.t("Runs out in 1 day", "1 天后失效") : L.t("Runs out in \(days) days", "\(days) 天后失效"),
                          systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else {
                    Text(L.t("Sign-in good until \(L.day(until))", "登录有效至 \(L.day(until))"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L.t("Signed in", "已登录"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .other(let mode):
            Text(L.t("Signed in with \(mode)", "通过 \(mode) 登录"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .out:
            Text(L.t("Not signed in", "未登录"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            icon("pencil", L.t("Rename…", "设别名…")) {
                draftAlias = row.alias ?? ""
                removing = nil
                renaming = key
            }
            if row.signIn.isGood {
                icon("terminal", L.t("Open Terminal as This Account", "用此账号打开终端")) {
                    model.openTerminalForCLI(row)
                }
            }
            icon("trash", row.isDefault
                ? L.t("The default folder stays. Sign out inside the CLI itself.", "默认文件夹无法移除，可在 CLI 内自行退出登录。")
                : L.t("Remove…", "移除…"), disabled: row.isDefault) {
                renaming = nil
                removing = key
            }
        }
    }

    private func icon(_ symbol: String, _ help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder private var menuItems: some View {
        Button(L.t("Rename…", "设别名…")) {
            draftAlias = row.alias ?? ""
            removing = nil
            renaming = key
        }
        if row.signIn.isGood {
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
        Divider()
        Button(L.t("Remove…", "移除…"), role: .destructive) {
            renaming = nil
            removing = key
        }
        .disabled(row.isDefault)
    }

    private var renameForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L.t("Set alias", "设置别名"))
                    .font(.body.weight(.semibold))
                Text(model.displayEmail(row.email) ?? (row.isDefault ? L.t("default", "默认") : row.name))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .padding(.top, 4)
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
            VStack(alignment: .leading, spacing: 3) {
                Text(L.t("Remove \(display.title)?", "移除 \(display.title)？"))
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(L.cliRemoveExplained(row.kind))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .padding(.top, 4)
    }
}

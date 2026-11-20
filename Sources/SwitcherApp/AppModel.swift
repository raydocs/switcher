import AppKit
import ServiceManagement
import Foundation
import Observation
import SwitcherCore

/// What a switch in progress is doing, for the progress view.
enum SwitchPhase: Equatable {
    case quitting(app: String, waited: Int)
    case swapping
    case opening(app: String)
}

struct SwitchJob: Equatable {
    var provider: ProviderID
    /// nil: adding an account (the app opens signed out).
    var target: String?
    var targetLabel: String?
    var phase: SwitchPhase
}

struct Banner: Equatable, Identifiable {
    enum Kind { case success, error, info }
    var id = UUID()
    var kind: Kind
    var text: String
}

/// The 4 managed tools (2 desktop apps + 2 terminal CLIs).
enum ToolID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case claude
    case antigravity
    case claudeCode
    case codex

    var id: String { rawValue }

    var desktopProvider: ProviderID? {
        switch self {
        case .claude: .claude
        case .antigravity: .antigravity
        case .claudeCode, .codex: nil
        }
    }

    var cliKind: CLIKind? {
        switch self {
        case .claudeCode: .claude
        case .codex: .codex
        case .claude, .antigravity: nil
        }
    }

    var displayName: String {
        switch self {
        case .claude: ProviderID.claude.displayName
        case .antigravity: ProviderID.antigravity.displayName
        case .claudeCode: CLIKind.claude.displayName
        case .codex: CLIKind.codex.displayName
        }
    }

    var symbol: String {
        switch self {
        case .claude: ProviderID.claude.symbol
        case .antigravity: ProviderID.antigravity.symbol
        case .claudeCode: "terminal"
        case .codex: "chevron.right.square"
        }
    }
}

/// Unified top tabs in the popover: Overview plus each visible desktop or CLI tool.
enum MenuTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview
    case claude
    case antigravity
    case claudeCode
    case codex

    var id: String { rawValue }

    var tool: ToolID? {
        switch self {
        case .overview: nil
        case .claude: .claude
        case .antigravity: .antigravity
        case .claudeCode: .claudeCode
        case .codex: .codex
        }
    }

    init(_ tool: ToolID) {
        switch tool {
        case .claude: self = .claude
        case .antigravity: self = .antigravity
        case .claudeCode: self = .claudeCode
        case .codex: self = .codex
        }
    }

    init(_ provider: ProviderID) {
        switch provider {
        case .claude: self = .claude
        case .antigravity: self = .antigravity
        }
    }

    init(_ kind: CLIKind) {
        switch kind {
        case .claude: self = .claudeCode
        case .codex: self = .codex
        }
    }

    var title: String {
        switch self {
        case .overview: L.t("Overview", "概览")
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .claude: ToolID.claude.symbol
        case .antigravity: ToolID.antigravity.symbol
        case .claudeCode: ToolID.claudeCode.symbol
        case .codex: ToolID.codex.symbol
        }
    }
}

/// Snapshot of shell shims and rc files for Settings → Terminal & Doctor.
struct TerminalSetupStatus: Equatable, Sendable {
    struct ShimInfo: Equatable, Sendable, Identifiable {
        var kind: CLIKind
        var shimInstalled: Bool
        var realBinary: String?
        var id: String { kind.rawValue }
    }

    struct RCInfo: Equatable, Sendable, Identifiable {
        var path: String
        var state: CLIShim.RCState
        var id: String { path }
    }

    var shims: [ShimInfo]
    var rcFiles: [RCInfo]
}

/// The app's state over SwitcherCore. Every call into the core that can block (quitting an app,
/// moving files, the keychain) runs off the main thread; results come back here.
@MainActor
@Observable
final class AppModel {
    static let hideEmailsKey = "hideEmails"
    static let selectedTabKey = "selectedMenuTab"
    static let hiddenToolsKey = "hiddenTools"

    private(set) var boards: [AppBoard] = []
    /// Parallel Antigravity sandboxes (independent App windows & concurrent `agy` CLI profiles).
    private(set) var sandboxes: [AntigravitySandbox] = []
    /// Names of sandboxes currently launching, stopping, or healing.
    private(set) var sandboxBusy: Set<String> = []
    private(set) var job: SwitchJob?
    private(set) var ccSame: CCSameImport.Found?
    /// Claude Code and Codex in the terminal: their accounts, apart from the desktop apps.
    private(set) var cliBoards: [CLIBoard] = []
    /// The CLIs whose usage is being read, and the accounts whose sign-in is being renewed.
    private(set) var cliReading: Set<CLIKind> = []
    private(set) var cliRenewing: Set<String> = []
    /// A sign-in running in the background (the browser is open), per CLI: the account's name.
    private(set) var cliSigningIn: [CLIKind: String] = [:]
    /// True once "Install" has run here: what is left is to open a new terminal.
    private(set) var cliJustInstalled = false
    private(set) var readingQuotas = false
    static let notifyQuotaWarningKey = "notifyQuotaWarning"
    static let notifyQuotaResetKey = "notifyQuotaReset"
    static let notifySignInExpiryKey = "notifySignInExpiry"

    /// Terminal setup and Doctor results for Settings → Terminal & Doctor.
    private(set) var terminalStatus: TerminalSetupStatus?
    private(set) var doctorFindings: [DoctorFinding] = []
    private(set) var runningDoctor = false
    private(set) var doctorLastRun: Date?
    /// Manual GitHub Release update check state in Settings → About.
    private(set) var checkingUpdate = false
    private(set) var updateResult: UpdateCheckResult?
    var banner: Banner?
    /// The active tab in the unified popover switcher.
    var selectedTab: MenuTab = .claude {
        didSet {
            guard oldValue != selectedTab, !isPreview else { return }
            UserDefaults.standard.set(selectedTab.rawValue, forKey: Self.selectedTabKey)
            if let kind = selectedTab.tool?.cliKind {
                loadCLIQuota(kind)
            }
        }
    }
    /// Display language preference, synced with `UserDefaults.standard` and observed by views.
    var language: AppLanguage = .system {
        didSet {
            guard oldValue != language, !isPreview else { return }
            UserDefaults.standard.set(language.rawValue, forKey: L10n.settingKey)
        }
    }
    /// Privacy mode: masks email addresses in the UI for screenshots and screen sharing.
    var hideEmails: Bool = false {
        didSet {
            guard oldValue != hideEmails, !isPreview else { return }
            UserDefaults.standard.set(hideEmails, forKey: Self.hideEmailsKey)
        }
    }
    /// Whether quota meters display used % or remaining %.
    var quotaDisplayMode: QuotaDisplayMode = .used {
        didSet {
            guard oldValue != quotaDisplayMode, !isPreview else { return }
            UserDefaults.standard.set(quotaDisplayMode.rawValue, forKey: QuotaDisplayMode.settingKey)
        }
    }
    /// How the menu bar icon renders: classic icon, dual bars, or dual bars + compact percentage.
    var menuBarStyle: MenuBarStyle = .bars {
        didSet {
            guard oldValue != menuBarStyle, !isPreview else { return }
            UserDefaults.standard.set(menuBarStyle.rawValue, forKey: MenuBarStyle.settingKey)
            UserDefaults.standard.set(menuBarStyle != .icon, forKey: MenuBarLabel.settingKey)
        }
    }
    /// Which tool drives the menu bar meter (Auto across Antigravity + Claude Code + Codex, or pinned).
    var menuBarSource: MenuBarSource = .auto {
        didSet {
            guard oldValue != menuBarSource, !isPreview else { return }
            UserDefaults.standard.set(menuBarSource.rawValue, forKey: MenuBarSource.settingKey)
        }
    }
    /// Proactive local notifications (only delivered inside a `.app` bundle).
    var notifyQuotaWarning: Bool = true {
        didSet {
            guard oldValue != notifyQuotaWarning, !isPreview else { return }
            UserDefaults.standard.set(notifyQuotaWarning, forKey: Self.notifyQuotaWarningKey)
            if notifyQuotaWarning { NotificationBridge.requestAuthorizationIfNeeded() }
        }
    }
    var notifyQuotaReset: Bool = true {
        didSet {
            guard oldValue != notifyQuotaReset, !isPreview else { return }
            UserDefaults.standard.set(notifyQuotaReset, forKey: Self.notifyQuotaResetKey)
            if notifyQuotaReset { NotificationBridge.requestAuthorizationIfNeeded() }
        }
    }
    var notifySignInExpiry: Bool = true {
        didSet {
            guard oldValue != notifySignInExpiry, !isPreview else { return }
            UserDefaults.standard.set(notifySignInExpiry, forKey: Self.notifySignInExpiryKey)
            if notifySignInExpiry { NotificationBridge.requestAuthorizationIfNeeded() }
        }
    }
    /// Global hotkey to summon/dismiss the popover from any app (Carbon, zero Accessibility needed).
    var globalHotkey: GlobalHotkeyPreset = .off {
        didSet {
            guard oldValue != globalHotkey, !isPreview else { return }
            UserDefaults.standard.set(globalHotkey.rawValue, forKey: GlobalHotkeyPreset.settingKey)
            hotkeyController.apply(globalHotkey)
        }
    }
    /// Tools explicitly hidden from the popover tab bar by the user.
    var hiddenTools: Set<ToolID> = [] {
        didSet {
            guard oldValue != hiddenTools, !isPreview else { return }
            let raw = ToolID.allCases.filter(hiddenTools.contains).map(\.rawValue).joined(separator: ",")
            UserDefaults.standard.set(raw, forKey: Self.hiddenToolsKey)
        }
    }

    @ObservationIgnored let board: Switchboard
    @ObservationIgnored private let queue = DispatchQueue(label: "switcher.core", qos: .userInitiated)
    @ObservationIgnored private var cancel: CancelToken?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isPreview = false
    @ObservationIgnored private let cli: CLIProfiles
    @ObservationIgnored private let cliKeychain: CLIKeychain
    @ObservationIgnored private var cliQuotaErrors: [String: CLIQuotaError] = [:]
    @ObservationIgnored private var cliQuotaReadAt: [CLIKind: Date] = [:]
    @ObservationIgnored private var cliLoginRuns: [CLIKind: CLILoginRun] = [:]
    @ObservationIgnored private var cliCancelled: Set<CLIKind> = []
    /// Per account id: when its usage was last read (or tried) and how many reads in a row failed.
    @ObservationIgnored private var cliAttempt: [String: Date] = [:]
    @ObservationIgnored private var cliFailures: [String: Int] = [:]
    /// A sign-in moved to Terminal: the account and its command, opened once the background run ends.
    @ObservationIgnored private var cliHandoff: [CLIKind: (name: String, command: String)] = [:]
    @ObservationIgnored private var usageScheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private let hotkeyController = GlobalHotkeyController()

    /// Fixed data for previews and screenshots: touches nothing on disk.
    init(preview boards: [AppBoard], sandboxes: [AntigravitySandbox] = [], ccSame: CCSameImport.Found? = nil, job: SwitchJob? = nil, banner: Banner? = nil,
         cli cliBoards: [CLIBoard] = [], cliJustInstalled: Bool = false, hideEmails: Bool = false,
         selectedTab: MenuTab = .claude, quotaDisplayMode: QuotaDisplayMode = .used,
         menuBarStyle: MenuBarStyle = .bars, menuBarSource: MenuBarSource = .auto,
         globalHotkey: GlobalHotkeyPreset = .off, updateResult: UpdateCheckResult? = nil,
         hiddenTools: Set<ToolID> = [], terminalStatus: TerminalSetupStatus? = nil,
         doctorFindings: [DoctorFinding] = []) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-preview", isDirectory: true)
        let env = Env(home: home)
        self.cli = CLIProfiles(env: CLIEnv(home: home.path))
        self.cliKeychain = MemoryCLIKeychain()
        self.cliBoards = cliBoards
        self.cliJustInstalled = cliJustInstalled
        self.board = Switchboard(
            env: env,
            claude: .claude(env: env, app: FakeApp(), keychain: MemorySecrets()),
            antigravity: .antigravity(env: env, app: FakeApp(), keychain: MemorySecrets()),
            sandboxes: AntigravitySandboxes(env: env, processControl: FakeSandboxProcessControl())
        )
        self.boards = boards
        self.sandboxes = sandboxes
        self.ccSame = ccSame
        self.job = job
        self.banner = banner
        self.isPreview = true
        self.language = L10n.language
        self.hideEmails = hideEmails
        self.quotaDisplayMode = quotaDisplayMode
        self.menuBarStyle = menuBarStyle
        self.menuBarSource = menuBarSource
        self.globalHotkey = globalHotkey
        self.updateResult = updateResult
        self.hiddenTools = hiddenTools
        self.selectedTab = selectedTab
        self.terminalStatus = terminalStatus
        self.doctorFindings = doctorFindings
        if !doctorFindings.isEmpty { self.doctorLastRun = Date() }
    }

    init(board: Switchboard = Switchboard()) {
        self.board = board
        self.cli = CLIProfiles(env: .live)
        self.cliKeychain = LiveCLIKeychain()
        self.language = L10n.language
        let defaults = UserDefaults.standard
        self.hideEmails = defaults.bool(forKey: Self.hideEmailsKey)
        if let raw = defaults.string(forKey: QuotaDisplayMode.settingKey),
           let mode = QuotaDisplayMode(rawValue: raw) {
            self.quotaDisplayMode = mode
        }
        if let raw = defaults.string(forKey: MenuBarStyle.settingKey),
           let style = MenuBarStyle(rawValue: raw) {
            self.menuBarStyle = style
        } else if defaults.object(forKey: MenuBarLabel.settingKey) != nil {
            self.menuBarStyle = defaults.bool(forKey: MenuBarLabel.settingKey) ? .bars : .icon
        }
        if let raw = defaults.string(forKey: MenuBarSource.settingKey),
           let source = MenuBarSource(rawValue: raw) {
            self.menuBarSource = source
        }
        if defaults.object(forKey: Self.notifyQuotaWarningKey) != nil {
            self.notifyQuotaWarning = defaults.bool(forKey: Self.notifyQuotaWarningKey)
        }
        if defaults.object(forKey: Self.notifyQuotaResetKey) != nil {
            self.notifyQuotaReset = defaults.bool(forKey: Self.notifyQuotaResetKey)
        }
        if defaults.object(forKey: Self.notifySignInExpiryKey) != nil {
            self.notifySignInExpiry = defaults.bool(forKey: Self.notifySignInExpiryKey)
        }
        if let raw = defaults.string(forKey: GlobalHotkeyPreset.settingKey),
           let preset = GlobalHotkeyPreset(rawValue: raw) {
            self.globalHotkey = preset
        }
        if let raw = defaults.string(forKey: Self.hiddenToolsKey) {
            self.hiddenTools = Set(raw.split(separator: ",").compactMap { ToolID(rawValue: String($0)) })
        }
        if let raw = defaults.string(forKey: Self.selectedTabKey),
           let tab = MenuTab(rawValue: raw) {
            self.selectedTab = tab
        }
        if self.globalHotkey != .off {
            self.hotkeyController.apply(self.globalHotkey)
        }
        if self.notifyQuotaWarning || self.notifyQuotaReset || self.notifySignInExpiry {
            NotificationBridge.requestAuthorizationIfNeeded()
        }
        queue.async { board.recoverIfIdle() }
        refresh()
        refreshCLI()
        startUsageRefresh()
    }

    @ObservationIgnored private var surfacesShown = 0

    /// The menu or the Settings window opened: re-read now, and every 15 seconds while one is open.
    /// While both are closed nothing shows the apps' state, so nothing re-reads it (the timer scans
    /// every process, so it is not left running for nobody).
    func surfaceAppeared() {
        surfacesShown += 1
        refresh()
        guard timer == nil, !isPreview else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Let the system fold this wake-up into others.
        timer?.tolerance = 5
    }

    func surfaceDisappeared() {
        surfacesShown = max(0, surfacesShown - 1)
        guard surfacesShown == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Keep the active CLI accounts' usage current while the menu is closed, at the least cost:
    /// the system schedules the check (it defers it on battery, when hot or busy), the check itself
    /// is a few `stat`s, and a read (a request, or a `codex app-server` process) happens only when
    /// `CLIRefreshPlan` says the numbers can have changed. Nothing runs while the screens sleep.
    private func startUsageRefresh() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "dev.switcher.app.cli-usage")
        scheduler.repeats = true
        scheduler.interval = CLIRefreshPlan.minSpacing
        scheduler.tolerance = CLIRefreshPlan.minSpacing / 2
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] done in
            Task { @MainActor in self?.backgroundUsageCheck() }
            done(.finished)
        }
        usageScheduler = scheduler
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensAsleep = true }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensAsleep = false }
        }
    }

    private func backgroundUsageCheck() {
        if isPreview || screensAsleep || cliBoards.isEmpty { return }
        let env = cli.env, boards = cliBoards, attempts = cliAttempt, failures = cliFailures
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        Task.detached(priority: .utility) {
            let now = Date()
            var due: [(CLIKind, [String])] = []
            for b in boards where b.commandFound {
                let states = b.rows.map {
                    CLIRefreshState(id: $0.id, isActive: $0.isActive, signedIn: $0.signIn.isGood, observedAt: $0.quota?.observedAt,
                                    lastAttempt: attempts[$0.id], failures: failures[$0.id] ?? 0)
                }
                let ids = Set(CLIRefreshPlan.due(states, activeStatus: b.active?.headroom.status ?? .unknown,
                                                 lastActivity: CLIUsage.lastActivity(b.kind, env: env, now: now), lowPower: lowPower, now: now))
                let names = b.rows.filter { ids.contains($0.id) }.map(\.name)
                if !names.isEmpty { due.append((b.kind, names)) }
            }
            let plan = due
            await MainActor.run { for (kind, names) in plan { self.loadCLIQuota(kind, only: names) } }
        }
    }

    func board(_ p: ProviderID) -> AppBoard? { boards.first { $0.provider == p } }

    var isBusy: Bool { job != nil }
    var isRefreshing: Bool { readingQuotas || !cliReading.isEmpty }

    // MARK: Visible tools & unified tab navigation

    func isToolVisible(_ tool: ToolID) -> Bool {
        if hiddenTools.contains(tool) { return false }
        if let kind = tool.cliKind {
            return cliBoard(kind).map { !$0.isAbsent } ?? false
        }
        return true
    }

    var visibleTools: [ToolID] {
        let shown = ToolID.allCases.filter(isToolVisible)
        return shown.isEmpty ? [.claude] : shown
    }

    var visibleTabs: [MenuTab] {
        let tools = visibleTools
        return tools.count > 1 ? ([.overview] + tools.map(MenuTab.init)) : tools.map(MenuTab.init)
    }

    /// Ensures `selectedTab` always refers to a currently visible tab.
    var activeTab: MenuTab {
        let tabs = visibleTabs
        if tabs.contains(selectedTab) { return selectedTab }
        return tabs.first ?? .claude
    }

    func toggleToolVisibility(_ tool: ToolID, visible: Bool) {
        if visible {
            hiddenTools.remove(tool)
        } else {
            let currentlyVisible = ToolID.allCases.filter { !hiddenTools.contains($0) && ($0.cliKind == nil || (cliBoard($0.cliKind!).map { !$0.isAbsent } ?? false)) }
            guard currentlyVisible.count > 1 else { return }
            hiddenTools.insert(tool)
            if selectedTab.tool == tool {
                selectedTab = visibleTabs.first ?? .claude
            }
        }
    }

    func stepTab(delta: Int) {
        let tabs = visibleTabs
        guard tabs.count > 1, let idx = tabs.firstIndex(of: activeTab) else { return }
        let next = (idx + delta % tabs.count + tabs.count) % tabs.count
        selectedTab = tabs[next]
    }

    /// The Antigravity account with the most remaining room when the active account is low or exhausted.
    var bestAntigravityAccount: String? {
        guard let board = board(.antigravity),
              let current = board.currentRow?.quota else { return nil }
        let status = current.status()
        guard status == .low || status == .out else { return nil }
        let others = board.rows.filter { !$0.isCurrent && $0.canSwitch && !$0.slot.disabled }
        return AntigravityQuota.bestAccount(others.map { ($0.id, $0.quota) })
    }

    /// Reference usage from a signed-in Claude Code CLI account sharing the exact same email (within 2h).
    func matchingCLIQuota(forDesktopEmail email: String?) -> CLIQuota? {
        guard let email = email?.lowercased(), !email.isEmpty,
              let claudeCLI = cliBoard(.claude) else { return nil }
        let now = Date()
        for row in claudeCLI.rows where row.signIn.isGood {
            guard row.email?.lowercased() == email,
                  let quota = row.quota,
                  !quota.windows.isEmpty,
                  now.timeIntervalSince(quota.observedAt) < 2 * 3600 else { continue }
            return quota
        }
        return nil
    }

    // MARK: Display helpers (aliases & privacy mode)

    func displayEmail(_ email: String?) -> String? {
        Privacy.displayEmail(email, masked: hideEmails)
    }

    func displayLabel(_ slot: Slot) -> (title: String, subtitle: String?) {
        if let alias = slot.alias, !alias.isEmpty {
            return (alias, displayEmail(slot.email))
        }
        if let email = displayEmail(slot.email) {
            return (email, nil)
        }
        return (slot.label, nil)
    }

    func displayTabLabel(_ slot: Slot) -> String {
        displayLabel(slot).title
    }

    func displayCLILabel(_ row: CLIRow) -> (title: String, subtitle: String?) {
        let folderTag = row.isDefault ? L.t("default", "默认") : row.name
        let shownEmail = displayEmail(row.email)
        if let alias = row.alias, !alias.isEmpty {
            let showFolder = alias.lowercased() != row.name.lowercased() && (!row.isDefault || alias.lowercased() != folderTag.lowercased())
            if let shownEmail {
                return (alias, showFolder ? "\(shownEmail) · \(folderTag)" : shownEmail)
            }
            return (alias, showFolder ? folderTag : nil)
        }
        if let shownEmail {
            return (shownEmail, folderTag)
        }
        return (row.name, nil)
    }

    func displayCLIActiveLabel(_ row: CLIRow) -> String {
        displayCLILabel(row).title
    }

    var runningSandboxCount: Int { sandboxes.filter(\.running).count }

    func displaySandboxLabel(_ sandbox: AntigravitySandbox) -> (title: String, subtitle: String?) {
        let shownEmail = displayEmail(sandbox.email)
        if let alias = sandbox.alias, !alias.isEmpty {
            let showFolder = alias.lowercased() != sandbox.name.lowercased()
            if let shownEmail {
                return (alias, showFolder ? "\(shownEmail) · \(sandbox.name)" : shownEmail)
            }
            return (alias, showFolder ? sandbox.name : nil)
        }
        return (sandbox.name, shownEmail)
    }

    func suggestedSandboxName() -> String {
        let taken = Set(sandboxes.map { $0.name.lowercased() })
        var n = 2
        while taken.contains("acc\(n)") { n += 1 }
        return "acc\(n)"
    }

    /// Re-read every app. Cheap: run when the menu opens and every 15 seconds while it is open.
    func refresh() {
        if isPreview { return }
        let board = self.board
        queue.async {
            let boards = board.board()
            let sandboxes = board.sandboxBoard()
            let found = board.ccSameImport()
            Task { @MainActor in
                // Assign only what changed, so a quiet 15-second tick redraws nothing.
                if self.boards != boards { self.boards = boards }
                if self.sandboxes != sandboxes { self.sandboxes = sandboxes }
                if self.ccSame != found { self.ccSame = found }
                self.refreshQuotasIfDue()
            }
        }
    }

    /// Force-refresh desktop state, Antigravity quotas, and CLI accounts/quotas now.
    func refreshAllNow() {
        if isPreview { return }
        refresh()
        refreshQuotasIfDue(force: true)
        let cli = self.cli, keychain = self.cliKeychain
        queue.async {
            let boards = Self.readCLI(cli, keychain)
            Task { @MainActor in
                self.setCLI(boards)
                for b in boards where b.commandFound {
                    self.loadCLIQuota(b.kind, force: true)
                }
            }
        }
    }

    @ObservationIgnored private var quotasReadAt: Date?

    /// Antigravity quotas come from Google: read them at most every 5 minutes (sooner with `force`).
    func refreshQuotasIfDue(force: Bool = false) {
        if isPreview || readingQuotas { return }
        if !force, let at = quotasReadAt, Date().timeIntervalSince(at) < 300 { return }
        readingQuotas = true
        let board = self.board
        Task.detached {
            await board.refreshAntigravityUsage()
            let boards = board.board()
            let sandboxes = board.sandboxBoard()
            await MainActor.run {
                self.readingQuotas = false
                self.quotasReadAt = Date()
                if self.boards != boards { self.boards = boards }
                if self.sandboxes != sandboxes { self.sandboxes = sandboxes }
                self.evaluateAlerts()
            }
        }
    }

    /// Switch `p` to `row`'s account.
    func switchTo(_ p: ProviderID, _ row: AccountRow) {
        guard !row.isCurrent, row.canSwitch else { return }
        start(p, target: row.slot.account, label: displayLabel(row.slot).title)
    }

    func next(_ p: ProviderID) {
        guard job == nil, !isPreview else { return }
        let board = self.board
        // Reading who is signed in asks the keychain: keep it off the main thread.
        queue.async {
            let slot = board.nextAccount(p)
            Task { @MainActor in
                guard let slot else {
                    self.banner = Banner(kind: .info, text: L.noOtherAccount(p.displayName))
                    return
                }
                self.start(p, target: slot.account, label: self.displayLabel(slot).title)
            }
        }
    }

    /// Restart the app signed out so the user can sign in to another account.
    func addAccount(_ p: ProviderID) { start(p, target: nil, label: nil) }

    func cancelSwitch() { cancel?.cancel() }

    // MARK: Settings

    /// Open at login, through the system's login items.
    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                banner = Banner(kind: .error, text: error.localizedDescription)
            }
        }
    }

    private func start(_ p: ProviderID, target: String?, label: String?) {
        guard job == nil, !isPreview else { return }
        let token = CancelToken()
        cancel = token
        let name = board.provider(p).app.name
        let initial: SwitchPhase = (board(p)?.running == true) ? .quitting(app: name, waited: 0) : .swapping
        job = SwitchJob(provider: p, target: target, targetLabel: label, phase: initial)
        let board = self.board
        queue.async {
            let result: Result<SwitchResult, Error>
            do {
                let r = try board.switchTo(p, account: target, alwaysLaunch: true, cancel: token, phase: { stage in
                    let mapped: SwitchPhase
                    switch stage {
                    case .quitting: mapped = .quitting(app: name, waited: 0)
                    case .swapping: mapped = .swapping
                    case .opening: mapped = .opening(app: name)
                    }
                    Task { @MainActor in self.job?.phase = mapped }
                }, waiting: { waited in
                    Task { @MainActor in self.job?.phase = .quitting(app: name, waited: Int(waited)) }
                })
                result = .success(r)
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in
                self.job = nil
                self.cancel = nil
                switch result {
                case .success:
                    self.banner = Banner(kind: .success, text: target == nil ? L.signInToAdd(name) : L.switched(name, label ?? ""))
                case .failure(let error):
                    if (error as? QuitError) == .cancelled {
                        self.banner = Banner(kind: .info, text: L.switchCancelled(name))
                    } else {
                        self.banner = Banner(kind: .error, text: error.localizedDescription)
                    }
                }
                self.refresh()
            }
        }
    }

    // MARK: Claude Code and Codex in the terminal

    func cliBoard(_ kind: CLIKind) -> CLIBoard? { cliBoards.first { $0.kind == kind } }

    /// Re-read the CLI accounts (folders, pointers, who is signed in). Run when the popover opens and
    /// after each action, not on the timer: it asks the keychain once per Claude Code account.
    /// `quotaFor`: the CLIs whose usage is read afterwards, if it is due.
    func refreshCLI(quotaFor kinds: Set<CLIKind> = []) {
        if isPreview { return }
        let cli = self.cli, keychain = self.cliKeychain
        queue.async {
            let boards = Self.readCLI(cli, keychain)
            Task { @MainActor in
                self.setCLI(boards)
                for kind in CLIKind.allCases where kinds.contains(kind) { self.loadCLIQuota(kind) }
            }
        }
    }

    private func setCLI(_ read: [CLIBoard]) {
        var boards = read
        for b in boards.indices {
            for r in boards[b].rows.indices { boards[b].rows[r].quotaError = cliQuotaErrors[boards[b].rows[r].id] }
        }
        if cliBoards != boards { cliBoards = boards }
        evaluateAlerts()
    }

    // MARK: Proactive alerts & manual release check

    /// Evaluates active accounts' quota and sign-in expiry against `AlertLedger` and delivers new local
    /// notifications (only when running inside a `.app` bundle and at least one alert toggle is on).
    private func evaluateAlerts() {
        guard !isPreview, NotificationBridge.isBundledApp else { return }
        let prefs = AlertPreferences(
            quotaWarning: notifyQuotaWarning,
            quotaReset: notifyQuotaReset,
            signInExpiry: notifySignInExpiry
        )
        guard prefs.quotaWarning || prefs.quotaReset || prefs.signInExpiry else { return }

        let now = Date()
        var windowSamples: [AlertWindowSample] = []
        var expirySamples: [AlertExpirySample] = []

        // Active Antigravity account windows + saved sign-ins approaching 28 days.
        if let ag = board(.antigravity) {
            let bestLabel: String? = bestAntigravityAccount.flatMap { bestID in
                ag.rows.first(where: { $0.id == bestID }).map { displayTabLabel($0.slot) }
            }
            if let cur = ag.currentRow, let quota = cur.quota {
                let label = displayLabel(cur.slot).title
                for bucket in quota.buckets where bucket.pool.isCore {
                    if let reset = bucket.resetsAt, reset <= now { continue }
                    windowSamples.append(AlertWindowSample(
                        tool: "Antigravity",
                        accountID: cur.id,
                        accountLabel: label,
                        windowLabel: L.poolName(bucket.pool),
                        usedPercent: bucket.used,
                        resetsAt: bucket.resetsAt,
                        bestFallback: bestLabel
                    ))
                }
            }
        }

        // Desktop saved sign-ins aged >= 25 days.
        for b in boards {
            for row in b.rows where !row.isCurrent && row.canSwitch && !row.probablyExpired {
                guard let savedAt = row.setAsideAt else { continue }
                let ageDays = Int(now.timeIntervalSince(savedAt) / 86_400)
                if ageDays >= 25 {
                    expirySamples.append(AlertExpirySample(
                        kind: .desktopSaved,
                        tool: b.provider.displayName,
                        accountID: row.id,
                        accountLabel: displayLabel(row.slot).title,
                        daysLeft: max(0, 28 - ageDays),
                        stamp: Int(savedAt.timeIntervalSince1970)
                    ))
                }
            }
        }

        // Active CLI accounts' main windows + expiring CLI refresh tokens.
        for b in cliBoards where !b.isAbsent {
            let bestLabel = b.rows.first(where: \.isBest).map { displayCLIActiveLabel($0) }
            if let active = b.active, active.signIn.isGood, let quota = active.quota {
                let label = displayCLIActiveLabel(active)
                for w in quota.windows where CLIUsage.isMain(w) {
                    windowSamples.append(AlertWindowSample(
                        tool: b.kind.displayName,
                        accountID: active.id,
                        accountLabel: label,
                        windowLabel: L.cliWindow(w.label),
                        usedPercent: Int(w.usedPercent.rounded()),
                        resetsAt: w.resetsAt,
                        bestFallback: bestLabel
                    ))
                }
            }
            for row in b.rows {
                if case .good(let until?) = row.signIn {
                    let daysLeft = Int((until.timeIntervalSince(now) / 86_400).rounded(.up))
                    if daysLeft <= 4 {
                        expirySamples.append(AlertExpirySample(
                            kind: .cliRefresh,
                            tool: b.kind.displayName,
                            accountID: row.id,
                            accountLabel: displayCLIActiveLabel(row),
                            daysLeft: daysLeft,
                            stamp: Int(until.timeIntervalSince1970)
                        ))
                    }
                }
            }
        }

        let env = board.env
        let wSamples = windowSamples
        let eSamples = expirySamples
        queue.async {
            var ledger = AlertLedger.load(env)
            let before = ledger
            let events = AlertEngine.evaluate(
                windows: wSamples,
                expiries: eSamples,
                preferences: prefs,
                ledger: &ledger,
                now: now
            )
            if ledger != before { try? ledger.save(env) }
            if !events.isEmpty {
                Task { @MainActor in NotificationBridge.deliver(events) }
            }
        }
    }

    /// Manually check GitHub Releases for a newer Switcher version (never runs automatically).
    func checkForUpdates() {
        guard !isPreview, !checkingUpdate else { return }
        checkingUpdate = true
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        Task.detached(priority: .userInitiated) {
            let result = await UpdateChecker.check(currentVersion: current)
            await MainActor.run {
                self.checkingUpdate = false
                self.updateResult = result
            }
        }
    }

    private nonisolated static func readCLI(_ cli: CLIProfiles, _ keychain: CLIKeychain) -> [CLIBoard] {
        let cache = CLIQuotaCache(env: cli.env).snapshot()
        let groups = Dictionary(uniqueKeysWithValues: CLICommands.list(cli, keychain: keychain).map { ($0.cli, $0) })
        let now = Date()
        return CLIKind.allCases.compactMap { kind -> CLIBoard? in
            let activity = CLIUsage.lastActivity(kind, env: cli.env, now: now)
            guard let group = groups[kind.rawValue] else { return nil }
            let listed = cli.list(kind)
            let loginCommands = Dictionary(listed.map { ($0.path, kind.loginCommand($0)) }) { a, _ in a }
            let launchCommands = Dictionary(listed.map { ($0.path, kind.launchCommand($0)) }) { a, _ in a }
            // A cached quota counts only for the account the profile is signed in to now.
            let cached = Dictionary(listed.map { p in (p.id, cache.quota(for: p, accountKey: cli.identity(p)?.accountKey)) }) { a, _ in a }
            var rows = group.profiles.map { e -> CLIRow in
                let signIn: CLIRow.SignIn
                switch e.signIn {
                case "signedIn": signIn = .good(until: e.signInGoodUntil)
                case "other": signIn = .other(e.signInMode ?? "")
                default: signIn = .out
                }
                let id = "\(kind.rawValue):\(e.name)"
                // A window that reset since the reading shows 0 % (or goes) instead of the old number.
                var quota = signIn == .out ? nil : cached[id] ?? nil
                if let read = quota { quota?.windows = CLIUsage.current(read, now: now, lastActivity: activity) }
                return CLIRow(kind: kind, number: e.number, name: e.name, alias: e.alias, isDefault: e.isDefault, isActive: e.active,
                              email: e.email, plan: e.plan ?? cached[id]??.plan, signIn: signIn,
                              loginCommand: loginCommands[e.path] ?? "", launchCommand: launchCommands[e.path] ?? "",
                              quota: quota,
                              headroom: CLIUsage.headroom(quota, signedIn: signIn.isGood, now: now, lastActivity: activity))
            }
            rows = CLIBoard.markingBest(rows)
            let found = group.shimInstalled || CLIShim.findRealBinary(kind, env: cli.env) != nil
            return CLIBoard(kind: kind, shimInstalled: group.shimInstalled, commandFound: found, rows: rows)
        }
    }

    private nonisolated static func profile(_ cli: CLIProfiles, _ kind: CLIKind, _ name: String) throws -> CLIProfile {
        guard let p = cli.list(kind).first(where: { $0.name == name }) else { throw SwitcherError.message(L.cliGone(name)) }
        return p
    }

    private nonisolated static func realBinary(_ cli: CLIProfiles, _ kind: CLIKind) -> String? {
        CLIShim.realBinary(ofShim: cli.env.shim(kind)) ?? CLIShim.findRealBinary(kind, env: cli.env)
    }

    /// New `claude` / `codex` processes use this account from now on. Nothing quits.
    func useCLI(_ row: CLIRow) {
        guard !isPreview, !row.isActive else { return }
        let cli = self.cli, keychain = self.cliKeychain
        let displayName = displayCLIActiveLabel(row)
        queue.async {
            let result = Result { try cli.setActive(try Self.profile(cli, row.kind, row.name)) }
            let boards = Self.readCLI(cli, keychain)
            Task { @MainActor in
                self.setCLI(boards)
                switch result {
                case .success:
                    let ready = self.cliBoard(row.kind)?.shimInstalled ?? false
                    self.banner = ready
                        ? Banner(kind: .success, text: L.cliNowUses(row.kind, displayName))
                        : Banner(kind: .info, text: L.cliChosenNoEffect(row.kind, displayName))
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Set or clear a display alias for a CLI account (stored in `cli-meta.json`; never renames its folder).
    func setCLIAlias(_ row: CLIRow, _ alias: String?) {
        if isPreview { return }
        let cli = self.cli, keychain = self.cliKeychain
        queue.async {
            let result = Result {
                try CLIMeta.edit(cli.env) { try $0.setAlias(kind: row.kind, name: row.name, alias) }
            }
            let boards = Self.readCLI(cli, keychain)
            Task { @MainActor in
                self.setCLI(boards)
                if case .failure(let error) = result {
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Sign a non-default CLI account out and move its profile folder to the Trash.
    func removeCLI(_ row: CLIRow) {
        guard !isPreview, !row.isDefault else { return }
        let cli = self.cli, keychain = self.cliKeychain
        let displayName = displayCLIActiveLabel(row)
        queue.async {
            let result = Result {
                let p = try Self.profile(cli, row.kind, row.name)
                if cli.signIn(p, keychain: keychain).state != .signedOut, let real = Self.realBinary(cli, row.kind) {
                    var base = ProcessInfo.processInfo.environment
                    base["PATH"] = CLIShim.enrichedPath(env: cli.env, realBinary: real, base: base["PATH"])
                    let run = CLILoginRun(profile: p, binary: real, arguments: row.kind.logoutArguments, baseEnvironment: base)
                    if (try? run.start()) != nil {
                        let timer = DispatchWorkItem { run.cancel(grace: 1) }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timer)
                        run.wait()
                        timer.cancel()
                    }
                }
                try cli.remove(p)
            }
            let boards = Self.readCLI(cli, keychain)
            Task { @MainActor in
                self.cliQuotaErrors[row.id] = nil
                self.cliAttempt[row.id] = nil
                self.cliFailures[row.id] = nil
                self.setCLI(boards)
                switch result {
                case .success:
                    self.banner = Banner(kind: .success, text: L.cliRemoved(displayName))
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Open a Terminal window running one session as this CLI account without changing the global pointer.
    func openTerminalForCLI(_ row: CLIRow) {
        if isPreview { return }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("switcher").path
        let command: String
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled) {
            command = "exec \(shellQuote(bundled)) cli exec \(row.kind.command) \(shellQuote(row.name))"
        } else if !row.launchCommand.isEmpty {
            command = row.launchCommand
        } else {
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-terminal", isDirectory: true)
        let url = dir.appendingPathComponent("launch-\(row.kind.command)-\(UUID().uuidString.prefix(8)).command")
        do {
            try FS.makePrivateDir(dir)
            let pathExport = "export PATH=\(shellQuote(CLIShim.enrichedPath(env: cli.env)))\n"
            try FS.atomicWrite(Data("#!/bin/sh\nrm -f \"$0\"\nclear\n\(pathExport)\(command)\n".utf8), to: url)
            guard chmod(url.path, 0o700) == 0 else { throw SwitcherError.message("cannot make \(url.path) executable") }
            NSWorkspace.shared.open(url)
        } catch {
            banner = Banner(kind: .error, text: error.localizedDescription)
        }
    }

    /// Add an account with one click: Switcher names the folder (`account2`, …), and the CLI's own
    /// sign-in runs in the background and opens the browser. If it ends without a sign-in, the
    /// new folder is removed again, so a cancelled add leaves nothing behind.
    func addCLIAccount(_ kind: CLIKind) {
        if isPreview || cliSigningIn[kind] != nil { return }
        let cli = self.cli
        queue.async {
            let result = Result { try cli.add(kind, name: cli.suggestedName(kind)) }
            Task { @MainActor in
                switch result {
                case .success(let p): self.startCLISignIn(p, createdNow: true)
                case .failure(let error): self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Sign an existing account in (again), in the background.
    func signInCLI(_ row: CLIRow) {
        if isPreview || cliSigningIn[row.kind] != nil { return }
        guard let p = try? Self.profile(cli, row.kind, row.isDefault ? "default" : row.name) else { return }
        startCLISignIn(p, createdNow: false)
    }

    func cancelCLISignIn(_ kind: CLIKind) {
        // Accepted until the sign-in's last step, even when its process already ended. A Cancel after
        // "in Terminal" takes that back too: nothing opens and a just-added account goes.
        guard cliSigningIn[kind] != nil else { return }
        cliHandoff[kind] = nil
        cliCancelled.insert(kind)
        if let run = cliLoginRuns[kind] { queue.async { run.cancel() } }
    }

    /// The sign-in that is running, in Terminal instead (when the browser flow does not work here).
    func continueCLISignInInTerminal(_ kind: CLIKind) {
        guard let name = cliSigningIn[kind], let run = cliLoginRuns[kind] else { return }
        // The account stays (a cancel would remove a just-added one), and Terminal opens once the
        // background sign-in has ended, so the two never run in the same folder at once.
        cliHandoff[kind] = (name, kind.loginCommand(run.profile))
        cliCancelled.insert(kind)
        queue.async { run.cancel() }
    }

    private func startCLISignIn(_ p: CLIProfile, createdNow: Bool) {
        let cli = self.cli, keychain = self.cliKeychain
        guard let binary = Self.realBinary(cli, p.kind) else {
            banner = Banner(kind: .error, text: L.cliNotFound(p.kind))
            if createdNow { queue.async { try? cli.discardUnsignedIn(p, keychain: keychain) } }
            return
        }
        // Launched from Finder the app has a bare PATH; the CLI may look for its helpers there.
        var base = ProcessInfo.processInfo.environment
        base["PATH"] = CLIShim.enrichedPath(env: cli.env, realBinary: binary, base: base["PATH"])
        let run = CLILoginRun(profile: p, binary: binary, baseEnvironment: base)
        do { try run.start() } catch {
            banner = Banner(kind: .error, text: error.localizedDescription)
            if createdNow { queue.async { try? cli.discardUnsignedIn(p, keychain: keychain) } }
            return
        }
        cliLoginRuns[p.kind] = run
        cliCancelled.remove(p.kind)
        cliSigningIn[p.kind] = p.name
        if createdNow { refreshCLI() }
        Task.detached {
            let status = run.wait()
            // One step on the main actor closes the run: after it no move to Terminal can arrive, so
            // what it read decides the clean-up. A later Cancel is taken in the last step.
            let (cancelled, handoff) = await MainActor.run {
                self.cliLoginRuns[p.kind] = nil
                return (self.cliCancelled.remove(p.kind) != nil, self.cliHandoff.removeValue(forKey: p.kind))
            }
            let present = cli.signIn(p, keychain: keychain).state != .signedOut
            // A just-added account is kept when its sign-in moved to Terminal.
            if !present, createdNow, handoff == nil { try? cli.discardUnsignedIn(p, keychain: keychain) }
            // A cancelled run proves nothing: an account signed in before keeps its old sign-in.
            let signedIn = present && !cancelled
            let email = cli.identity(p)?.email
            let twin = signedIn ? cli.duplicates(of: p).first : nil
            let output = signedIn ? "" : run.output()
            let boards = Self.readCLI(cli, keychain)
            await MainActor.run {
                // A Cancel that came after the run closed still counts.
                let cancelledLate = self.cliCancelled.remove(p.kind) != nil
                if handoff != nil, cancelledLate {
                    // The move to Terminal is taken back: nothing opens, and a just-added account goes.
                    // The sign-in stays marked as running until it is gone, so no retry starts in it.
                    guard createdNow, !present else { self.cliSigningIn[p.kind] = nil; self.setCLI(boards); return }
                    self.queue.async {
                        try? cli.discardUnsignedIn(p, keychain: keychain)
                        let after = Self.readCLI(cli, keychain)
                        Task { @MainActor in
                            self.cliSigningIn[p.kind] = nil
                            self.setCLI(after)
                        }
                    }
                    return
                }
                self.cliSigningIn[p.kind] = nil
                self.setCLI(boards)
                if let handoff {
                    self.openSignIn(p.kind, name: handoff.name, loginCommand: handoff.command)
                } else if signedIn {
                    let shown = self.displayEmail(email) ?? p.name
                    if let twin {
                        self.banner = Banner(kind: .info, text: L.cliDuplicate(shown, twin.isDefault ? "1" : twin.name))
                    } else {
                        self.banner = Banner(kind: .success, text: L.cliSignedIn(p.kind, shown))
                    }
                    self.cliQuotaErrors[p.id] = nil
                    self.cliFailures[p.id] = nil
                    self.loadCLIQuota(p.kind, force: true)
                } else if !cancelled, !cancelledLate {
                    let last = output.split(separator: "\n").last.map(String.init) ?? ""
                    self.banner = Banner(kind: .error, text: L.cliSignInFailed(status: status, detail: last))
                }
            }
        }
    }

    /// Switch new CLI sessions to the account with the most room (when active is low/out), else next signed-in account.
    func nextCLI(_ kind: CLIKind) {
        guard !isPreview, let board = cliBoard(kind) else { return }
        if let best = board.rows.first(where: { $0.isBest && !$0.isActive && $0.signIn.isGood }) {
            useCLI(best)
            return
        }
        let usable = board.rows.filter { $0.signIn.isGood }
        guard usable.count > 1 || (usable.count == 1 && !usable[0].isActive) else {
            banner = Banner(kind: .info, text: L.noOtherAccount(kind.displayName))
            return
        }
        if let activeIdx = board.rows.firstIndex(where: \.isActive) {
            let ordered = Array(board.rows[(activeIdx + 1)...]) + Array(board.rows[..<activeIdx])
            if let target = ordered.first(where: { !$0.isActive && $0.signIn.isGood }) {
                useCLI(target)
                return
            }
        }
        if let target = usable.first(where: { !$0.isActive }) {
            useCLI(target)
        }
    }

    private nonisolated static func readTerminalStatus(_ env: CLIEnv) -> TerminalSetupStatus {
        let shims = CLIKind.allCases.map { kind in
            let shimPath = env.shim(kind)
            let installed = CLIShim.isShim(shimPath)
            let real = installed ? CLIShim.realBinary(ofShim: shimPath) : CLIShim.findRealBinary(kind, env: env)
            return TerminalSetupStatus.ShimInfo(kind: kind, shimInstalled: installed, realBinary: real)
        }
        let rcFiles = CLICommands.rcFiles(env).map { rc in
            let text = (try? String(contentsOfFile: rc, encoding: .utf8)) ?? ""
            return TerminalSetupStatus.RCInfo(path: rc, state: CLIShim.rcState(text))
        }
        return TerminalSetupStatus(shims: shims, rcFiles: rcFiles)
    }

    func refreshTerminalStatus() {
        if isPreview { return }
        let env = cli.env
        queue.async {
            let status = Self.readTerminalStatus(env)
            Task { @MainActor in
                if self.terminalStatus != status { self.terminalStatus = status }
            }
        }
    }

    /// Run `CLIDoctor` off the main thread and populate Settings → Terminal & Doctor.
    func runDoctor() {
        if isPreview || runningDoctor { return }
        runningDoctor = true
        let cli = self.cli, keychain = self.cliKeychain
        Task.detached(priority: .userInitiated) {
            let status = Self.readTerminalStatus(cli.env)
            let findings = CLIDoctor(
                profiles: cli,
                keychain: keychain,
                rcFiles: CLICommands.rcFiles(cli.env),
                resolve: CLIDoctor.zshResolve
            ).run()
            await MainActor.run {
                self.terminalStatus = status
                self.doctorFindings = findings
                self.doctorLastRun = Date()
                self.runningDoctor = false
            }
        }
    }

    /// Install the PATH shims and the line in the shell's rc files. Only ever on the user's click.
    func installCLIShims() {
        if isPreview { return }
        let cli = self.cli, keychain = self.cliKeychain
        queue.async {
            let result = Result {
                try CLIShim.installShims(env: cli.env)
                for rc in CLICommands.rcFiles(cli.env) { try CLIShim.installRC(rc, env: cli.env) }
            }
            let boards = Self.readCLI(cli, keychain)
            let status = Self.readTerminalStatus(cli.env)
            Task { @MainActor in
                self.setCLI(boards)
                self.terminalStatus = status
                switch result {
                case .success:
                    self.cliJustInstalled = true
                    self.banner = Banner(kind: .success, text: L.shimsInstalled)
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Uninstall the PATH shims and rc blocks safely without touching any account folders or credentials.
    func uninstallCLIShims() {
        if isPreview { return }
        let cli = self.cli, keychain = self.cliKeychain
        queue.async {
            let result = Result {
                CLIShim.uninstallShims(env: cli.env)
                for rc in CLICommands.rcFiles(cli.env) { try CLIShim.uninstallRC(rc) }
            }
            let boards = Self.readCLI(cli, keychain)
            let status = Self.readTerminalStatus(cli.env)
            Task { @MainActor in
                self.setCLI(boards)
                self.terminalStatus = status
                self.cliJustInstalled = false
                switch result {
                case .success:
                    self.banner = Banner(kind: .success, text: L.shimsUninstalled)
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Re-create missing shared configuration symlinks across every non-default CLI profile.
    func repairCLILinks() {
        if isPreview { return }
        let cli = self.cli, keychain = self.cliKeychain
        queue.async {
            let result = Result<Int, Error> {
                var linked = 0
                for kind in CLIKind.allCases {
                    for p in cli.list(kind) where !p.isDefault {
                        linked += try cli.applyLinks(p).count
                    }
                }
                return linked
            }
            let boards = Self.readCLI(cli, keychain)
            Task { @MainActor in
                self.setCLI(boards)
                switch result {
                case .success(let count):
                    self.banner = count > 0
                        ? Banner(kind: .success, text: L.linksRepaired(count))
                        : Banner(kind: .info, text: L.linksAlreadyGood)
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Copy a privacy-redacted Doctor report (home path -> `~`, emails masked) to the clipboard.
    func copyDoctorReport() {
        guard !doctorFindings.isEmpty else { return }
        let report = CLIDoctor.formattedReport(doctorFindings, home: cli.env.home, redacted: true)
        copy(report)
        banner = Banner(kind: .success, text: L.doctorReportCopied)
    }

    private nonisolated static func readOneCLIQuota(
        _ p: CLIProfile, env: CLIEnv, keychain: CLIKeychain, cache: CLIQuotaCache,
        codexBinary: String?, codexEnv: [String: String]?
    ) async -> (String, CLIQuotaError?) {
        let profiles = CLIProfiles(env: env)
        do {
            let quota: CLIQuota
            switch p.kind {
            case .claude:
                quota = try await ClaudeCodeQuota.read(profile: p, profiles: profiles, keychain: keychain, http: URLSessionHTTPGetter())
            case .codex:
                guard let binary = codexBinary, let processEnv = codexEnv else {
                    throw CLIQuotaError.unavailable(L.cliNotFound(.codex))
                }
                quota = try await CodexQuota.read(profile: p, codexBinary: binary, environment: processEnv)
            }
            try? cache.store(quota, for: p, accountKey: profiles.identity(p)?.accountKey)
            return (p.id, nil)
        } catch let error as CLIQuotaError {
            return (p.id, error)
        } catch {
            return (p.id, .unavailable(error.localizedDescription))
        }
    }

    /// Read the usage of every signed-in account of `kind`, at most every 5 minutes (sooner with
    /// `force`). Never renews a sign-in: an expired one is reported on its row.
    /// `only`: these accounts, from the background check (it has its own rule, so no throttle here).
    func loadCLIQuota(_ kind: CLIKind, force: Bool = false, only: [String]? = nil) {
        if isPreview || cliReading.contains(kind) { return }
        if !force, only == nil, let at = cliQuotaReadAt[kind], Date().timeIntervalSince(at) < 300 { return }
        // Opening the menu does not cut short the backoff after failures; manual refresh still respects 429 backoff.
        let now = Date()
        func backingOff(_ row: CLIRow) -> Bool {
            let failures = cliFailures[row.id] ?? 0
            if !force {
                return CLIRefreshPlan.backingOff(lastAttempt: cliAttempt[row.id], failures: failures, now: now)
            }
            return failures >= CLIRefreshPlan.rateLimitedFailures
                && CLIRefreshPlan.backingOff(lastAttempt: cliAttempt[row.id], failures: failures, now: now)
        }
        guard let names = cliBoard(kind)?.rows.filter({ $0.signIn.isGood && (only?.contains($0.name) ?? true) && !backingOff($0) }).map(\.name),
              !names.isEmpty else { return }
        cliReading.insert(kind)
        for name in names { cliAttempt["\(kind.rawValue):\(name)"] = Date() }
        let cli = self.cli, keychain = self.cliKeychain
        Task.detached {
            let cache = CLIQuotaCache(env: cli.env)
            let codexBinary = kind == .codex ? Self.realBinary(cli, .codex) : nil
            let codexEnv: [String: String]? = codexBinary.map { binary in
                var processEnv = ProcessInfo.processInfo.environment
                processEnv["PATH"] = CLIShim.enrichedPath(env: cli.env, realBinary: binary, base: processEnv["PATH"])
                return processEnv
            }
            let targets = names.compactMap { try? Self.profile(cli, kind, $0) }
            let maxConcurrent = 3
            var errors: [String: CLIQuotaError?] = [:]
            await withTaskGroup(of: (String, CLIQuotaError?).self) { group in
                var nextIndex = 0
                let initial = min(maxConcurrent, targets.count)
                while nextIndex < initial {
                    let target = targets[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await Self.readOneCLIQuota(target, env: cli.env, keychain: keychain, cache: cache, codexBinary: codexBinary, codexEnv: codexEnv)
                    }
                }
                for await (id, error) in group {
                    errors.updateValue(error, forKey: id)
                    if nextIndex < targets.count {
                        let target = targets[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            await Self.readOneCLIQuota(target, env: cli.env, keychain: keychain, cache: cache, codexBinary: codexBinary, codexEnv: codexEnv)
                        }
                    }
                }
            }
            let boards = Self.readCLI(cli, keychain)
            let read = errors
            await MainActor.run {
                for (id, error) in read {
                    self.cliQuotaErrors[id] = error
                    switch error {
                    case nil: self.cliFailures[id] = nil
                    case let e?: self.cliFailures[id] = e.isRateLimited ? CLIRefreshPlan.rateLimitedFailures : (self.cliFailures[id] ?? 0) + 1
                    }
                }
                self.cliReading.remove(kind)
                if only == nil { self.cliQuotaReadAt[kind] = Date() }
                self.setCLI(boards)
            }
        }
    }

    /// Have Claude Code renew this account's sign-in (one minimal run of the real CLI), then read
    /// its usage again. Only from the row's button.
    func renewCLISignIn(_ row: CLIRow) {
        guard !isPreview, row.kind == .claude, !cliRenewing.contains(row.id) else { return }
        cliRenewing.insert(row.id)
        let cli = self.cli
        let displayName = displayCLIActiveLabel(row)
        Task.detached {
            var renewed = false
            if let p = try? Self.profile(cli, row.kind, row.name), let binary = Self.realBinary(cli, .claude) {
                var processEnv = ProcessInfo.processInfo.environment
                processEnv["PATH"] = CLIShim.enrichedPath(env: cli.env, realBinary: binary, base: processEnv["PATH"])
                renewed = ClaudeCodeQuota.renewLogin(profile: p, claudeBinary: binary, stateDir: cli.env.config + "/renew", environment: processEnv)
            }
            let ok = renewed
            await MainActor.run {
                self.cliRenewing.remove(row.id)
                if ok {
                    self.cliQuotaErrors[row.id] = nil
                    self.cliFailures[row.id] = nil
                    self.loadCLIQuota(.claude, force: true)
                } else {
                    self.banner = Banner(kind: .info, text: L.cliRenewFailed(displayName))
                }
            }
        }
    }

    /// Sign an account in, in Terminal: a one-shot `.command` script (private temp folder, deleted as
    /// it starts) runs `switcher cli login`, which runs the CLI's own sign-in in the account's folder.
    /// The menu picks the sign-in up the next time it opens.
    func openSignIn(_ kind: CLIKind, name: String, loginCommand: String?) {
        if isPreview { return }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("switcher").path
        let command: String
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled) {
            command = "exec \(shellQuote(bundled)) cli login \(kind.command) \(shellQuote(name))"
        } else if let loginCommand {
            command = loginCommand
        } else {
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-sign-in", isDirectory: true)
        let url = dir.appendingPathComponent("sign-in-\(kind.command)-\(UUID().uuidString.prefix(8)).command")
        do {
            try FS.makePrivateDir(dir)
            let pathExport = "export PATH=\(shellQuote(CLIShim.enrichedPath(env: cli.env)))\n"
            try FS.atomicWrite(Data("#!/bin/sh\nrm -f \"$0\"\nclear\n\(pathExport)\(command)\n".utf8), to: url)
            guard chmod(url.path, 0o700) == 0 else { throw SwitcherError.message("cannot make \(url.path) executable") }
            NSWorkspace.shared.open(url)
        } catch {
            banner = Banner(kind: .error, text: error.localizedDescription)
        }
    }

    func copy(_ text: String) {
        if isPreview { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Antigravity parallel sandboxes

    func createSandbox(name: String, alias: String?, linkPolicy: SandboxLinkPolicy, inheritHostConfig: Bool, launchImmediately: Bool) {
        if isPreview { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetName = trimmedName.isEmpty ? suggestedSandboxName() : trimmedName
        sandboxBusy.insert(targetName)
        let board = self.board
        queue.async {
            let result = Result<(AntigravitySandbox, pid_t?), Error> {
                let sb = try board.sandboxes.create(
                    name: targetName,
                    alias: alias,
                    linkPolicy: linkPolicy,
                    inheritHostConfig: inheritHostConfig
                )
                let pid = launchImmediately ? try board.sandboxes.launch(sb.name) : nil
                return (sb, pid)
            }
            let updated = board.sandboxBoard()
            Task { @MainActor in
                self.sandboxBusy.remove(targetName)
                self.sandboxes = updated
                switch result {
                case .success(let (sb, pid)):
                    if pid != nil {
                        self.banner = Banner(kind: .success, text: L.sandboxLaunched(sb.label))
                    } else {
                        self.banner = Banner(kind: .success, text: L.sandboxCreated(sb.label))
                    }
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    func launchSandbox(_ sandbox: AntigravitySandbox, workspace: String? = nil) {
        if isPreview || sandboxBusy.contains(sandbox.name) { return }
        sandboxBusy.insert(sandbox.name)
        let board = self.board
        let label = displaySandboxLabel(sandbox).title
        let name = sandbox.name
        queue.async {
            let result = Result { try board.sandboxes.launch(name, workspace: workspace) }
            let updated = board.sandboxBoard()
            Task { @MainActor in
                self.sandboxBusy.remove(name)
                self.sandboxes = updated
                switch result {
                case .success:
                    self.banner = Banner(kind: .success, text: L.sandboxLaunched(label))
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    func stopSandbox(_ sandbox: AntigravitySandbox, force: Bool = false) {
        if isPreview || sandboxBusy.contains(sandbox.name) { return }
        sandboxBusy.insert(sandbox.name)
        let board = self.board
        let label = displaySandboxLabel(sandbox).title
        let name = sandbox.name
        queue.async {
            let result = Result { try board.sandboxes.stop(name, force: force) }
            let updated = board.sandboxBoard()
            Task { @MainActor in
                self.sandboxBusy.remove(name)
                self.sandboxes = updated
                switch result {
                case .success(let stopped):
                    self.banner = Banner(kind: stopped ? .success : .info, text: stopped ? L.sandboxStopped(label) : L.sandboxAlreadyStopped(label))
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Prompts for a project folder (e.g. a dedicated `git worktree`) and launches the sandbox on it.
    func openSandboxFolderPicker(_ sandbox: AntigravitySandbox) {
        if isPreview { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L.t(
            "Choose a project folder or git worktree to open in \(displaySandboxLabel(sandbox).title).",
            "选择要在 \(displaySandboxLabel(sandbox).title) 中打开的项目目录（建议独立 git worktree）。")
        panel.prompt = L.t("Open", "打开")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            launchSandbox(sandbox, workspace: url.path)
        }
    }

    /// Opens a fresh macOS Terminal window running `agy` inside this sandbox's isolated environment.
    func openSandboxAgyInTerminal(_ sandbox: AntigravitySandbox) {
        if isPreview { return }
        let board = self.board
        let cliEnv = self.cli.env
        let name = sandbox.name
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("switcher").path
        queue.async {
            let result = Result<URL, Error> {
                // Ensure keyring-bypass markers and symlinks are current before Terminal starts.
                _ = try board.sandboxes.agyEnvironment(for: name)
                let command: String
                if let bundled, FileManager.default.isExecutableFile(atPath: bundled) {
                    command = "exec \(shellQuote(bundled)) agy \(shellQuote(name))"
                } else {
                    command = "exec " + board.sandboxes.standaloneAgyCommand(for: name)
                }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-agy", isDirectory: true)
                let url = dir.appendingPathComponent("agy-\(name)-\(UUID().uuidString.prefix(8)).command")
                try FS.makePrivateDir(dir)
                let pathExport = "export PATH=\(shellQuote(CLIShim.enrichedPath(env: cliEnv)))\n"
                let script = "#!/bin/sh\nrm -f \"$0\"\nclear\n\(pathExport)\(command)\n"
                try FS.atomicWrite(Data(script.utf8), to: url)
                guard chmod(url.path, 0o700) == 0 else {
                    throw SwitcherError.message("cannot make \(url.path) executable")
                }
                return url
            }
            Task { @MainActor in
                switch result {
                case .success(let url):
                    NSWorkspace.shared.open(url)
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Copies a self-contained `agy` launch command for this sandbox to the clipboard (after ensuring markers exist).
    func copySandboxAgyCommand(_ sandbox: AntigravitySandbox) {
        if isPreview { return }
        let board = self.board
        let name = sandbox.name
        let label = displaySandboxLabel(sandbox).title
        queue.async {
            _ = try? board.sandboxes.agyEnvironment(for: name)
            let cmd = board.sandboxes.standaloneAgyCommand(for: name)
            Task { @MainActor in
                self.copy(cmd)
                self.banner = Banner(kind: .success, text: L.sandboxAgyCopied(label))
            }
        }
    }

    func renameSandbox(_ sandbox: AntigravitySandbox, alias: String?) {
        edit { try $0.sandboxes.setAlias(sandbox.name, alias) }
    }

    func setSandboxLinkPolicy(_ sandbox: AntigravitySandbox, policy: SandboxLinkPolicy) {
        let label = displaySandboxLabel(sandbox).title
        let name = sandbox.name
        let board = self.board
        queue.async {
            let result = Result { try board.sandboxes.setLinkPolicy(name, policy) }
            let updated = board.sandboxBoard()
            Task { @MainActor in
                self.sandboxes = updated
                switch result {
                case .success:
                    self.banner = Banner(kind: .success, text: L.sandboxPolicyUpdated(label, policy))
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    func healSandbox(_ sandbox: AntigravitySandbox, force: Bool = true) {
        if isPreview || sandboxBusy.contains(sandbox.name) { return }
        sandboxBusy.insert(sandbox.name)
        let board = self.board
        let label = displaySandboxLabel(sandbox).title
        let name = sandbox.name
        queue.async {
            let result = Result { try board.sandboxes.heal(name, force: force) }
            let updated = board.sandboxBoard()
            Task { @MainActor in
                self.sandboxBusy.remove(name)
                self.sandboxes = updated
                switch result {
                case .success(let report):
                    self.banner = Banner(kind: .success, text: L.sandboxHealed(label, locks: report.locksCleaned.count, caches: report.cachesPurged.count))
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    func revealSandboxInFinder(_ sandbox: AntigravitySandbox) {
        if isPreview { return }
        NSWorkspace.shared.activateFileViewerSelecting([sandbox.path])
    }

    func removeSandbox(_ sandbox: AntigravitySandbox) {
        if isPreview || sandboxBusy.contains(sandbox.name) { return }
        sandboxBusy.insert(sandbox.name)
        let board = self.board
        let label = displaySandboxLabel(sandbox).title
        let name = sandbox.name
        queue.async {
            let result = Result { try board.sandboxes.remove(name) }
            let updated = board.sandboxBoard()
            Task { @MainActor in
                self.sandboxBusy.remove(name)
                self.sandboxes = updated
                switch result {
                case .success:
                    self.banner = Banner(kind: .success, text: L.sandboxRemoved(label))
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    // MARK: Account list

    func setAlias(_ p: ProviderID, _ account: String, _ alias: String?) {
        edit { try Roster.edit($0.env) { try $0.setAlias(p, account, alias) } }
    }

    func setDisabled(_ p: ProviderID, _ account: String, _ disabled: Bool) {
        edit { try Roster.edit($0.env) { $0.setDisabled(p, account, disabled) } }
    }

    func move(_ p: ProviderID, _ account: String, to number: Int) {
        edit { try Roster.edit($0.env) { try $0.move(p, account, to: number) } }
    }

    func reorder(_ p: ProviderID, _ account: String, toIndex: Int) {
        edit { try Roster.edit($0.env) { try $0.reorder(p, account, toIndex: toIndex) } }
    }

    func remove(_ p: ProviderID, _ account: String) {
        edit { try $0.remove(p, account: account) }
    }

    func importCCSame() {
        let board = self.board
        queue.async {
            let result = Result { try board.importCCSame() }
            Task { @MainActor in
                switch result {
                case .success(let r): self.banner = Banner(kind: .success, text: L.imported(r.logins))
                case .failure(let e): self.banner = Banner(kind: .error, text: e.localizedDescription)
                }
                self.refresh()
            }
        }
    }

    /// List edits take file locks (removing waits up to 30 s for a switch): run them on the core queue.
    private func edit(_ body: @escaping @Sendable (Switchboard) throws -> Void) {
        let board = self.board
        queue.async {
            let result = Result { try body(board) }
            Task { @MainActor in
                if case .failure(let error) = result { self.banner = Banner(kind: .error, text: error.localizedDescription) }
                self.refresh()
            }
        }
    }
}

/// The words on screen, in English and Simplified Chinese, following the user's preference or the system language.
enum L {
    static var zh: Bool { L10n.zh }

    static func t(_ en: String, _ cn: String) -> String { zh ? cn : en }

    static func noOtherAccount(_ app: String) -> String {
        t("No other \(app) account has a saved sign-in yet.", "还没有其他已保存登录的 \(app) 账号。")
    }

    static func signInToAdd(_ app: String) -> String {
        t("\(app) is open on its sign-in page. Sign in to the account to add.", "\(app) 已打开登录页，登录要添加的账号即可。")
    }

    static func switched(_ app: String, _ who: String) -> String {
        t("\(app) is now signed in to \(who).", "\(app) 已切换到 \(who)。")
    }

    static func switchCancelled(_ app: String) -> String {
        t("Cancelled. \(app) was left as it is.", "已取消，\(app) 保持原样。")
    }

    static func imported(_ n: Int) -> String {
        t("Imported \(n) saved sign-in(s) from CC Same.", "已从 CC Same 导入 \(n) 个已保存登录。")
    }

    static func cliRemoved(_ who: String) -> String {
        t("Removed \(who). Shared sessions and settings stay.", "已移除 \(who)，共享会话和设置保持不变。")
    }

    static func cliRemoveExplained(_ kind: CLIKind) -> String {
        t("Signs this \(kind.displayName) account out and moves its folder to the Trash. Shared sessions and settings stay.",
          "会先退出这个 \(kind.displayName) 账号的登录，再把它的配置文件夹移入废纸篓。共享的会话和设置保持不变。")
    }

    static var shimsInstalled: String {
        t("Terminal shims installed. Open a new terminal for them to take effect.",
          "终端启动器已安装，打开新终端窗口即可生效。")
    }

    static var shimsUninstalled: String {
        t("Terminal shims removed. Your accounts and settings were not touched.",
          "已移除终端启动器，账号与设置均未受影响。")
    }

    static func linksRepaired(_ count: Int) -> String {
        count == 1
            ? t("Restored 1 missing shared link.", "已修复 1 个缺失的共享软链。")
            : t("Restored \(count) missing shared links.", "已修复 \(count) 个缺失的共享软链。")
    }

    static var linksAlreadyGood: String {
        t("All shared configuration links are already in place.", "所有共享配置软链都已就绪，无需修复。")
    }

    static var doctorReportCopied: String {
        t("Copied redacted diagnostic report to clipboard.", "已复制脱敏诊断报告到剪贴板。")
    }

    static func sandboxLinkPolicyName(_ policy: SandboxLinkPolicy) -> String {
        switch policy {
        case .minimal: t("Minimal", "精简")
        case .full: t("Full", "完整")
        case .none: t("None", "无")
        }
    }

    static func sandboxCreated(_ label: String) -> String {
        t("Created sandbox \(label).", "已创建并行分身 \(label)。")
    }

    static func sandboxLaunched(_ label: String) -> String {
        t("Launched Antigravity window for \(label).", "已启动 \(label) 的独立 Antigravity 窗口。")
    }

    static func sandboxStopped(_ label: String) -> String {
        t("Stopped Antigravity window for \(label).", "已停止 \(label) 的独立 Antigravity 窗口。")
    }

    static func sandboxAlreadyStopped(_ label: String) -> String {
        t("\(label) is already stopped.", "\(label) 当前未运行。")
    }

    static func sandboxAgyCopied(_ label: String) -> String {
        t("Copied `agy` launch command for \(label).", "已复制 \(label) 的 agy 启动命令。")
    }

    static func sandboxPolicyUpdated(_ label: String, _ policy: SandboxLinkPolicy) -> String {
        t("Updated link policy for \(label) to \(sandboxLinkPolicyName(policy)).",
          "已将 \(label) 的软链策略更新为「\(sandboxLinkPolicyName(policy))」。")
    }

    static func sandboxHealed(_ label: String, locks: Int, caches: Int) -> String {
        if locks == 0 && caches == 0 {
            return t("Checked \(label): locks and markers look good.", "已检查 \(label)：锁文件与隔离标记均正常。")
        }
        return t("Healed \(label) (cleaned \(locks) lock(s), \(caches) cache(s)).",
                 "已自愈 \(label)（清理 \(locks) 个锁文件、\(caches) 个缓存）。")
    }

    static func sandboxRemoved(_ label: String) -> String {
        t("Moved sandbox \(label) to the Trash.", "已将分身 \(label) 移入废纸篓。")
    }
}

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

/// The app's state over SwitcherCore. Every call into the core that can block (quitting an app,
/// moving files, the keychain) runs off the main thread; results come back here.
@MainActor
@Observable
final class AppModel {
    private(set) var boards: [AppBoard] = []
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
    var banner: Banner?
    /// The app section the popover shows first.
    var selected: ProviderID = .claude

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

    /// Fixed data for previews and screenshots: touches nothing on disk.
    init(preview boards: [AppBoard], ccSame: CCSameImport.Found? = nil, job: SwitchJob? = nil, banner: Banner? = nil,
         cli cliBoards: [CLIBoard] = [], cliJustInstalled: Bool = false) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-preview", isDirectory: true)
        let env = Env(home: home)
        self.cli = CLIProfiles(env: CLIEnv(home: home.path))
        self.cliKeychain = MemoryCLIKeychain()
        self.cliBoards = cliBoards
        self.cliJustInstalled = cliJustInstalled
        self.board = Switchboard(env: env, claude: .claude(env: env, app: FakeApp(), keychain: MemorySecrets()), antigravity: .antigravity(env: env, app: FakeApp(), keychain: MemorySecrets()))
        self.boards = boards
        self.ccSame = ccSame
        self.job = job
        self.banner = banner
        self.isPreview = true
    }

    init(board: Switchboard = Switchboard()) {
        self.board = board
        self.cli = CLIProfiles(env: .live)
        self.cliKeychain = LiveCLIKeychain()
        queue.async { board.recoverIfIdle() }
        refresh()
        refreshCLI()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func board(_ p: ProviderID) -> AppBoard? { boards.first { $0.provider == p } }

    var isBusy: Bool { job != nil }

    /// Re-read every app. Cheap: run when the menu opens and every 15 seconds.
    func refresh() {
        if isPreview { return }
        let board = self.board
        queue.async {
            let boards = board.board()
            let found = board.ccSameImport()
            Task { @MainActor in
                // Assign only what changed, so a quiet 15-second tick redraws nothing.
                if self.boards != boards { self.boards = boards }
                if self.ccSame != found { self.ccSame = found }
                self.refreshQuotasIfDue()
            }
        }
    }

    @ObservationIgnored private var quotasReadAt: Date?
    @ObservationIgnored private var readingQuotas = false

    /// Antigravity quotas come from Google: read them at most every 5 minutes (sooner with `force`).
    func refreshQuotasIfDue(force: Bool = false) {
        if isPreview || readingQuotas { return }
        if !force, let at = quotasReadAt, Date().timeIntervalSince(at) < 300 { return }
        readingQuotas = true
        let board = self.board
        Task.detached {
            await board.refreshAntigravityUsage()
            let boards = board.board()
            await MainActor.run {
                self.readingQuotas = false
                self.quotasReadAt = Date()
                if self.boards != boards { self.boards = boards }
            }
        }
    }

    /// Switch `p` to `row`'s account.
    func switchTo(_ p: ProviderID, _ row: AccountRow) {
        guard !row.isCurrent, row.canSwitch else { return }
        start(p, target: row.slot.account, label: row.slot.label)
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
                self.start(p, target: slot.account, label: slot.label)
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
        job = SwitchJob(provider: p, target: target, targetLabel: label, phase: .quitting(app: name, waited: 0))
        let board = self.board
        queue.async {
            let result: Result<SwitchResult, Error>
            do {
                let r = try board.switchTo(p, account: target, alwaysLaunch: true, cancel: token) { waited in
                    Task { @MainActor in self.job?.phase = .quitting(app: name, waited: Int(waited)) }
                }
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
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
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
    }

    private nonisolated static func readCLI(_ cli: CLIProfiles, _ keychain: CLIKeychain) -> [CLIBoard] {
        let cache = CLIQuotaCache(env: cli.env)
        return CLIKind.allCases.compactMap { kind -> CLIBoard? in
            guard let group = CLICommands.list(cli, keychain: keychain, kinds: [kind]).first else { return nil }
            let listed = cli.list(kind)
            let commands = Dictionary(listed.map { ($0.path, kind.loginCommand($0)) }) { a, _ in a }
            // A cached quota counts only for the account the profile is signed in to now.
            let cached = Dictionary(listed.map { p in (p.id, cache.quota(for: p, accountKey: cli.identity(p)?.accountKey)) }) { a, _ in a }
            let rows = group.profiles.map { e -> CLIRow in
                let signIn: CLIRow.SignIn
                switch e.signIn {
                case "signedIn": signIn = .good(until: e.signInGoodUntil)
                case "other": signIn = .other(e.signInMode ?? "")
                default: signIn = .out
                }
                let id = "\(kind.rawValue):\(e.name)"
                return CLIRow(kind: kind, number: e.number, name: e.name, isDefault: e.isDefault, isActive: e.active,
                              email: e.email, plan: e.plan ?? cached[id]??.plan, signIn: signIn,
                              loginCommand: commands[e.path] ?? "", quota: signIn == .out ? nil : cached[id] ?? nil)
            }
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
        queue.async {
            let result = Result { try cli.setActive(try Self.profile(cli, row.kind, row.name)) }
            let boards = Self.readCLI(cli, keychain)
            Task { @MainActor in
                self.setCLI(boards)
                switch result {
                case .success:
                    let ready = self.cliBoard(row.kind)?.shimInstalled ?? false
                    self.banner = ready
                        ? Banner(kind: .success, text: L.cliNowUses(row.kind, row.label))
                        : Banner(kind: .info, text: L.cliChosenNoEffect(row.kind, row.label))
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
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
        guard let run = cliLoginRuns[kind] else { return }
        cliCancelled.insert(kind)
        queue.async { run.cancel() }
    }

    /// The sign-in that is running, in Terminal instead (when the browser flow does not work here).
    func continueCLISignInInTerminal(_ kind: CLIKind) {
        guard let name = cliSigningIn[kind], let run = cliLoginRuns[kind] else { return }
        let command = kind.loginCommand(run.profile)
        cliCancelled.insert(kind)
        queue.async { run.cancel() }
        openSignIn(kind, name: name, loginCommand: command)
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
        base["PATH"] = [cli.env.home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
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
            let signedIn = cli.signIn(p, keychain: keychain).state != .signedOut
            if !signedIn, createdNow { try? cli.discardUnsignedIn(p, keychain: keychain) }
            let email = cli.identity(p)?.email
            let twin = signedIn ? cli.duplicates(of: p).first : nil
            let output = signedIn ? "" : run.output()
            let boards = Self.readCLI(cli, keychain)
            await MainActor.run {
                let cancelled = self.cliCancelled.remove(p.kind) != nil
                self.cliLoginRuns[p.kind] = nil
                self.cliSigningIn[p.kind] = nil
                self.setCLI(boards)
                if signedIn {
                    if let twin {
                        self.banner = Banner(kind: .info, text: L.cliDuplicate(email ?? p.name, twin.isDefault ? "1" : twin.name))
                    } else {
                        self.banner = Banner(kind: .success, text: L.cliSignedIn(p.kind, email ?? p.name))
                    }
                    self.loadCLIQuota(p.kind, force: true)
                } else if !cancelled {
                    let last = output.split(separator: "\n").last.map(String.init) ?? ""
                    self.banner = Banner(kind: .error, text: L.cliSignInFailed(status: status, detail: last))
                }
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
            Task { @MainActor in
                self.setCLI(boards)
                switch result {
                case .success: self.cliJustInstalled = true
                case .failure(let error): self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Read the usage of every signed-in account of `kind`, at most every 5 minutes (sooner with
    /// `force`). Never renews a sign-in: an expired one is reported on its row.
    func loadCLIQuota(_ kind: CLIKind, force: Bool = false) {
        if isPreview || cliReading.contains(kind) { return }
        if !force, let at = cliQuotaReadAt[kind], Date().timeIntervalSince(at) < 300 { return }
        guard let names = cliBoard(kind)?.rows.filter({ $0.signIn.isGood }).map(\.name), !names.isEmpty else { return }
        cliReading.insert(kind)
        let cli = self.cli, keychain = self.cliKeychain
        Task.detached {
            let cache = CLIQuotaCache(env: cli.env)
            var errors: [String: CLIQuotaError?] = [:]
            for name in names {
                guard let p = try? Self.profile(cli, kind, name) else { continue }
                do {
                    let quota: CLIQuota
                    switch kind {
                    case .claude:
                        quota = try await ClaudeCodeQuota.read(profile: p, profiles: cli, keychain: keychain, http: URLSessionHTTPGetter())
                    case .codex:
                        guard let binary = Self.realBinary(cli, .codex) else { throw CLIQuotaError.unavailable(L.cliNotFound(.codex)) }
                        quota = try await CodexQuota.read(profile: p, codexBinary: binary)
                    }
                    try? cache.store(quota, for: p, accountKey: cli.identity(p)?.accountKey)
                    errors[p.id] = .some(nil)
                } catch let error as CLIQuotaError {
                    errors[p.id] = error
                } catch {
                    errors[p.id] = .unavailable(error.localizedDescription)
                }
            }
            let boards = Self.readCLI(cli, keychain)
            let read = errors
            await MainActor.run {
                for (id, error) in read { self.cliQuotaErrors[id] = error }
                self.cliReading.remove(kind)
                self.cliQuotaReadAt[kind] = Date()
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
        Task.detached {
            var renewed = false
            if let p = try? Self.profile(cli, row.kind, row.name), let binary = Self.realBinary(cli, .claude) {
                renewed = ClaudeCodeQuota.renewLogin(profile: p, claudeBinary: binary, stateDir: cli.env.config + "/renew")
            }
            let ok = renewed
            await MainActor.run {
                self.cliRenewing.remove(row.id)
                if ok {
                    self.cliQuotaErrors[row.id] = nil
                    self.loadCLIQuota(.claude, force: true)
                } else {
                    self.banner = Banner(kind: .info, text: L.cliRenewFailed(row.label))
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
            try FS.atomicWrite(Data("#!/bin/sh\nrm -f \"$0\"\nclear\n\(command)\n".utf8), to: url)
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

    // MARK: Account list

    func setDisabled(_ p: ProviderID, _ account: String, _ disabled: Bool) {
        edit { try Roster.edit($0.env) { $0.setDisabled(p, account, disabled) } }
    }

    func move(_ p: ProviderID, _ account: String, to number: Int) {
        edit { try Roster.edit($0.env) { try $0.move(p, account, to: number) } }
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

/// The words on screen, in English and Simplified Chinese, following the system language.
enum L {
    static let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

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

    static func imported(_ n: Int) -> String {
        t("Imported \(n) saved sign-in(s) from CC Same.", "已从 CC Same 导入 \(n) 个已保存登录。")
    }
}

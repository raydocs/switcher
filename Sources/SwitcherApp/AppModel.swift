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

/// Counter shared with `AppModel.queue` so CLI state reads never overwrite newer ones out of order.
private final class CLISeqBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0
    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        current &+= 1
        return current
    }
}

/// The app's state over SwitcherCore. Every call into the core that can block (quitting an app,
/// moving files, the keychain) runs off the main thread; results come back here.
@MainActor
@Observable
final class AppModel {
    private(set) var boards: [AppBoard] = []
    private(set) var job: SwitchJob?
    private(set) var ccSame: CCSameImport.Found?
    /// Claude Code, Codex and Antigravity CLI in the terminal: their accounts, apart from the desktop apps.
    private(set) var cliBoards: [CLIBoard] = []
    /// The CLIs whose usage is being read, and the accounts whose sign-in is being renewed or removed.
    private(set) var cliReading: Set<CLIKind> = []
    private(set) var cliRenewing: Set<String> = []
    private(set) var cliRemoving: Set<String> = []
    /// Reserved synchronously before `addCLIAccount` hops to `queue`, closing the double-click gap.
    private(set) var cliStarting: Set<CLIKind> = []
    /// A sign-in running in the background (the browser is open), per CLI: the account's name.
    private(set) var cliSigningIn: [CLIKind: String] = [:]
    /// True while the running sign-in is for a brand-new folder (`addCLIAccount`), hidden until done.
    private(set) var cliSignInCreatedNow: Set<CLIKind> = []
    /// True while the background sign-in process is still live and can be handed off to Terminal.
    private(set) var cliCanHandoff: Set<CLIKind> = []
    /// True once "Install" has run here: what is left is to open a new terminal.
    private(set) var cliJustInstalled = false
    var banner: Banner?
    /// The app section the popover shows first.
    var selected: ProviderID = .claude

    private struct PendingQuotaRequest {
        var force: Bool
        var respectRateLimit: Bool
        var names: Set<String>?
    }

    @ObservationIgnored let board: Switchboard
    @ObservationIgnored private let queue = DispatchQueue(label: "switcher.core", qos: .userInitiated)
    @ObservationIgnored private let cliSeqBox = CLISeqBox()
    @ObservationIgnored private var appliedCLISeq: UInt64 = 0
    @ObservationIgnored private var cancel: CancelToken?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isPreview = false
    @ObservationIgnored private let cli: CLIProfiles
    @ObservationIgnored private let cliKeychain: CLIKeychain
    @ObservationIgnored private var cliQuotaErrors: [String: CLIQuotaError] = [:]
    @ObservationIgnored private var cliErrorContext: [String: (accountKey: String?, fingerprint: String?)] = [:]
    @ObservationIgnored private var cliQuotaGen: [String: UInt64] = [:]
    @ObservationIgnored private var cliPendingQuota: [CLIKind: PendingQuotaRequest] = [:]
    @ObservationIgnored private var cliLoginRuns: [CLIKind: CLILoginRun] = [:]
    @ObservationIgnored private var cliCancelled: Set<CLIKind> = []
    /// Per account id: when its usage was last read (or tried) and how many reads in a row failed.
    @ObservationIgnored private var cliAttempt: [String: Date] = [:]
    @ObservationIgnored private var cliFailures: [String: Int] = [:]
    /// A sign-in moved to Terminal: the account and its command, opened once the background run ends.
    @ObservationIgnored private var cliHandoff: [CLIKind: (name: String, command: String)] = [:]
    @ObservationIgnored private var usageScheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var screensAsleep = false

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
        let cli = self.cli, boards = cliBoards, attempts = cliAttempt, failures = cliFailures
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        DispatchQueue.global(qos: .utility).async {
            let now = Date()
            let cache = CLIQuotaCache(env: cli.env)
            var needsBoardRefresh = false
            var due: [(CLIKind, [String])] = []
            for b in boards where b.commandFound {
                let listed = cli.list(b.kind)
                let activePath = cli.active(b.kind).path
                let activity = CLIUsage.lastActivity(b.kind, env: cli.env, now: now)
                let byName = Dictionary(b.rows.map { ($0.name, $0) }) { a, _ in a }
                if listed.map(\.name) != b.rows.map(\.name) { needsBoardRefresh = true }
                var activeStatus: CLIHeadroom.Status = .unknown
                let states = listed.map { p -> CLIRefreshState in
                    let isActive = p.path == activePath
                    let known = byName[p.name]
                    let signedIn: Bool
                    if p.kind == .codex || (p.kind == .agy && !p.isDefault) {
                        let s = cli.signIn(p, keychain: MemoryCLIKeychain())
                        signedIn = s.state == .signedIn && (s.refreshExpiresAt.map { $0 > now } ?? true)
                    } else {
                        signedIn = known?.signIn.isGood(at: now) ?? false
                    }
                    let accountKey = known?.accountKey ?? cli.identity(p)?.accountKey
                    let quota = signedIn ? cache.quota(for: p, accountKey: accountKey) : nil
                    let head = CLIUsage.headroom(quota, signedIn: signedIn, now: now, lastActivity: activity)
                    if isActive { activeStatus = head.status }
                    return CLIRefreshState(id: p.id, isActive: isActive, signedIn: signedIn,
                                           observedAt: quota?.observedAt, lastAttempt: attempts[p.id],
                                           failures: failures[p.id] ?? 0)
                }
                let ids = Set(CLIRefreshPlan.due(states, activeStatus: activeStatus,
                                                 lastActivity: activity, lowPower: lowPower, now: now))
                let names = listed.filter { ids.contains($0.id) }.map(\.name)
                if !names.isEmpty { due.append((b.kind, names)) }
            }
            let plan = due
            let shouldRefresh = needsBoardRefresh
            Task { @MainActor in
                if shouldRefresh { self.refreshCLI() }
                for (kind, names) in plan { self.loadCLIQuota(kind, only: names) }
            }
        }
    }

    func board(_ p: ProviderID) -> AppBoard? { boards.first { $0.provider == p } }

    var isBusy: Bool { job != nil }

    /// Re-read every app. Cheap: run when the menu opens and every 15 seconds while it is open.
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
        if !force, let at = quotasReadAt, max(0, Date().timeIntervalSince(at)) < 300 { return }
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

    // MARK: Claude Code, Codex and Antigravity CLI in the terminal

    func cliBoard(_ kind: CLIKind) -> CLIBoard? { cliBoards.first { $0.kind == kind } }

    /// Re-read the CLI accounts (folders, pointers, who is signed in). Run when the popover opens and
    /// after each action, not on the timer: it asks the keychain once per Claude Code account.
    /// `quotaFor`: the CLIs whose usage is read afterwards, if it is due.
    func refreshCLI(quotaFor kinds: Set<CLIKind> = []) {
        if isPreview { return }
        let cli = self.cli, keychain = self.cliKeychain, seqBox = self.cliSeqBox
        queue.async {
            let boards = Self.readCLI(cli, keychain)
            let seq = seqBox.next()
            Task { @MainActor in
                self.setCLI(boards, seq: seq)
                for kind in CLIKind.allCases where kinds.contains(kind) { self.loadCLIQuota(kind) }
            }
        }
    }

    /// Manual refresh from the popover: re-reads folders/credentials first so Terminal sign-ins or
    /// renewals clear stale errors, then reads usage for every signed-in account not in 429 lockout.
    func refreshCLIUsage(_ kind: CLIKind) {
        if isPreview { return }
        let cli = self.cli, keychain = self.cliKeychain, seqBox = self.cliSeqBox
        queue.async {
            let boards = Self.readCLI(cli, keychain)
            let seq = seqBox.next()
            Task { @MainActor in
                self.setCLI(boards, seq: seq)
                self.loadCLIQuota(kind, force: true, respectRateLimit: true)
            }
        }
    }

    private func clearCLIQuotaState(_ id: String, clearAttempt: Bool) {
        cliQuotaErrors[id] = nil
        cliFailures[id] = nil
        cliErrorContext[id] = nil
        if clearAttempt { cliAttempt[id] = nil }
        cliQuotaGen[id, default: 0] &+= 1
    }

    private func setCLI(_ read: [CLIBoard], seq: UInt64) {
        guard seq >= appliedCLISeq else { return }
        appliedCLISeq = seq
        let now = Date()
        var boards = read
        for b in boards.indices {
            for r in boards[b].rows.indices {
                let row = boards[b].rows[r]
                let id = row.id
                if !row.signIn.isGood(at: now) {
                    clearCLIQuotaState(id, clearAttempt: true)
                } else if let ctx = cliErrorContext[id],
                          ctx.accountKey != row.accountKey || ctx.fingerprint != row.credentialFingerprint
                {
                    clearCLIQuotaState(id, clearAttempt: true)
                } else if cliQuotaErrors[id] != nil,
                          let seen = row.quota?.observedAt, let tried = cliAttempt[id], seen > tried
                {
                    clearCLIQuotaState(id, clearAttempt: false)
                }
                boards[b].rows[r].quotaError = cliQuotaErrors[id]
            }
        }
        if cliBoards != boards { cliBoards = boards }
    }

    private nonisolated static func readCLI(_ cli: CLIProfiles, _ keychain: CLIKeychain) -> [CLIBoard] {
        let cache = CLIQuotaCache(env: cli.env)
        let now = Date()
        return CLIKind.allCases.compactMap { kind -> CLIBoard? in
            let activity = CLIUsage.lastActivity(kind, env: cli.env, now: now)
            guard let group = CLICommands.list(cli, keychain: keychain, kinds: [kind]).first else { return nil }
            let listed = cli.list(kind)
            let commands = Dictionary(listed.map { ($0.path, kind.loginCommand($0)) }) { a, _ in a }
            let meta = Dictionary(listed.map { p -> (String, (accountKey: String?, fingerprint: String?, quota: CLIQuota?)) in
                let key = cli.identity(p, keychain: keychain)?.accountKey
                let fp = cli.credentialFingerprint(p, keychain: keychain)
                return (p.id, (key, fp, cache.quota(for: p, accountKey: key)))
            }) { a, _ in a }
            var rows = group.profiles.map { e -> CLIRow in
                let signIn: CLIRow.SignIn
                switch e.signIn {
                case "signedIn": signIn = .good(until: e.signInGoodUntil)
                case "other": signIn = .other(e.signInMode ?? "")
                default: signIn = .out
                }
                let id = "\(kind.rawValue):\(e.name)"
                let info = meta[id]
                let good = signIn.isGood(at: now)
                // A window that reset since the reading shows 0 % (or goes) instead of the old number.
                var quota = signIn == .out ? nil : info?.quota
                if let read = quota { quota?.windows = CLIUsage.current(read, now: now, lastActivity: activity) }
                return CLIRow(kind: kind, number: e.number, name: e.name, isDefault: e.isDefault, isActive: e.active,
                              email: e.email, plan: e.plan ?? info?.quota?.plan, signIn: signIn,
                              loginCommand: commands[e.path] ?? "", quota: quota,
                              headroom: CLIUsage.headroom(quota, signedIn: good, now: now, lastActivity: activity),
                              accountKey: info?.accountKey, credentialFingerprint: info?.fingerprint)
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
        if let fromShim = CLIShim.realBinary(ofShim: cli.env.shim(kind)),
           fromShim.hasPrefix("/"), CLIShim.isRegularExecutable(fromShim), !CLIShim.isShim(fromShim)
        {
            return fromShim
        }
        return CLIShim.findRealBinary(kind, env: cli.env)
    }

    func isCLIProfileBusy(_ kind: CLIKind, name: String) -> Bool {
        let id = "\(kind.rawValue):\(name)"
        return cliRemoving.contains(id) || cliRenewing.contains(id) || cliSigningIn[kind] == name
    }

    /// New `claude` / `codex` / `agy` processes use this account from now on. Nothing quits.
    func useCLI(_ row: CLIRow) {
        guard !isPreview, !row.isActive, !cliRemoving.contains(row.id), cliSigningIn[row.kind] != row.name else { return }
        let cli = self.cli, keychain = self.cliKeychain, seqBox = self.cliSeqBox
        queue.async {
            let result = Result {
                let p = try Self.profile(cli, row.kind, row.name)
                if p.kind == .agy, !p.isDefault { try cli.prepareAgyProfile(p) }
                try cli.setActive(p)
            }
            let boards = Self.readCLI(cli, keychain)
            let seq = seqBox.next()
            Task { @MainActor in
                self.setCLI(boards, seq: seq)
                switch result {
                case .success:
                    let ready = self.cliBoard(row.kind)?.shimInstalled ?? false
                    self.banner = ready
                        ? Banner(kind: .success, text: L.cliNowUses(row.kind, row.label))
                        : Banner(kind: .info, text: L.cliChosenNoEffect(row.kind, row.label))
                    if let updated = self.cliBoard(row.kind)?.rows.first(where: { $0.name == row.name }),
                       updated.quota == nil, updated.signIn.isGood
                    {
                        self.loadCLIQuota(row.kind, only: [row.name])
                    }
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
        if isPreview || cliStarting.contains(kind) || cliSigningIn[kind] != nil { return }
        cliStarting.insert(kind)
        let prefix = kind.rawValue + ":"
        let reserved = Set(cliRemoving.union(cliRenewing).compactMap { id in
            id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
        })
        let cli = self.cli, keychain = self.cliKeychain
        queue.async {
            let result = Result { try cli.add(kind, name: cli.suggestedName(kind, keychain: keychain, reserved: reserved)) }
            Task { @MainActor in
                self.cliStarting.remove(kind)
                switch result {
                case .success(let p): self.startCLISignIn(p, createdNow: true)
                case .failure(let error): self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Sign an existing account in (again), in the background.
    func signInCLI(_ row: CLIRow) {
        if isPreview || cliStarting.contains(row.kind) || cliSigningIn[row.kind] != nil || isCLIProfileBusy(row.kind, name: row.name) { return }
        guard let p = try? Self.profile(cli, row.kind, row.isDefault ? "default" : row.name) else { return }
        startCLISignIn(p, createdNow: false)
    }

    func cancelCLISignIn(_ kind: CLIKind) {
        // Accepted until the sign-in's last step, even when its process already ended. A Cancel after
        // "in Terminal" takes that back too: nothing opens and a just-added account goes.
        guard cliSigningIn[kind] != nil else { return }
        cliHandoff[kind] = nil
        cliCancelled.insert(kind)
        if let run = cliLoginRuns[kind] {
            DispatchQueue.global(qos: .userInitiated).async { run.cancel() }
        }
    }

    /// The sign-in that is running, in Terminal instead (when the browser flow does not work here).
    func continueCLISignInInTerminal(_ kind: CLIKind) {
        guard let name = cliSigningIn[kind], let run = cliLoginRuns[kind] else { return }
        // The account stays (a cancel would remove a just-added one), and Terminal opens once the
        // background sign-in has ended, so the two never run in the same folder at once.
        cliHandoff[kind] = (name, kind.loginCommand(run.profile))
        cliCancelled.insert(kind)
        DispatchQueue.global(qos: .userInitiated).async { run.cancel() }
    }

    private nonisolated static func waitOffPool(_ run: CLILoginRun) async -> Int32 {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: run.wait())
            }
        }
    }

    private func startCLISignIn(_ p: CLIProfile, createdNow: Bool) {
        let cli = self.cli, keychain = self.cliKeychain, coreQueue = self.queue, seqBox = self.cliSeqBox
        guard !cliStarting.contains(p.kind), cliSigningIn[p.kind] == nil, !isCLIProfileBusy(p.kind, name: p.name) else {
            if createdNow { coreQueue.async { try? cli.discardUnsignedIn(p, keychain: keychain) } }
            return
        }
        guard let binary = Self.realBinary(cli, p.kind) else {
            banner = Banner(kind: .error, text: L.cliNotFound(p.kind))
            if createdNow { coreQueue.async { try? cli.discardUnsignedIn(p, keychain: keychain) } }
            return
        }
        let startedAt = Date()
        let beforeSignIn = cli.signIn(p, keychain: keychain)
        let beforeFingerprint = cli.credentialFingerprint(p, keychain: keychain)
        let wasSignedOut = createdNow || beforeSignIn.state == .signedOut
        let beforeExpired = beforeSignIn.refreshExpiresAt.map { $0 <= startedAt } ?? false

        let run = CLILoginRun(profile: p, binary: binary, workingDirectory: cli.env.home,
                              baseEnvironment: cli.env.augmentedEnvironment())
        do { try run.start() } catch {
            banner = Banner(kind: .error, text: error.localizedDescription)
            if createdNow { coreQueue.async { try? cli.discardUnsignedIn(p, keychain: keychain) } }
            return
        }
        cliLoginRuns[p.kind] = run
        cliCanHandoff.insert(p.kind)
        cliCancelled.remove(p.kind)
        cliHandoff[p.kind] = nil
        cliSigningIn[p.kind] = p.name
        if createdNow {
            cliSignInCreatedNow.insert(p.kind)
            refreshCLI()
        } else {
            cliSignInCreatedNow.remove(p.kind)
        }

        Task.detached {
            let status = await Self.waitOffPool(run)
            // One step on the main actor closes the run: after it no move to Terminal can arrive.
            let closed: (cancelled: Bool, handoff: (name: String, command: String)?)? = await MainActor.run {
                guard self.cliLoginRuns[p.kind] === run else { return nil }
                self.cliLoginRuns[p.kind] = nil
                self.cliCanHandoff.remove(p.kind)
                return (self.cliCancelled.remove(p.kind) != nil, self.cliHandoff.removeValue(forKey: p.kind))
            }
            guard let (cancelled, handoff) = closed else { return }

            let inspected = await withCheckedContinuation { (cont: CheckedContinuation<(afterPresent: Bool, completedNew: Bool, completedRelogin: Bool, email: String?, twin: CLIProfile?, output: String, boards: [CLIBoard], seq: UInt64), Never>) in
                coreQueue.async {
                    let now = Date()
                    let afterSignIn = cli.signIn(p, keychain: keychain)
                    let afterFingerprint = cli.credentialFingerprint(p, keychain: keychain)
                    let afterPresent = afterSignIn.state != .signedOut
                    let afterUsable = afterPresent && (afterSignIn.refreshExpiresAt.map { $0 > now } ?? true)
                    let changed = afterFingerprint != nil && afterFingerprint != beforeFingerprint
                    let completedNew = wasSignedOut && afterUsable && changed
                    let completedRelogin = !wasSignedOut && status == 0 && !cancelled && afterUsable && (changed || !beforeExpired)
                    if !afterPresent, createdNow, handoff == nil {
                        try? cli.discardUnsignedIn(p, keychain: keychain)
                    }
                    let email = cli.identity(p, keychain: keychain)?.email
                    let twin = (completedNew || completedRelogin) ? cli.duplicates(of: p, keychain: keychain).first : nil
                    let output = (completedNew || completedRelogin) ? "" : run.output()
                    let boards = Self.readCLI(cli, keychain)
                    let seq = seqBox.next()
                    cont.resume(returning: (afterPresent, completedNew, completedRelogin, email, twin, output, boards, seq))
                }
            }

            await MainActor.run {
                let cancelledLate = self.cliCancelled.remove(p.kind) != nil
                let signedIn = inspected.completedNew || (inspected.completedRelogin && !cancelledLate)

                func discardNewAndClear() {
                    coreQueue.async {
                        try? cli.discardUnsignedIn(p, keychain: keychain)
                        let after = Self.readCLI(cli, keychain)
                        let seq2 = seqBox.next()
                        Task { @MainActor in
                            self.cliSigningIn[p.kind] = nil
                            self.cliSignInCreatedNow.remove(p.kind)
                            self.setCLI(after, seq: seq2)
                        }
                    }
                }

                if !signedIn, handoff != nil, cancelledLate {
                    guard createdNow, !inspected.afterPresent else {
                        self.cliSigningIn[p.kind] = nil
                        self.cliSignInCreatedNow.remove(p.kind)
                        self.setCLI(inspected.boards, seq: inspected.seq)
                        return
                    }
                    discardNewAndClear()
                    return
                }

                self.clearCLIQuotaState(p.id, clearAttempt: true)
                self.cliSigningIn[p.kind] = nil
                self.cliSignInCreatedNow.remove(p.kind)
                self.setCLI(inspected.boards, seq: inspected.seq)

                if signedIn {
                    if let twin = inspected.twin {
                        self.banner = Banner(kind: .info, text: L.cliDuplicate(inspected.email ?? p.name, twin.isDefault ? "1" : twin.name))
                    } else {
                        self.banner = Banner(kind: .success, text: L.cliSignedIn(p.kind, inspected.email ?? p.name))
                    }
                    self.loadCLIQuota(p.kind, force: true, only: [p.name])
                } else if let handoff {
                    let opened = self.openSignIn(p.kind, name: handoff.name, loginCommand: handoff.command, createdNow: createdNow)
                    if !opened, createdNow, !inspected.afterPresent {
                        discardNewAndClear()
                    }
                } else if !cancelled, !cancelledLate {
                    let last = inspected.output.split(separator: "\n").last.map(String.init) ?? ""
                    self.banner = Banner(kind: .error, text: L.cliSignInFailed(status: status, detail: last))
                }
            }
        }
    }

    /// Sign a CLI account out (bounded wait) and move its profile folder to the Trash.
    func removeCLIAccount(_ row: CLIRow) {
        guard !isPreview, !row.isDefault, !isCLIProfileBusy(row.kind, name: row.name) else { return }
        cliRemoving.insert(row.id)
        clearCLIQuotaState(row.id, clearAttempt: true)
        let cli = self.cli, keychain = self.cliKeychain, coreQueue = self.queue, seqBox = self.cliSeqBox
        let kind = row.kind, name = row.name, rowID = row.id, label = row.label
        DispatchQueue.global(qos: .userInitiated).async {
            var keychainLeft = false
            if let p = try? Self.profile(cli, kind, name) {
                if !kind.logoutArguments.isEmpty, cli.signIn(p, keychain: keychain).state != .signedOut,
                   let real = Self.realBinary(cli, kind)
                {
                    let run = CLILoginRun(profile: p, binary: real, arguments: kind.logoutArguments,
                                          workingDirectory: cli.env.home, baseEnvironment: cli.env.augmentedEnvironment())
                    if (try? run.start()) != nil {
                        let (exited, _) = run.wait(timeout: 15)
                        if !exited { run.cancel(grace: 2) }
                    }
                }
                if kind == .claude, keychain.exists(service: claudeKeychainService(configDir: p.envValue)) {
                    keychainLeft = true
                }
            }
            coreQueue.async {
                let result = Result {
                    let p = try Self.profile(cli, kind, name)
                    try cli.remove(p)
                }
                let boards = Self.readCLI(cli, keychain)
                let seq = seqBox.next()
                let leftOver = keychainLeft
                Task { @MainActor in
                    self.cliRemoving.remove(rowID)
                    self.clearCLIQuotaState(rowID, clearAttempt: true)
                    self.setCLI(boards, seq: seq)
                    switch result {
                    case .success:
                        self.banner = leftOver
                            ? Banner(kind: .info, text: L.cliRemovedKeychainLeft(label))
                            : Banner(kind: .success, text: L.cliRemoved(label))
                    case .failure(let error):
                        self.banner = Banner(kind: .error, text: error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Install the PATH shims and the line in the shell's rc files. Only ever on the user's click.
    func installCLIShims() {
        if isPreview { return }
        let cli = self.cli, keychain = self.cliKeychain, seqBox = self.cliSeqBox
        queue.async {
            let result = Result {
                try CLIShim.installShims(env: cli.env)
                for rc in CLICommands.rcFiles(cli.env) { try CLIShim.installRC(rc, env: cli.env) }
            }
            let boards = Self.readCLI(cli, keychain)
            let seq = seqBox.next()
            Task { @MainActor in
                self.setCLI(boards, seq: seq)
                switch result {
                case .success: self.cliJustInstalled = true
                case .failure(let error): self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    /// Read the usage of signed-in accounts of `kind`, at most every 5 minutes per account (sooner
    /// with `force`). Never renews a sign-in: an expired one is reported on its row without entering
    /// failure backoff. `only`: restrict to these profile names.
    func loadCLIQuota(_ kind: CLIKind, force: Bool = false, only: [String]? = nil, respectRateLimit: Bool = false) {
        if isPreview { return }
        if cliReading.contains(kind) {
            if force || only != nil {
                if let cur = cliPendingQuota[kind] {
                    let combinedNames: Set<String>? = (cur.names == nil || only == nil) ? nil : cur.names!.union(only!)
                    let combinedForce = cur.force || force
                    let combinedRespect = combinedNames == nil
                        ? (cur.respectRateLimit || respectRateLimit)
                        : (cur.respectRateLimit && respectRateLimit)
                    cliPendingQuota[kind] = PendingQuotaRequest(force: combinedForce, respectRateLimit: combinedRespect, names: combinedNames)
                } else {
                    cliPendingQuota[kind] = PendingQuotaRequest(force: force, respectRateLimit: respectRateLimit, names: only.map(Set.init))
                }
            }
            return
        }

        let now = Date()
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let minWait = CLIRefreshPlan.minSpacing * (lowPower ? 2 : 1)
        struct Target: Sendable {
            var name: String
            var id: String
            var gen: UInt64
        }
        let targets: [Target] = (cliBoard(kind)?.rows ?? []).compactMap { row in
            guard !isCLIProfileBusy(kind, name: row.name),
                  row.signIn.isGood(at: now), only?.contains(row.name) ?? true else { return nil }
            let isBackingOff = CLIRefreshPlan.backingOff(lastAttempt: cliAttempt[row.id], failures: cliFailures[row.id] ?? 0,
                                                         lowPower: lowPower, now: now)
            if !force, isBackingOff { return nil }
            if force, respectRateLimit, isBackingOff, cliQuotaErrors[row.id]?.isRateLimited == true { return nil }
            if !force, only == nil, let last = cliAttempt[row.id], max(0, now.timeIntervalSince(last)) < minWait { return nil }
            return Target(name: row.name, id: row.id, gen: cliQuotaGen[row.id] ?? 0)
        }
        guard !targets.isEmpty else { return }

        cliReading.insert(kind)
        for t in targets { cliAttempt[t.id] = now }
        let cli = self.cli, keychain = self.cliKeychain, coreQueue = self.queue, seqBox = self.cliSeqBox
        let augmentedEnv = cli.env.augmentedEnvironment()

        struct ReadRecord: Sendable {
            var profile: CLIProfile
            var beforeKey: String?
            var beforeFP: String?
            var afterKey: String?
            var afterFP: String?
            var afterSignedOut: Bool
            var outcome: Result<CLIQuota, CLIQuotaError>
        }

        Task.detached {
            var records: [ReadRecord] = []
            for t in targets {
                guard let p = try? Self.profile(cli, kind, t.name) else { continue }
                let beforeKey = cli.identity(p, keychain: keychain)?.accountKey
                let beforeFP = cli.credentialFingerprint(p, keychain: keychain)
                let outcome: Result<CLIQuota, CLIQuotaError>
                do {
                    let quota: CLIQuota
                    switch kind {
                    case .claude:
                        quota = try await ClaudeCodeQuota.read(profile: p, profiles: cli, keychain: keychain, http: URLSessionHTTPGetter())
                    case .codex:
                        guard let binary = Self.realBinary(cli, .codex) else { throw CLIQuotaError.unavailable(L.cliNotFound(.codex)) }
                        quota = try await CodexQuota.read(profile: p, codexBinary: binary, environment: augmentedEnv)
                    case .agy:
                        quota = try await AgyCLIQuota.read(profile: p, profiles: cli, keychain: keychain)
                    }
                    outcome = .success(quota)
                } catch let error as CLIQuotaError {
                    outcome = .failure(error)
                } catch {
                    outcome = .failure(.unavailable(error.localizedDescription))
                }
                let afterKey = cli.identity(p, keychain: keychain)?.accountKey
                let afterFP = cli.credentialFingerprint(p, keychain: keychain)
                let afterSignedOut = cli.signIn(p, keychain: keychain).state == .signedOut
                records.append(ReadRecord(profile: p, beforeKey: beforeKey, beforeFP: beforeFP,
                                          afterKey: afterKey, afterFP: afterFP, afterSignedOut: afterSignedOut,
                                          outcome: outcome))
            }

            let collected = records
            let finished = await withCheckedContinuation { (cont: CheckedContinuation<(boards: [CLIBoard], seq: UInt64, validOutcomes: [String: CLIQuotaError?], staleIDs: Set<String>, contexts: [String: (accountKey: String?, fingerprint: String?)]), Never>) in
                coreQueue.async {
                    let cache = CLIQuotaCache(env: cli.env)
                    var validOutcomes: [String: CLIQuotaError?] = [:]
                    var staleIDs: Set<String> = []
                    var contexts: [String: (accountKey: String?, fingerprint: String?)] = [:]
                    for r in collected {
                        let p = r.profile
                        let nowKey = cli.identity(p, keychain: keychain)?.accountKey
                        let nowFP = cli.credentialFingerprint(p, keychain: keychain)
                        let sameDuringRead = (r.beforeKey == r.afterKey) && (r.beforeKey != nil || r.beforeFP == r.afterFP)
                        let sameUntilCommit = (nowKey == r.afterKey) && (nowFP == r.afterFP)
                        guard sameDuringRead, sameUntilCommit else {
                            staleIDs.insert(p.id)
                            continue
                        }
                        switch r.outcome {
                        case .success(let q):
                            guard !r.afterSignedOut else {
                                staleIDs.insert(p.id)
                                continue
                            }
                            try? cache.store(q, for: p, accountKey: r.afterKey)
                            validOutcomes[p.id] = .some(nil)
                        case .failure(let err):
                            validOutcomes[p.id] = err
                            contexts[p.id] = (r.afterKey, r.afterFP)
                        }
                    }
                    let boards = Self.readCLI(cli, keychain)
                    let seq = seqBox.next()
                    cont.resume(returning: (boards, seq, validOutcomes, staleIDs, contexts))
                }
            }

            await MainActor.run {
                for t in targets {
                    guard (self.cliQuotaGen[t.id] ?? 0) == t.gen else { continue }
                    if finished.staleIDs.contains(t.id) {
                        self.cliAttempt[t.id] = nil
                        continue
                    }
                    guard let outcome = finished.validOutcomes[t.id] else { continue }
                    self.cliQuotaErrors[t.id] = outcome
                    switch outcome {
                    case nil:
                        self.cliFailures[t.id] = nil
                        self.cliErrorContext[t.id] = nil
                    case let e?:
                        self.cliErrorContext[t.id] = finished.contexts[t.id] ?? (nil, nil)
                        switch e {
                        case .signedOut, .signInExpired:
                            self.cliFailures[t.id] = nil
                        case .unavailable:
                            self.cliFailures[t.id] = e.isRateLimited
                                ? CLIRefreshPlan.rateLimitedFailures
                                : (self.cliFailures[t.id] ?? 0) + 1
                        }
                    }
                }
                self.cliReading.remove(kind)
                self.setCLI(finished.boards, seq: finished.seq)
                if let pending = self.cliPendingQuota.removeValue(forKey: kind) {
                    self.loadCLIQuota(kind, force: pending.force, only: pending.names.map(Array.init),
                                      respectRateLimit: pending.respectRateLimit)
                }
            }
        }
    }

    /// Have Claude Code renew this account's sign-in (one minimal run of the real CLI), then read
    /// its usage again. Only from the row's button.
    func renewCLISignIn(_ row: CLIRow) {
        guard !isPreview, row.kind == .claude, !isCLIProfileBusy(row.kind, name: row.name) else { return }
        cliRenewing.insert(row.id)
        let cli = self.cli, keychain = self.cliKeychain, coreQueue = self.queue, seqBox = self.cliSeqBox
        let rowID = row.id, rowName = row.name, rowLabel = row.label
        DispatchQueue.global(qos: .userInitiated).async {
            var renewed = false
            if let p = try? Self.profile(cli, .claude, rowName), let binary = Self.realBinary(cli, .claude) {
                renewed = ClaudeCodeQuota.renewLogin(profile: p, claudeBinary: binary,
                                                     stateDir: cli.env.config + "/renew",
                                                     environment: cli.env.augmentedEnvironment())
            }
            let ok = renewed
            coreQueue.async {
                let boards = Self.readCLI(cli, keychain)
                let seq = seqBox.next()
                Task { @MainActor in
                    self.cliRenewing.remove(rowID)
                    if ok {
                        self.clearCLIQuotaState(rowID, clearAttempt: true)
                        self.setCLI(boards, seq: seq)
                        self.loadCLIQuota(.claude, force: true, only: [rowName])
                    } else {
                        self.setCLI(boards, seq: seq)
                        self.banner = Banner(kind: .info, text: L.cliRenewFailed(rowLabel))
                    }
                }
            }
        }
    }

    private nonisolated static func sameFile(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a, &sa) == 0, stat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// Sign an account in, in Terminal: a one-shot `.command` script (private temp folder, deleted as
    /// it starts) runs `switcher cli login`, which runs the CLI's own sign-in in the account's folder.
    /// The menu picks the sign-in up the next time it opens.
    @discardableResult
    func openSignIn(_ kind: CLIKind, name: String, loginCommand: String?, createdNow: Bool = false) -> Bool {
        if isPreview { return false }
        let mainExec = Bundle.main.executableURL?.path
        let macosDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let helper = macosDir?.appendingPathComponent("switcher-cli").path
        let devSibling = macosDir?.appendingPathComponent("switcher").path
        let bundled = [helper, devSibling].compactMap { $0 }.first { candidate in
            guard CLIShim.isRegularExecutable(candidate) else { return false }
            if let mainExec, Self.sameFile(candidate, mainExec) { return false }
            return true
        }
        let command: String
        if let bundled {
            let flag = createdNow ? " --rollback-if-unsigned" : ""
            command = "exec \(shellQuote(bundled)) cli login \(kind.command) \(shellQuote(name))\(flag)"
        } else if let loginCommand, !loginCommand.isEmpty {
            command = loginCommand
        } else {
            return false
        }
        let exportPath = "export PATH=\(shellQuote(cli.env.augmentedPath()))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-sign-in", isDirectory: true)
        let url = dir.appendingPathComponent("sign-in-\(kind.command)-\(UUID().uuidString.prefix(8)).command")
        do {
            try FS.makePrivateDir(dir)
            try FS.atomicWrite(Data("#!/bin/sh\nrm -f \"$0\"\n\(exportPath)\nclear\n\(command)\n".utf8), to: url)
            guard chmod(url.path, 0o700) == 0 else { throw SwitcherError.message("cannot make \(url.path) executable") }
            guard NSWorkspace.shared.open(url) else {
                try? FileManager.default.removeItem(at: url)
                banner = Banner(kind: .error, text: L.cliTerminalOpenFailed)
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            banner = Banner(kind: .error, text: error.localizedDescription)
            return false
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

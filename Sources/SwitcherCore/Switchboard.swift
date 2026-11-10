import Foundation

/// One account as the window and the menu show it.
public struct AccountRow: Equatable, Identifiable, Sendable {
    public var slot: Slot
    public var isCurrent: Bool
    /// A sign-in is set aside for it, so it can be switched to.
    public var canSwitch: Bool
    public var setAsideAt: Date?
    public var probablyExpired: Bool
    public var usage: PlanUsage?
    /// Antigravity: the quota last read for this account.
    public var quota: AntigravityQuota?

    public init(slot: Slot, isCurrent: Bool, canSwitch: Bool, setAsideAt: Date? = nil, probablyExpired: Bool = false, usage: PlanUsage? = nil, quota: AntigravityQuota? = nil) {
        self.slot = slot
        self.isCurrent = isCurrent
        self.canSwitch = canSwitch
        self.setAsideAt = setAsideAt
        self.probablyExpired = probablyExpired
        self.usage = usage
        self.quota = quota
    }

    public var id: String { slot.account }
}

/// One app as the window and the menu show it.
public struct AppBoard: Equatable, Identifiable, Sendable {
    public var provider: ProviderID
    public var installed: Bool
    public var running: Bool
    public var current: String?
    public var rows: [AccountRow]
    /// A switch was cut short and will be finished or undone the next time the app is quit.
    public var interrupted: Bool

    public init(provider: ProviderID, installed: Bool, running: Bool, current: String?, rows: [AccountRow], interrupted: Bool = false) {
        self.provider = provider
        self.installed = installed
        self.running = running
        self.current = current
        self.rows = rows
        self.interrupted = interrupted
    }

    public var id: ProviderID { provider }
    public var currentRow: AccountRow? { rows.first { $0.isCurrent } }
}

/// Everything Switcher manages, behind one object for the app and the command line.
public final class Switchboard {
    public let env: Env
    public let claude: Provider
    public let antigravity: Provider
    /// Whether cc-same's app or agent runs (replaced in tests).
    public var ccSameRunning: () -> Bool = CCSameImport.isRunning
    public let antigravityUsage: AntigravityUsage

    public init(env: Env = .live, claude: Provider? = nil, antigravity: Provider? = nil) {
        self.env = env
        self.claude = claude ?? .claude(env: env)
        self.antigravity = antigravity ?? .antigravity(env: env)
        self.antigravityUsage = AntigravityUsage(env: env)
    }

    public func provider(_ id: ProviderID) -> Provider {
        switch id {
        case .claude: claude
        case .antigravity: antigravity
        }
    }

    /// Put whoever each app is signed in to on its list (the first time Switcher sees them).
    @discardableResult
    public func noteSignedIn() -> Roster {
        let currents = ProviderID.allCases.map { (p: $0, who: provider($0).current()) }
        let saved = ProviderID.allCases.map { p in (p, provider(p).vault.saved()) }
        return (try? Roster.edit(env) { roster -> Roster in
            for (p, who) in currents {
                if let who { roster.join(p, account: who.id, email: who.email) }
            }
            for (p, list) in saved {
                for s in list { roster.join(p, account: s.account, email: s.email) }
            }
            fillClaudeEmails(&roster, current: currents.first { $0.p == .claude }?.who?.id)
            return roster
        }) ?? Roster.load(env)
    }

    /// Claude accounts the roster has no email for: look in claude.ai's own cache, the live one for
    /// the open account and each saved sign-in's copy for the rest. Read once; the roster keeps it.
    func fillClaudeEmails(_ roster: inout Roster, current: String?) {
        for slot in roster.slots(.claude) where slot.email == nil {
            let dir = slot.account == current ? env.claudeData : claude.vault.dir(slot.account)
            if let email = ClaudeFiles.webEmails(dir)[slot.account.lowercased()] {
                roster.join(.claude, account: slot.account, email: email)
            }
        }
    }

    /// A read of every app, cheap enough to refresh whenever the menu opens.
    public func board() -> [AppBoard] {
        let roster = noteSignedIn()
        let usage = ClaudeUsage.latest(env, roster: roster)
        let quotas = antigravityUsage.cached()
        return ProviderID.allCases.map { p in
            let prov = provider(p)
            let current = prov.current()?.id
            let saved = Dictionary(uniqueKeysWithValues: prov.vault.saved().map { ($0.account, $0) })
            let rows = roster.slots(p).map { slot -> AccountRow in
                let s = saved[slot.account]
                var u = p == .claude ? usage[slot.account] : nil
                // The open account may be filling a new 5-hour window Claude has not read yet.
                if slot.account == current, let a = u, a.age() > 5 * 3600 { u?.fiveHour = nil }
                return AccountRow(
                    slot: slot,
                    isCurrent: slot.account == current,
                    canSwitch: s != nil,
                    setAsideAt: s.map { Date(timeIntervalSince1970: $0.setAsideAt) },
                    probablyExpired: s?.probablyExpired ?? false,
                    usage: u,
                    quota: p == .antigravity ? quotas[slot.account] : nil
                )
            }
            return AppBoard(provider: p, installed: prov.app.isInstalled, running: prov.app.isRunning, current: current, rows: rows, interrupted: prov.vault.hasInterruptedSwap)
        }
    }

    /// Every Antigravity account's keychain value: the live one for the account in use, the saved
    /// copy for the others.
    public func antigravityKeyrings() -> [(account: String, value: String)] {
        let ref = Provider.antigravityKeychain
        var out: [(String, String)] = []
        let current = antigravity.current()?.id
        if let current, let live = try? antigravity.vault.keychain.get(service: ref.service, account: ref.account) {
            out.append((current, live))
        }
        for s in antigravity.vault.saved(excluding: current) {
            if let v = antigravity.vault.savedSecret(s.account, ref) { out.append((s.account, v)) }
        }
        return out
    }

    /// Read every Antigravity account's quota from Google, a few at a time.
    @discardableResult
    public func refreshAntigravityUsage() async -> [String: AntigravityQuota] {
        let usage = antigravityUsage
        return await withTaskGroup(of: (String, AntigravityQuota).self) { group in
            for (account, value) in antigravityKeyrings() {
                group.addTask { (account, await usage.refresh(account: account, keyring: value)) }
            }
            var out: [String: AntigravityQuota] = [:]
            for await (a, q) in group { out[a] = q }
            return out
        }
    }

    /// Switch an app to `account` (nil: signed out, to add another account).
    @discardableResult
    public func switchTo(_ p: ProviderID, account: String?, alwaysLaunch: Bool = true, cancel: CancelToken? = nil, waiting: ((TimeInterval) -> Void)? = nil) throws -> SwitchResult {
        let result = try provider(p).switchTo(account, alwaysLaunch: alwaysLaunch, cancel: cancel, waiting: waiting)
        noteSignedIn()
        return result
    }

    /// Next Account: the next number after the one in use that has a sign-in set aside.
    public func nextAccount(_ p: ProviderID) -> Slot? {
        let prov = provider(p)
        let current = prov.current()?.id
        return noteSignedIn().next(p, after: current) { prov.vault.isSaved($0.account) }
    }

    /// Take an account off the list and forget its saved sign-in. Not the one in use: it would
    /// join again at once.
    public func remove(_ p: ProviderID, account: String, lockTimeout: TimeInterval = 30) throws {
        let lock = try FileLock(claude.lockURL, timeout: lockTimeout)
        defer { withExtendedLifetime(lock) {} }
        if provider(p).vault.hasInterruptedSwap {
            throw SwitcherError.message(L10n.t("A switch was cut short. Quit the app once so it is finished, then remove the account.", "有一次切换被中断。先退出该应用一次让它完成，再删除账号。"))
        }
        if provider(p).current()?.id == account {
            throw SwitcherError.message("That account is signed in. Switch to another one first.")
        }
        try provider(p).vault.forget(account)
        try Roster.edit(env) { $0.remove(p, account) }
    }

    public func resolve(_ p: ProviderID, _ query: String) -> Slot? { noteSignedIn().resolve(p, query) }

    public func ccSameImport() -> CCSameImport.Found? {
        CCSameImport.find(env, currentClaude: claude.current()?.id, running: ccSameRunning)
    }

    public func importCCSame() throws -> CCSameImport.Result {
        let lock = try FileLock(claude.lockURL, timeout: 30)
        defer { withExtendedLifetime(lock) {} }
        return try CCSameImport.run(env, vault: claude.vault, currentClaude: claude.current()?.id, running: ccSameRunning)
    }

    /// Finish or undo any switch cut short, for apps that are not running.
    public func recoverIfIdle() {
        claude.recoverIfIdle()
        antigravity.recoverIfIdle()
    }
}

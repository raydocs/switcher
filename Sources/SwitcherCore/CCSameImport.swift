import Foundation

/// Taking over from cc-same: its numbered list and the Claude sign-ins it set aside. Its saved
/// sign-ins are in the same format Switcher uses, so they move over as they are.
public enum CCSameImport {
    public struct Found: Equatable {
        public var slots: Int
        public var logins: [String]
        public var running: Bool
        public var interruptedSwitch: Bool

        public init(slots: Int, logins: [String], running: Bool, interruptedSwitch: Bool) {
            self.slots = slots
            self.logins = logins
            self.running = running
            self.interruptedSwitch = interruptedSwitch
        }
    }

    struct CCRoster: Decodable {
        var slots: [Slot]
    }

    static func logins(_ env: Env) -> URL { env.ccSame.appendingPathComponent("logins", isDirectory: true) }

    /// cc-same's app or its background agent.
    public static func isRunning() -> Bool {
        // Can't list processes, or one we can't see into might be it: assume it runs, and refuse.
        guard let list = Proc.list() else { return true }
        if !list.unknown.isEmpty { return true }
        if list.unresolved.contains(where: { $0.name.hasPrefix("cc-same") || $0.name.hasPrefix("CC Same") }) { return true }
        return list.resolved.contains { p in
            p.path.contains("/CC Same.app/") || (p.path as NSString).lastPathComponent == "cc-same"
        }
    }

    /// What there is to import; nil when cc-same left nothing.
    public static func find(_ env: Env, currentClaude: String?, running: () -> Bool = isRunning) -> Found? {
        let roster = FS.readCodable(CCRoster.self, from: env.ccSame.appendingPathComponent("accounts.json"))
        let saved = FS.children(logins(env))
            .filter { isUUID($0.lastPathComponent) && FS.isFile($0.appendingPathComponent("config.json")) }
            .map(\.lastPathComponent)
            .filter { $0 != currentClaude }
        // Only saved sign-ins are worth offering; the list alone comes along with them.
        if saved.isEmpty { return nil }
        return Found(
            slots: roster?.slots.count ?? 0,
            logins: saved,
            running: running(),
            interruptedSwitch: FS.exists(logins(env).appendingPathComponent("switch.json"))
        )
    }

    public struct Result: Equatable {
        public var accounts: Int
        public var logins: Int
    }

    /// Move cc-same's sign-ins into Switcher's vault and copy its list (numbers, aliases, sitting
    /// out). cc-same must be quit, with no switch of its own left half done.
    public static func run(_ env: Env, vault: SignInVault, currentClaude: String?, running: () -> Bool = isRunning, lockTimeout: TimeInterval = 5) throws -> Result {
        // Hold cc-same's own lock for the whole import, so it can't start a switch of its own meanwhile,
        // and look again once it is held.
        let theirLock = try FileLock(env.ccSame.appendingPathComponent("lock"), timeout: lockTimeout)
        defer { withExtendedLifetime(theirLock) {} }
        guard let found = find(env, currentClaude: currentClaude, running: running) else { return Result(accounts: 0, logins: 0) }
        if found.running { throw SwitcherError.message("Quit CC Same first (its app and background sync), then import again.") }
        if found.interruptedSwitch { throw SwitcherError.message("CC Same has an account switch it did not finish. Open CC Same once so it can finish it, quit it, then import again.") }
        let theirs = FS.readCodable(CCRoster.self, from: env.ccSame.appendingPathComponent("accounts.json"))?.slots ?? []
        var accounts = 0
        try Roster.edit(env) { roster in
            for s in theirs.sorted(by: { $0.number < $1.number }) where isUUID(s.account) {
                if roster.slot(.claude, s.account) == nil {
                    roster.join(.claude, account: s.account, email: s.email)
                    accounts += 1
                }
                if !roster.slots(.claude).contains(where: { $0.number == s.number && $0.account != s.account }) {
                    try? roster.move(.claude, s.account, to: s.number)
                }
                if let alias = s.alias, roster.slot(.claude, s.account)?.alias == nil { try? roster.setAlias(.claude, s.account, alias) }
                if s.disabled { roster.setDisabled(.claude, s.account, true) }
                for org in s.orgs { roster.noteOrg(.claude, s.account, org) }
            }
        }
        var moved = 0
        for id in found.logins {
            if try vault.adopt(folder: logins(env).appendingPathComponent(id), id: id) {
                moved += 1
                let email = vault.about(vault.dir(id)).email
                try Roster.edit(env) { $0.join(.claude, account: id, email: email) }
            }
        }
        return Result(accounts: accounts, logins: moved)
    }
}

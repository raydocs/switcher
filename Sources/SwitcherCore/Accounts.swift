import Foundation

/// One account in an app's numbered list. Same fields as cc-same's slots, so its list imports as is.
public struct Slot: Codable, Equatable, Identifiable, Sendable {
    public var number: Int
    /// Claude: the account UUID. Antigravity: the lowercased email.
    public var account: String
    public var email: String?
    public var alias: String?
    /// Sits out of Next Account; switching to it by name still works.
    public var disabled: Bool = false
    public var addedAt: TimeInterval = 0
    /// Organizations Claude was seen using it with, to attribute plan usage.
    public var orgs: [String] = []

    public init(number: Int, account: String, email: String? = nil, alias: String? = nil, disabled: Bool = false, addedAt: TimeInterval = 0, orgs: [String] = []) {
        self.number = number
        self.account = account
        self.email = email
        self.alias = alias
        self.disabled = disabled
        self.addedAt = addedAt
        self.orgs = orgs
    }

    public var id: String { account }

    /// The alias, else the email, else a short ID.
    /// The email when known; an alias (from cc-same) only stands in until it is.
    public var label: String { email ?? alias ?? "Account \(account.prefix(8))" }
}

/// Every app's account list, in `<state>/accounts.json`.
public struct Roster: Codable, Equatable, Sendable {
    public var version = 1
    public var lists: [String: [Slot]] = [:]

    public init() {}

    public func slots(_ p: ProviderID) -> [Slot] { (lists[p.rawValue] ?? []).sorted { $0.number < $1.number } }

    public func slot(_ p: ProviderID, _ account: String) -> Slot? { lists[p.rawValue]?.first { $0.account == account } }

    mutating func update(_ p: ProviderID, _ body: (inout [Slot]) throws -> Void) rethrows {
        var list = lists[p.rawValue] ?? []
        try body(&list)
        lists[p.rawValue] = list.sorted { $0.number < $1.number }
    }

    /// Add `account` with the next free number, or refresh its email. Whether anything changed.
    @discardableResult
    public mutating func join(_ p: ProviderID, account: String, email: String?) -> Bool {
        var changed = false
        update(p) { list in
            if let i = list.firstIndex(where: { $0.account == account }) {
                if let email, list[i].email != email {
                    list[i].email = email
                    changed = true
                }
                return
            }
            let number = (1...).first { n in !list.contains { $0.number == n } }!
            list.append(Slot(number: number, account: account, email: email, addedAt: FS.now.rounded()))
            changed = true
        }
        return changed
    }

    public mutating func remove(_ p: ProviderID, _ account: String) {
        update(p) { $0.removeAll { $0.account == account } }
    }

    public mutating func setDisabled(_ p: ProviderID, _ account: String, _ disabled: Bool) {
        update(p) { list in
            if let i = list.firstIndex(where: { $0.account == account }) { list[i].disabled = disabled }
        }
    }

    /// Give `account` the number `to`, trading places with whoever had it.
    public mutating func move(_ p: ProviderID, _ account: String, to: Int) throws {
        guard to >= 1 else { throw SwitcherError.message("numbers start at 1") }
        try update(p) { list in
            guard let i = list.firstIndex(where: { $0.account == account }) else { throw SwitcherError.message("no such account") }
            if let j = list.firstIndex(where: { $0.number == to }) { list[j].number = list[i].number }
            list[i].number = to
        }
    }

    /// A lowercase name of up to 24 letters, digits, `-`, `_` and `.`, not only digits; nil clears it.
    public mutating func setAlias(_ p: ProviderID, _ account: String, _ alias: String?) throws {
        let name = alias?.trimmingCharacters(in: .whitespaces).lowercased()
        if let name, !name.isEmpty {
            guard name.count <= 24, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }), !name.allSatisfy(\.isNumber) else {
                throw SwitcherError.message("an alias is up to 24 letters, digits, '-', '_' or '.', and not only digits")
            }
            if slots(p).contains(where: { $0.alias == name && $0.account != account }) {
                throw SwitcherError.message("another account already uses that alias")
            }
        }
        update(p) { list in
            if let i = list.firstIndex(where: { $0.account == account }) { list[i].alias = (name?.isEmpty ?? true) ? nil : name }
        }
    }

    public mutating func noteOrg(_ p: ProviderID, _ account: String, _ org: String) {
        update(p) { list in
            if let i = list.firstIndex(where: { $0.account == account }), !list[i].orgs.contains(org) { list[i].orgs.append(org) }
        }
    }

    /// The account a name refers to: its number, alias, email, or the start of its ID.
    public func resolve(_ p: ProviderID, _ query: String) -> Slot? {
        let q = query.lowercased()
        let list = slots(p)
        if let n = Int(q) { return list.first { $0.number == n } }
        return list.first { $0.alias == q } ?? list.first { $0.email?.lowercased() == q }
            ?? { let hits = list.filter { $0.account.lowercased().hasPrefix(q) }; return hits.count == 1 ? hits[0] : nil }()
    }

    /// Next Account: the next number after `current` that is switchable, starting over after the last.
    public func next(_ p: ProviderID, after current: String?, switchable: (Slot) -> Bool) -> Slot? {
        let list = slots(p).filter { !$0.disabled && $0.account != current && switchable($0) }
        let from = current.flatMap { slot(p, $0)?.number } ?? 0
        return list.first { $0.number > from } ?? list.first
    }

    // MARK: Storage

    public static func url(_ env: Env) -> URL { env.state.appendingPathComponent("accounts.json") }

    public static func load(_ env: Env) -> Roster { FS.readCodable(Roster.self, from: url(env)) ?? Roster() }

    public func save(_ env: Env) throws { try FS.writeCodable(self, to: Self.url(env)) }

    /// Load, change and save, under the state lock.
    @discardableResult
    public static func edit<T>(_ env: Env, _ body: (inout Roster) throws -> T) throws -> T {
        let lock = try FileLock(env.state.appendingPathComponent("accounts.lock"), timeout: 5)
        defer { withExtendedLifetime(lock) {} }
        var roster = load(env)
        let before = roster
        let out = try body(&roster)
        if roster != before { try roster.save(env) }
        return out
    }
}

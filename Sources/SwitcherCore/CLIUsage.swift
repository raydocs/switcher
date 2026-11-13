import Foundation

// What the CLI quota means at a glance: how much room an account has, which account has the most,
// how far a window is from an even pace, and a machine-readable report (`cli usage --json`).
// Everything here is plain arithmetic over readings already in the cache, plus a few `stat`
// calls: no network, no process, no keychain.

/// How much room one account has left in its tightest main window.
public struct CLIHeadroom: Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok, low, out, unknown
    }

    public var status: Status
    /// The main window (5-hour, weekly, or Codex's own) closest to its limit, after resets.
    public var tightest: CLIQuotaWindow?
    /// 100 − the tightest window's use. Nil when unknown.
    public var percentLeft: Double?
    /// A model- or feature-scoped window (`week (Opus)`, a second Codex bucket) at 90 % or more.
    public var scopedWarning: CLIQuotaWindow?

    public static let unknown = CLIHeadroom(status: .unknown, tightest: nil, percentLeft: nil, scopedWarning: nil)
}

public enum CLIUsage {
    /// A window this full is `low`.
    public static let lowAt: Double = 80
    public static let scopedWarnAt: Double = 90
    /// A reading older than this is shown with its age and marked stale.
    public static let staleAfter: TimeInterval = 30 * 60

    /// The 5-hour and weekly windows, and Codex's unprefixed ones (`300m`, …). Model-scoped windows
    /// (`week (Opus)`) and other Codex buckets (`<name> 5h`) are not main windows.
    public static func isMain(_ w: CLIQuotaWindow) -> Bool {
        if w.label == "5h" || w.label == "week" { return true }
        return w.label.hasSuffix("m") && Int(w.label.dropLast()) != nil
    }

    /// How long a window lasts, from its label.
    public static func duration(_ w: CLIQuotaWindow) -> TimeInterval? {
        let last = w.label.split(separator: " ").last.map(String.init) ?? w.label
        switch last {
        case "5h": return 5 * 3600
        case "week": return 7 * 86400
        default:
            if w.label.hasPrefix("week") { return 7 * 86400 }
            guard last.hasSuffix("m"), let m = Int(last.dropLast()), m > 0 else { return nil }
            return TimeInterval(m * 60)
        }
    }

    /// The windows as they stand now. A window whose reset time has passed is back to 0 % when
    /// nothing of this CLI ran since that reset (`lastActivity`); when something did, or nobody
    /// knows, the window is dropped rather than guessed.
    public static func current(_ quota: CLIQuota, now: Date, lastActivity: Date?) -> [CLIQuotaWindow] {
        quota.windows.compactMap { current($0, now: now, lastActivity: lastActivity) }
    }

    public static func current(_ w: CLIQuotaWindow, now: Date, lastActivity: Date?) -> CLIQuotaWindow? {
        guard let reset = w.resetsAt, reset <= now else { return w }
        guard let last = lastActivity, last < reset else { return nil }
        return CLIQuotaWindow(label: w.label, usedPercent: 0, resetsAt: nil)
    }

    public static func headroom(_ quota: CLIQuota?, signedIn: Bool, now: Date, lastActivity: Date?) -> CLIHeadroom {
        guard signedIn, let quota else { return .unknown }
        let windows = current(quota, now: now, lastActivity: lastActivity)
        let scoped = windows.filter { !isMain($0) && $0.usedPercent >= scopedWarnAt }.max { $0.usedPercent < $1.usedPercent }
        guard let tight = windows.filter(isMain).max(by: { $0.usedPercent < $1.usedPercent }) else {
            return CLIHeadroom(status: .unknown, tightest: nil, percentLeft: nil, scopedWarning: scoped)
        }
        let status: CLIHeadroom.Status = tight.usedPercent >= 100 ? .out : tight.usedPercent >= lowAt ? .low : .ok
        return CLIHeadroom(status: status, tightest: tight, percentLeft: max(0, 100 - tight.usedPercent), scopedWarning: scoped)
    }

    /// Where use would be now if the window were spent evenly: the share of the window gone by, in
    /// percent. Nil without a reset time or a known length.
    public static func pace(_ w: CLIQuotaWindow, now: Date) -> Double? {
        guard let reset = w.resetsAt, let length = duration(w), reset > now else { return nil }
        let gone = length - reset.timeIntervalSince(now)
        return min(100, max(0, gone / length * 100))
    }

    /// The account with the most room among `candidates` (id, headroom): never an unknown or used-up
    /// one. Ties go to the earlier candidate (list order).
    public static func best<ID>(_ candidates: [(id: ID, headroom: CLIHeadroom)]) -> ID? {
        var pick: (id: ID, left: Double)?
        for c in candidates where c.headroom.status == .ok || c.headroom.status == .low {
            guard let left = c.headroom.percentLeft else { continue }
            if pick == nil || left > pick!.left { pick = (c.id, left) }
        }
        return pick?.id
    }

    /// When this CLI last did anything, by the modification time of files it writes on every
    /// prompt or turn. They are shared by every account (links into the default folder), so this
    /// is when any account last ran. Only `stat`s; nothing is read.
    /// Claude: `history.jsonl`. Codex: `history.jsonl` and the newest session file of today and
    /// yesterday (`sessions/YYYY/MM/DD`, local dates).
    public static func lastActivity(_ kind: CLIKind, env: CLIEnv, now: Date = Date()) -> Date? {
        let root = env.defaultFolder(kind)
        var dates: [Date] = []
        if let d = FS.mtime(URL(fileURLWithPath: root + "/history.jsonl")) { dates.append(d) }
        if kind == .codex {
            let cal = Calendar.current
            for back in [0, -1] {
                guard let day = cal.date(byAdding: .day, value: back, to: now) else { continue }
                let c = cal.dateComponents([.year, .month, .day], from: day)
                let dir = String(format: "%@/sessions/%04d/%02d/%02d", root, c.year ?? 0, c.month ?? 0, c.day ?? 0)
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for n in names where n.hasSuffix(".jsonl") {
                    if let d = FS.mtime(URL(fileURLWithPath: dir + "/" + n)) { dates.append(d) }
                }
            }
        }
        return dates.max()
    }
}

// MARK: - When to read again

/// What the background refresh knows about one account.
public struct CLIRefreshState: Equatable, Sendable {
    public var id: String
    public var isActive: Bool
    public var signedIn: Bool
    /// When the cached reading was taken.
    public var observedAt: Date?
    public var lastAttempt: Date?
    /// Failed reads in a row. A rate limit (HTTP 429) counts as many, so it waits the longest.
    public var failures: Int

    public init(id: String, isActive: Bool, signedIn: Bool, observedAt: Date?, lastAttempt: Date? = nil, failures: Int = 0) {
        self.id = id
        self.isActive = isActive
        self.signedIn = signedIn
        self.observedAt = observedAt
        self.lastAttempt = lastAttempt
        self.failures = failures
    }
}

/// Which accounts to read in the background. The rule keeps reads (a request, or a `codex
/// app-server` process) to when the numbers can have changed:
/// - only the active account, and only when this CLI ran since its reading, or the reading is
///   older than `maxAge` (the same account may be used on another computer);
/// - the other accounts only while the active one is low or out (to show where to go), at most
///   every `maxAge`;
/// - never twice within `minSpacing`, and after failures 5 min doubling to an hour.
/// Low Power Mode doubles every interval.
public enum CLIRefreshPlan {
    public static let minSpacing: TimeInterval = 5 * 60
    public static let maxAge: TimeInterval = 30 * 60
    public static let backoffBase: TimeInterval = 5 * 60
    public static let backoffMax: TimeInterval = 60 * 60
    /// The failure count a rate limit sets: its backoff is the maximum.
    public static let rateLimitedFailures = 8

    public static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(backoffMax, backoffBase * pow(2, Double(min(failures, 10) - 1)))
    }

    public static func due(_ accounts: [CLIRefreshState], activeStatus: CLIHeadroom.Status, lastActivity: Date?,
                           lowPower: Bool, now: Date) -> [String] {
        let factor: Double = lowPower ? 2 : 1
        return accounts.filter { a in
            guard a.signedIn else { return false }
            if let last = a.lastAttempt {
                let wait = max(minSpacing * factor, backoff(failures: a.failures) * factor)
                if now.timeIntervalSince(last) < wait { return false }
            }
            guard let seen = a.observedAt else { return a.isActive || activeStatus == .low || activeStatus == .out }
            let old = now.timeIntervalSince(seen) >= maxAge * factor
            if a.isActive { return old || (lastActivity.map { $0 > seen } ?? false) }
            return (activeStatus == .low || activeStatus == .out) && old
        }.map(\.id)
    }
}

// MARK: - Report

/// `switcher cli usage --json`: every account's last reading and what it means now. Versioned;
/// percentages, reset times, plan and the identity `cli list --json` already prints. No tokens.
public struct CLIUsageReport: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var label: String
        public var usedPercent: Double
        public var resetsAt: Date?
        /// The reset time passed since the reading and nothing ran since: use is back to 0.
        public var resetSinceRead: Bool
        /// Where an even pace would be now, in percent.
        public var pacePercent: Double?
    }

    public struct Account: Codable, Equatable, Sendable {
        public var number: Int
        public var name: String
        public var email: String?
        public var isDefault: Bool
        public var active: Bool
        /// Nil when not checked (`--cached` never asks the keychain).
        public var signedIn: Bool?
        public var plan: String?
        public var source: String?
        public var observedAt: Date?
        public var stale: Bool
        public var error: String?
        public var status: CLIHeadroom.Status
        public var percentLeft: Double?
        public var tightest: String?
        public var scopedWarning: String?
        public var windows: [Window]
    }

    public struct CLI: Codable, Equatable, Sendable {
        public var cli: String
        public var lastActivity: Date?
        /// The name of the account with the most room, if any has room.
        public var best: String?
        public var accounts: [Account]
    }

    public var schema = "switcher.usage.v1"
    public var generatedAt: Date
    public var clis: [CLI]

    /// Built from the cache. `signedIn`: nil to skip the sign-in check (no keychain); then an
    /// account counts as signed in when it has an identity. `errors`: the newest failed read per
    /// profile id, if any.
    public static func build(profiles: CLIProfiles, kinds: [CLIKind] = CLIKind.allCases, now: Date = Date(),
                             signedIn: ((CLIProfile) -> Bool)? = nil, errors: [String: String] = [:]) -> CLIUsageReport {
        let cache = CLIQuotaCache(env: profiles.env)
        let clis = kinds.map { kind -> CLI in
            let activity = CLIUsage.lastActivity(kind, env: profiles.env, now: now)
            let active = profiles.active(kind).path
            var heads: [(id: String, headroom: CLIHeadroom)] = []
            let accounts = profiles.list(kind).enumerated().map { i, p -> Account in
                let identity = profiles.identity(p)
                let checked = signedIn?(p)
                let isIn = checked ?? (identity != nil)
                let quota = isIn ? cache.quota(for: p, accountKey: identity?.accountKey) : nil
                let head = CLIUsage.headroom(quota, signedIn: isIn, now: now, lastActivity: activity)
                let isActive = p.path == active
                if !isActive { heads.append((p.name, head)) }
                let windows = (quota?.windows ?? []).compactMap { read -> Window? in
                    guard let w = CLIUsage.current(read, now: now, lastActivity: activity) else { return nil }
                    return Window(label: w.label, usedPercent: w.usedPercent, resetsAt: w.resetsAt,
                                  resetSinceRead: read.resetsAt != nil && w.resetsAt == nil, pacePercent: CLIUsage.pace(w, now: now).map { ($0 * 10).rounded() / 10 })
                }
                return Account(number: i + 1, name: p.name, email: identity?.email, isDefault: p.isDefault, active: isActive,
                               signedIn: checked, plan: quota?.plan ?? identity?.plan, source: quota?.source,
                               observedAt: quota?.observedAt,
                               stale: quota.map { now.timeIntervalSince($0.observedAt) > CLIUsage.staleAfter } ?? false,
                               error: errors[p.id], status: head.status, percentLeft: head.percentLeft,
                               tightest: head.tightest?.label, scopedWarning: head.scopedWarning?.label, windows: windows)
            }
            return CLI(cli: kind.rawValue, lastActivity: activity, best: CLIUsage.best(heads), accounts: accounts)
        }
        return CLIUsageReport(generatedAt: now, clis: clis)
    }

    public func json() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return String(decoding: (try? enc.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }
}

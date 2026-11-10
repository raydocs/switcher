import Foundation

/// How much of an account's plan is used, as Claude Desktop last read it.
public struct PlanUsage: Equatable, Sendable {
    /// The 5-hour window, percent used; nil when unknown.
    public var fiveHour: Int?
    /// The weekly window, percent used; nil when unknown.
    public var weekly: Int?
    /// When Claude asked.
    public var sampledAt: Date

    public init(fiveHour: Int?, weekly: Int?, sampledAt: Date) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.sampledAt = sampledAt
    }

    public func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(sampledAt) }
    /// Older than half an hour: show its age.
    public func isStale(now: Date = Date()) -> Bool { age(now: now) > 30 * 60 }
}

/// Claude Desktop's `plan-usage-history.json`: what claude.ai answered when Desktop asked how much
/// of the open organization's plan is used (`fh` is the 5-hour window, `sd` the weekly one).
/// Switcher never asks Anthropic itself; an account's numbers are as fresh as Claude's last look.
public enum ClaudeUsage {
    struct File: Decodable {
        struct Sample: Decodable {
            var t: Double
            var org: String
            var u: [String: Double]?
        }
        var samples: [Sample]
    }

    /// Organization → the accounts known to use it, from the session folders and the roster.
    public static func orgOwners(_ env: Env, roster: Roster) -> [String: Set<String>] {
        var owners: [String: Set<String>] = [:]
        for base in [env.claudeSessions, env.claudeCoworkSessions] {
            for account in FS.children(base) where isUUID(account.lastPathComponent) {
                for org in FS.children(account) where isUUID(org.lastPathComponent) {
                    owners[org.lastPathComponent, default: []].insert(account.lastPathComponent)
                }
            }
        }
        for slot in roster.slots(.claude) {
            for org in slot.orgs { owners[org, default: []].insert(slot.account) }
        }
        return owners
    }

    /// The newest usage for each account. Samples name an organization; one used by a single
    /// account belongs to it, and one several accounts share (a team) is left out rather than guessed.
    public static func latest(_ env: Env, roster: Roster, now: Date = Date()) -> [String: PlanUsage] {
        guard let data = try? Data(contentsOf: env.claudeUsageHistory),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        let owners = orgOwners(env, roster: roster)
        var out: [String: PlanUsage] = [:]
        for s in file.samples.sorted(by: { $0.t < $1.t }) {
            guard let who = owners[s.org], who.count == 1, let account = who.first else { continue }
            let at = Date(timeIntervalSince1970: s.t / 1000)
            var fh = s.u?["fh"].map { Int($0.rounded()) }
            var sd = s.u?["sd"].map { Int($0.rounded()) }
            // A 5-hour reading older than five hours is a window that has started over since;
            // a weekly one older than a week says nothing.
            if now.timeIntervalSince(at) > 5 * 3600 { fh = fh.map { _ in 0 } }
            if now.timeIntervalSince(at) > 7 * 86_400 { sd = nil }
            out[account] = PlanUsage(fiveHour: fh, weekly: sd, sampledAt: at)
        }
        return out
    }
}

import Foundation

// Pure, deterministic notification evaluation and deduplication ledger.
// Never sends notifications directly: `SwitcherApp` feeds live snapshots in and delivers
// returned `AlertEvent`s through `UNUserNotificationCenter` when running inside a `.app` bundle.

public struct AlertPreferences: Equatable, Sendable {
    public var quotaWarning: Bool
    public var quotaReset: Bool
    public var signInExpiry: Bool

    public init(quotaWarning: Bool = true, quotaReset: Bool = true, signInExpiry: Bool = true) {
        self.quotaWarning = quotaWarning
        self.quotaReset = quotaReset
        self.signInExpiry = signInExpiry
    }
}

/// One active window observed for an account (Antigravity, Claude Code, or Codex).
public struct AlertWindowSample: Equatable, Sendable {
    public var tool: String
    public var accountID: String
    public var accountLabel: String
    public var windowLabel: String
    public var usedPercent: Int
    public var resetsAt: Date?
    /// Optional fallback account with more headroom, to include in warning body.
    public var bestFallback: String?

    public init(tool: String, accountID: String, accountLabel: String, windowLabel: String,
                usedPercent: Int, resetsAt: Date? = nil, bestFallback: String? = nil) {
        self.tool = tool
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.windowLabel = windowLabel
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.bestFallback = bestFallback
    }
}

/// One expiring sign-in observed for a CLI or desktop account.
public struct AlertExpirySample: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case cliRefresh
        case desktopSaved
    }

    public var kind: Kind
    public var tool: String
    public var accountID: String
    public var accountLabel: String
    /// Days remaining until expected expiry (for CLI refresh tokens) or remaining of the ~28-day desktop window.
    public var daysLeft: Int
    /// Stable stamp identifying this sign-in epoch (e.g. refresh expiry epoch or `setAsideAt` epoch).
    public var stamp: Int

    public init(kind: Kind, tool: String, accountID: String, accountLabel: String, daysLeft: Int, stamp: Int) {
        self.kind = kind
        self.tool = tool
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.daysLeft = daysLeft
        self.stamp = stamp
    }
}

/// A notification ready to deliver.
public struct AlertEvent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case quotaWarning80
        case quotaCritical95
        case quotaReset
        case signInExpiring
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String

    public init(id: String, kind: Kind, title: String, body: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// Persisted deduplication state in `<state>/alert-state.json` (mode 0600).
public struct AlertLedger: Codable, Equatable, Sendable {
    public struct WindowState: Codable, Equatable, Sendable {
        /// Highest warning tier already notified in this reset cycle (0, 80, or 95).
        public var highestTier: Int
        /// Bucketed reset timestamp (seconds, rounded to 5 minutes) when the warning was issued.
        public var resetBucket: Int?
        public var updatedAt: TimeInterval

        public init(highestTier: Int, resetBucket: Int?, updatedAt: TimeInterval) {
            self.highestTier = highestTier
            self.resetBucket = resetBucket
            self.updatedAt = updatedAt
        }
    }

    public var version = 1
    /// Keyed by `"<tool>:<accountID>:<windowLabel>"`.
    public var windows: [String: WindowState] = [:]
    /// Keyed by `"<kind>:<tool>:<accountID>"` -> notified stamp epoch.
    public var expiries: [String: Int] = [:]

    public init(version: Int = 1, windows: [String: WindowState] = [:], expiries: [String: Int] = [:]) {
        self.version = version
        self.windows = windows
        self.expiries = expiries
    }

    public static func url(_ env: Env) -> URL {
        env.state.appendingPathComponent("alert-state.json")
    }

    public static func load(_ env: Env) -> AlertLedger {
        FS.readCodable(AlertLedger.self, from: url(env)) ?? AlertLedger()
    }

    public func save(_ env: Env) throws {
        try FS.makePrivateDir(env.state)
        try FS.writeCodable(self, to: Self.url(env))
    }

    public mutating func prune(olderThan days: Int = 30, now: Date = Date()) {
        let cutoff = now.timeIntervalSince1970 - Double(days) * 86_400
        windows = windows.filter { $0.value.updatedAt >= cutoff }
    }
}

public enum AlertEngine {
    public static let warnThreshold = 80
    public static let criticalThreshold = 95
    public static let resetThreshold = 15

    /// Round a reset timestamp to a 5-minute bucket so minor server jitter does not trigger duplicate alerts.
    public static func resetBucket(_ date: Date?) -> Int? {
        guard let date else { return nil }
        return Int((date.timeIntervalSince1970 / 300).rounded()) * 300
    }

    /// Evaluates current quota and expiry samples against `ledger`, mutating `ledger` and returning
    /// only new events that have not yet been sent in the current reset cycle / sign-in epoch.
    public static func evaluate(
        windows: [AlertWindowSample],
        expiries: [AlertExpirySample],
        preferences: AlertPreferences,
        ledger: inout AlertLedger,
        now: Date = Date()
    ) -> [AlertEvent] {
        var events: [AlertEvent] = []
        let nowEpoch = now.timeIntervalSince1970

        for sample in windows {
            let key = "\(sample.tool):\(sample.accountID):\(sample.windowLabel)"
            let bucket = resetBucket(sample.resetsAt)
            let prev = ledger.windows[key]

            // Detect cycle reset: previously warned (>= 80), now either dropped to <= 15% or moved to a later reset window.
            let cycleAdvanced: Bool = {
                guard let prevBucket = prev?.resetBucket, let bucket else { return false }
                return bucket > prevBucket + 600
            }()
            let droppedLow = sample.usedPercent <= resetThreshold

            if let prev, prev.highestTier >= warnThreshold, (droppedLow || cycleAdvanced) {
                if preferences.quotaReset {
                    let title = L10n.t("\(sample.tool) quota reset", "\(sample.tool) 配额已重置")
                    let body = L10n.t(
                        "\(sample.accountLabel) (\(sample.windowLabel)) is fresh again.",
                        "\(sample.accountLabel)（\(sample.windowLabel)）已重置，可以继续使用。"
                    )
                    events.append(AlertEvent(
                        id: "reset:\(key):\(bucket ?? Int(nowEpoch))",
                        kind: .quotaReset,
                        title: title,
                        body: body
                    ))
                }
                ledger.windows[key] = AlertLedger.WindowState(highestTier: 0, resetBucket: bucket, updatedAt: nowEpoch)
            }

            // Re-read after potential reset.
            let current = ledger.windows[key]
            let tier: Int = sample.usedPercent >= criticalThreshold ? criticalThreshold
                : sample.usedPercent >= warnThreshold ? warnThreshold : 0

            if tier > 0 {
                let sameCycle = (current?.resetBucket == bucket) || (current?.resetBucket == nil && bucket == nil)
                let prevTier = sameCycle ? (current?.highestTier ?? 0) : 0
                if tier > prevTier {
                    if preferences.quotaWarning {
                        let isCritical = tier >= criticalThreshold
                        let title = isCritical
                            ? L10n.t("\(sample.tool) nearly out (\(sample.usedPercent)%)", "\(sample.tool) 配额即将耗尽（\(sample.usedPercent)%）")
                            : L10n.t("\(sample.tool) running low (\(sample.usedPercent)%)", "\(sample.tool) 配额偏紧（\(sample.usedPercent)%）")
                        let fallbackSuffix: String
                        if let best = sample.bestFallback, !best.isEmpty {
                            fallbackSuffix = L10n.t(" Most room: \(best).", " 余量最多：\(best)。")
                        } else {
                            fallbackSuffix = ""
                        }
                        let body = L10n.t(
                            "\(sample.accountLabel) reached \(sample.usedPercent)% on \(sample.windowLabel).\(fallbackSuffix)",
                            "\(sample.accountLabel) 的 \(sample.windowLabel) 已用 \(sample.usedPercent)%。\(fallbackSuffix)"
                        )
                        events.append(AlertEvent(
                            id: "warn:\(key):\(tier):\(bucket ?? 0)",
                            kind: isCritical ? .quotaCritical95 : .quotaWarning80,
                            title: title,
                            body: body
                        ))
                    }
                    ledger.windows[key] = AlertLedger.WindowState(highestTier: tier, resetBucket: bucket, updatedAt: nowEpoch)
                }
            }
        }

        if preferences.signInExpiry {
            for item in expiries where item.daysLeft <= 4 {
                let key = "\(item.kind.rawValue):\(item.tool):\(item.accountID)"
                if ledger.expiries[key] == item.stamp { continue }
                ledger.expiries[key] = item.stamp
                let title = L10n.t("\(item.tool) sign-in expiring soon", "\(item.tool) 登录即将失效")
                let body: String
                switch item.kind {
                case .cliRefresh:
                    if item.daysLeft <= 0 {
                        body = L10n.t(
                            "\(item.accountLabel)'s sign-in has expired. Sign in again to keep using it.",
                            "\(item.accountLabel) 的登录已失效，请重新登录。"
                        )
                    } else {
                        body = L10n.t(
                            "\(item.accountLabel) expires in \(item.daysLeft) day(s) unless used.",
                            "\(item.accountLabel) 将在 \(item.daysLeft) 天后失效，使用一次或续期即可保持有效。"
                        )
                    }
                case .desktopSaved:
                    body = L10n.t(
                        "\(item.accountLabel)'s saved sign-in is nearly 28 days old and may expire soon.",
                        "\(item.accountLabel) 保存的登录已接近 28 天，建议切换登录一次以免过期。"
                    )
                }
                events.append(AlertEvent(
                    id: "expiry:\(key):\(item.stamp)",
                    kind: .signInExpiring,
                    title: title,
                    body: body
                ))
            }
        }

        ledger.prune(now: now)
        return events
    }
}

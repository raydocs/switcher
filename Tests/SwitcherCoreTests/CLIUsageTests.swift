import Foundation
import Testing
@testable import SwitcherCore

/// Headroom, pace, the background refresh rule and the usage report. Temporary HOME, fixed dates.
@Suite struct CLIUsageTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func w(_ label: String, _ used: Double, resetsIn: TimeInterval?) -> CLIQuotaWindow {
        CLIQuotaWindow(label: label, usedPercent: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    func q(_ windows: [CLIQuotaWindow], age: TimeInterval = 60) -> CLIQuota {
        CLIQuota(windows: windows, source: "test", observedAt: now.addingTimeInterval(-age))
    }

    @Test func theTightestMainWindowDecides() {
        let h = CLIUsage.headroom(q([w("5h", 30, resetsIn: 3600), w("week", 85, resetsIn: 86400), w("week (Opus)", 95, resetsIn: 86400)]),
                                  signedIn: true, now: now, lastActivity: nil)
        #expect(h.status == .low)
        #expect(h.tightest?.label == "week")
        #expect(h.percentLeft == 15)
        #expect(h.scopedWarning?.label == "week (Opus)")
        #expect(CLIUsage.headroom(q([w("5h", 100, resetsIn: 60)]), signedIn: true, now: now, lastActivity: nil).status == .out)
        #expect(CLIUsage.headroom(q([w("300m", 10, resetsIn: 60), w("spark 300m", 99, resetsIn: 60)]), signedIn: true, now: now, lastActivity: nil).status == .ok)
    }

    @Test func unknownWithoutSignInDataOrMainWindow() {
        let quota = q([w("5h", 10, resetsIn: 60)])
        #expect(CLIUsage.headroom(quota, signedIn: false, now: now, lastActivity: nil) == .unknown)
        #expect(CLIUsage.headroom(nil, signedIn: true, now: now, lastActivity: nil) == .unknown)
        #expect(CLIUsage.headroom(q([w("week (Opus)", 10, resetsIn: 60)]), signedIn: true, now: now, lastActivity: nil).status == .unknown)
    }

    @Test func aPassedResetIsZeroOnlyWhenNothingRanSince() {
        let quota = q([w("5h", 90, resetsIn: -600), w("week", 40, resetsIn: 86400)], age: 3600)
        // Nothing ran after the 5-hour reset: it is back to 0, so the week decides.
        let quiet = CLIUsage.headroom(quota, signedIn: true, now: now, lastActivity: now.addingTimeInterval(-1200))
        #expect(quiet.tightest?.label == "week")
        #expect(CLIUsage.current(quota, now: now, lastActivity: now.addingTimeInterval(-1200)).first == CLIQuotaWindow(label: "5h", usedPercent: 0, resetsAt: nil))
        // Something ran after it, or nobody knows: the window is dropped, never guessed.
        #expect(CLIUsage.current(quota, now: now, lastActivity: now.addingTimeInterval(-60)).map(\.label) == ["week"])
        #expect(CLIUsage.current(quota, now: now, lastActivity: nil).map(\.label) == ["week"])
    }

    @Test func paceIsTheShareOfTheWindowGoneBy() {
        #expect(CLIUsage.pace(w("5h", 0, resetsIn: 3600 * 4), now: now) == 20)
        #expect(CLIUsage.pace(w("week", 0, resetsIn: 7 * 86400 / 2), now: now) == 50)
        #expect(CLIUsage.pace(w("300m", 0, resetsIn: 150 * 60), now: now) == 50)
        #expect(CLIUsage.pace(w("5h", 0, resetsIn: nil), now: now) == nil)
        #expect(CLIUsage.pace(w("odd", 0, resetsIn: 60), now: now) == nil)
        let zeroMin = w("0m", 0, resetsIn: 60)
        #expect(!CLIUsage.isMain(zeroMin) && CLIUsage.duration(zeroMin) == nil)
    }

    @Test func scopePartsSplitsEveryWindowShape() {
        #expect(CLIUsage.scopeParts("") == CLIUsage.ScopeParts(name: "", window: nil, isWeeklyModel: false))
        #expect(CLIUsage.scopeParts("   ") == CLIUsage.ScopeParts(name: "", window: nil, isWeeklyModel: false))
        #expect(CLIUsage.scopeParts("5h") == CLIUsage.ScopeParts(name: "5h", window: nil, isWeeklyModel: false))
        #expect(CLIUsage.scopeParts("week") == CLIUsage.ScopeParts(name: "week", window: nil, isWeeklyModel: false))
        #expect(CLIUsage.scopeParts("45m") == CLIUsage.ScopeParts(name: "45m", window: nil, isWeeklyModel: false))
        #expect(CLIUsage.scopeParts("week (Opus)") == CLIUsage.ScopeParts(name: "Opus", window: nil, isWeeklyModel: true))
        #expect(CLIUsage.scopeParts("week ()") == CLIUsage.ScopeParts(name: "scoped", window: nil, isWeeklyModel: true))
        #expect(CLIUsage.scopeParts("Spark 45m") == CLIUsage.ScopeParts(name: "Spark", window: "45m", isWeeklyModel: false))
        #expect(CLIUsage.scopeParts("GPT-5.3-Codex-Spark 5h") == CLIUsage.ScopeParts(name: "GPT-5.3-Codex-Spark", window: "5h", isWeeklyModel: false))
        #expect(CLIUsage.scopeParts("Fast 5h week") == CLIUsage.ScopeParts(name: "Fast 5h", window: "week", isWeeklyModel: false))
        #expect(CLIUsage.scopeParts("Pro 5h") == CLIUsage.ScopeParts(name: "Pro", window: "5h", isWeeklyModel: false))
        #expect(CLIUsage.scopeParts("Claude week") == CLIUsage.ScopeParts(name: "Claude", window: "week", isWeeklyModel: false))
        #expect(CLIUsage.scopeParts("credits") == CLIUsage.ScopeParts(name: "credits", window: nil, isWeeklyModel: false))
        #expect(CLIUsage.scopeParts("Code Review daily") == CLIUsage.ScopeParts(name: "Code Review daily", window: nil, isWeeklyModel: false))
    }

    @Test func theBestAccountHasTheMostRoomAndIsKnown() {
        func h(_ s: CLIHeadroom.Status, _ left: Double?) -> CLIHeadroom { CLIHeadroom(status: s, tightest: nil, percentLeft: left, scopedWarning: nil) }
        #expect(CLIUsage.best([("a", h(.ok, 40)), ("b", h(.ok, 70)), ("c", h(.unknown, nil)), ("d", h(.out, 0))]) == "b")
        #expect(CLIUsage.best([("a", h(.low, 10)), ("b", h(.low, 10))]) == "a")
        #expect(CLIUsage.best([("c", h(.unknown, nil)), ("d", h(.out, 0))]) == nil)
    }

    // MARK: Refresh rule

    func s(_ id: String, active: Bool, seenAgo: TimeInterval?, triedAgo: TimeInterval? = nil, failures: Int = 0, signedIn: Bool = true) -> CLIRefreshState {
        CLIRefreshState(id: id, isActive: active, signedIn: signedIn, observedAt: seenAgo.map { now.addingTimeInterval(-$0) },
                        lastAttempt: triedAgo.map { now.addingTimeInterval(-$0) }, failures: failures)
    }

    @Test func idleMeansNoReads() {
        // Read 10 minutes ago, nothing ran since: nothing to do, active or not.
        let accounts = [s("a", active: true, seenAgo: 600, triedAgo: 600), s("b", active: false, seenAgo: 7200)]
        #expect(CLIRefreshPlan.due(accounts, activeStatus: .ok, lastActivity: now.addingTimeInterval(-900), lowPower: false, now: now).isEmpty)
    }

    @Test func activityOrAgeReadsTheActiveAccountOnly() {
        let accounts = [s("a", active: true, seenAgo: 600, triedAgo: 600), s("b", active: false, seenAgo: 7200)]
        #expect(CLIRefreshPlan.due(accounts, activeStatus: .ok, lastActivity: now.addingTimeInterval(-60), lowPower: false, now: now) == ["a"])
        let old = [s("a", active: true, seenAgo: 1900, triedAgo: 1900)]
        #expect(CLIRefreshPlan.due(old, activeStatus: .ok, lastActivity: nil, lowPower: false, now: now) == ["a"])
        // Low Power Mode doubles the age.
        #expect(CLIRefreshPlan.due(old, activeStatus: .ok, lastActivity: nil, lowPower: true, now: now).isEmpty)
        // Never within 5 minutes of the last try, however busy the CLI is.
        let recent = [s("a", active: true, seenAgo: 200, triedAgo: 200)]
        #expect(CLIRefreshPlan.due(recent, activeStatus: .ok, lastActivity: now, lowPower: false, now: now).isEmpty)
        // Signed out: never.
        #expect(CLIRefreshPlan.due([s("a", active: true, seenAgo: nil, signedIn: false)], activeStatus: .ok, lastActivity: now, lowPower: false, now: now).isEmpty)
    }

    @Test func aLowActiveAccountReadsTheOthersToo() {
        let accounts = [s("a", active: true, seenAgo: 400, triedAgo: 400), s("b", active: false, seenAgo: 2000), s("c", active: false, seenAgo: 600), s("d", active: false, seenAgo: nil)]
        #expect(CLIRefreshPlan.due(accounts, activeStatus: .low, lastActivity: nil, lowPower: false, now: now) == ["b", "d"])
        #expect(CLIRefreshPlan.due(accounts, activeStatus: .ok, lastActivity: nil, lowPower: false, now: now).isEmpty)
    }

    @Test func failuresBackOffAndARateLimitWaitsAnHour() {
        #expect(CLIQuotaError.unavailable("Claude usage HTTP 429; do not poll or retry now.").isRateLimited)
        #expect(!CLIQuotaError.unavailable("Claude usage HTTP 500.").isRateLimited)
        #expect(!CLIQuotaError.signInExpired.isRateLimited)
        #expect(CLIRefreshPlan.backoff(failures: 0) == 0)
        #expect(CLIRefreshPlan.backoff(failures: 1) == 300)
        #expect(CLIRefreshPlan.backoff(failures: 3) == 1200)
        #expect(CLIRefreshPlan.backoff(failures: CLIRefreshPlan.rateLimitedFailures) == 3600)
        // Every automatic read (opening the menu too) waits the backoff out.
        let limitedAt = now.addingTimeInterval(-600)
        #expect(CLIRefreshPlan.backingOff(lastAttempt: limitedAt, failures: CLIRefreshPlan.rateLimitedFailures, now: now))
        #expect(!CLIRefreshPlan.backingOff(lastAttempt: limitedAt, failures: 1, now: now))
        // Finding #22: Low Power Mode doubles backoff, and backward clock jumps clamp negative elapsed time.
        let fourHundredAgo = now.addingTimeInterval(-400)
        #expect(!CLIRefreshPlan.backingOff(lastAttempt: fourHundredAgo, failures: 1, lowPower: false, now: now))
        #expect(CLIRefreshPlan.backingOff(lastAttempt: fourHundredAgo, failures: 1, lowPower: true, now: now))
        let futureAttempt = now.addingTimeInterval(3600)
        #expect(CLIRefreshPlan.backingOff(lastAttempt: futureAttempt, failures: 1, lowPower: false, now: now))
        #expect(!CLIRefreshPlan.backingOff(lastAttempt: limitedAt, failures: 0, now: now))
        #expect(!CLIRefreshPlan.backingOff(lastAttempt: nil, failures: 5, now: now))
        let failing = [s("a", active: true, seenAgo: 4000, triedAgo: 900, failures: 3)]
        #expect(CLIRefreshPlan.due(failing, activeStatus: .ok, lastActivity: now, lowPower: false, now: now).isEmpty)
        let limited = [s("a", active: true, seenAgo: 4000, triedAgo: 3000, failures: CLIRefreshPlan.rateLimitedFailures)]
        #expect(CLIRefreshPlan.due(limited, activeStatus: .ok, lastActivity: now, lowPower: false, now: now).isEmpty)
        let waited = [s("a", active: true, seenAgo: 4000, triedAgo: 3700, failures: CLIRefreshPlan.rateLimitedFailures)]
        #expect(CLIRefreshPlan.due(waited, activeStatus: .ok, lastActivity: now, lowPower: false, now: now) == ["a"])
    }

    // MARK: Activity and the report

    func touch(_ path: String, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    @Test func activityIsTheNewestSharedFile() {
        let box = CLIBox()
        #expect(CLIUsage.lastActivity(.codex, env: box.env, now: now) == nil)
        box.write(box.home + "/.claude/history.jsonl", "{}\n")
        touch(box.home + "/.claude/history.jsonl", now.addingTimeInterval(-100))
        #expect(CLIUsage.lastActivity(.claude, env: box.env, now: now) == now.addingTimeInterval(-100))

        box.write(box.home + "/.codex/history.jsonl", "{}\n")
        touch(box.home + "/.codex/history.jsonl", now.addingTimeInterval(-9000))
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let today = String(format: "%@/.codex/sessions/%04d/%02d/%02d", box.home, c.year!, c.month!, c.day!)
        box.write(today + "/rollout-1.jsonl", "{}\n")
        touch(today + "/rollout-1.jsonl", now.addingTimeInterval(-30))
        #expect(CLIUsage.lastActivity(.codex, env: box.env, now: now) == now.addingTimeInterval(-30))

        #expect(CLIUsage.lastActivity(.agy, env: box.env, now: now) == nil)
        box.write(box.home + "/.gemini/antigravity-cli/cache/projects.json", "{}\n")
        touch(box.home + "/.gemini/antigravity-cli/cache/projects.json", now.addingTimeInterval(-200))
        box.write(box.home + "/.gemini/antigravity-cli/conversations/conv-1.pb", "x")
        touch(box.home + "/.gemini/antigravity-cli/conversations/conv-1.pb", now.addingTimeInterval(-15))
        #expect(CLIUsage.lastActivity(.agy, env: box.env, now: now) == now.addingTimeInterval(-15))
    }

    @Test func theReportComesFromTheCacheAndHoldsNoSecrets() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let secret = "sk-SECRET-refresh-token"
        func signIn(_ p: CLIProfile, account: String, email: String) {
            box.write(p.path + "/auth.json", box.json(["auth_mode": "chatgpt", "tokens": ["id_token": fakeJWT(["email": email]), "refresh_token": secret, "access_token": secret, "account_id": account]]))
        }
        let def = profiles.defaultProfile(.codex)
        let two = try profiles.add(.codex, name: "account2")
        let three = try profiles.add(.codex, name: "account3")
        signIn(def, account: "acct-1", email: "one@example.com")
        signIn(two, account: "acct-2", email: "two@example.com")
        let cache = CLIQuotaCache(env: box.env)
        try cache.store(q([w("300m", 85, resetsIn: 3600), w("10080m", 50, resetsIn: 86400)]), for: def, accountKey: "acct-1")
        try cache.store(q([w("300m", 20, resetsIn: 3600), w("10080m", 30, resetsIn: 86400)], age: 3600), for: two, accountKey: "acct-2")
        // A reading for another account the folder is no longer signed in to is not used.
        try cache.store(q([w("300m", 1, resetsIn: 3600)]), for: three, accountKey: "acct-old")

        let report = CLIUsageReport.build(profiles: profiles, kinds: [.codex], now: now, errors: [two.id: "HTTP 500"])
        let codex = try #require(report.clis.first)
        #expect(codex.best == "account2")
        #expect(codex.accounts.map(\.status) == [.low, .ok, .unknown])
        #expect(codex.accounts[0].active && !codex.accounts[1].active)
        #expect(codex.accounts[1].stale)
        #expect(codex.accounts[1].error == "HTTP 500")
        #expect(codex.accounts[1].percentLeft == 70)
        #expect(codex.accounts[0].windows.first?.pacePercent == 80)
        #expect(codex.accounts[2].windows.isEmpty)
        #expect(codex.accounts[0].signedIn == nil)

        let text = report.json()
        #expect(!text.contains(secret))
        #expect(text.contains("\"schema\" : \"switcher.usage.v1\""))
        let back = try JSONDecoder.iso.decode(CLIUsageReport.self, from: Data(text.utf8))
        #expect(back.clis.first?.best == "account2")
    }

    // Findings #9 & #18: active profile is included in `best`, and `--cached` never marks signed-out file profiles as ok/best.
    @Test func reportIncludesActiveInBestAndChecksFileBackedCachedSignIn() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let def = profiles.defaultProfile(.codex)
        let two = try profiles.add(.codex, name: "account2")
        let three = try profiles.add(.codex, name: "account3")
        box.write(def.path + "/auth.json", box.json(["auth_mode": "chatgpt", "tokens": ["refresh_token": "r", "account_id": "a1"]]))
        box.write(two.path + "/auth.json", box.json(["auth_mode": "chatgpt", "tokens": ["refresh_token": "r", "account_id": "a2"]]))
        // account3 lost its refresh token (signed out), even though a nil-keyed cache entry exists.
        box.write(three.path + "/auth.json", box.json([:]))

        let cache = CLIQuotaCache(env: box.env)
        try cache.store(q([w("5h", 15, resetsIn: 3600)]), for: def, accountKey: "a1")
        try cache.store(q([w("5h", 70, resetsIn: 3600)]), for: two, accountKey: "a2")
        try cache.store(q([w("5h", 1, resetsIn: 3600)]), for: three, accountKey: nil)

        // `--cached` passes keychain: nil, signedIn: nil; file-backed profiles still verify local credentials.
        let report = CLIUsageReport.build(profiles: profiles, kinds: [.codex], now: now)
        let codex = try #require(report.clis.first)
        #expect(codex.best == "default")
        #expect(codex.accounts[2].status == .unknown)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

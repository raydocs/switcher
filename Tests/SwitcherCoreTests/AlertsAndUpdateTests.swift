import Foundation
import Testing
@testable import SwitcherCore

@Suite(.serialized) struct AlertEngineTests {
    @Test func warnsAt80And95OncePerCycleAndNotifiesOnReset() throws {
        defer { L10n.override = nil }
        L10n.override = .en

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let reset1 = t0.addingTimeInterval(3600)
        var ledger = AlertLedger()
        let prefs = AlertPreferences(quotaWarning: true, quotaReset: true, signInExpiry: true)

        // Below threshold: silent.
        let s1 = AlertWindowSample(tool: "Claude Code", accountID: "claude:default", accountLabel: "default",
                                   windowLabel: "5h", usedPercent: 79, resetsAt: reset1, bestFallback: "team")
        #expect(AlertEngine.evaluate(windows: [s1], expiries: [], preferences: prefs, ledger: &ledger, now: t0).isEmpty)

        // Crosses 80%: one warning mentioning the fallback account.
        let s2 = AlertWindowSample(tool: "Claude Code", accountID: "claude:default", accountLabel: "default",
                                   windowLabel: "5h", usedPercent: 82, resetsAt: reset1, bestFallback: "team")
        let e2 = AlertEngine.evaluate(windows: [s2], expiries: [], preferences: prefs, ledger: &ledger, now: t0.addingTimeInterval(60))
        #expect(e2.count == 1)
        #expect(e2[0].kind == .quotaWarning80)
        #expect(e2[0].body.contains("team"))

        // Same cycle + tiny server reset jitter (15s): no duplicate 80% warning.
        let s3 = AlertWindowSample(tool: "Claude Code", accountID: "claude:default", accountLabel: "default",
                                   windowLabel: "5h", usedPercent: 88, resetsAt: reset1.addingTimeInterval(15), bestFallback: "team")
        #expect(AlertEngine.evaluate(windows: [s3], expiries: [], preferences: prefs, ledger: &ledger, now: t0.addingTimeInterval(120)).isEmpty)

        // Escalates to 95%: fires critical once.
        let s4 = AlertWindowSample(tool: "Claude Code", accountID: "claude:default", accountLabel: "default",
                                   windowLabel: "5h", usedPercent: 96, resetsAt: reset1, bestFallback: "team")
        let e4 = AlertEngine.evaluate(windows: [s4], expiries: [], preferences: prefs, ledger: &ledger, now: t0.addingTimeInterval(180))
        #expect(e4.count == 1)
        #expect(e4[0].kind == .quotaCritical95)

        // Repeated 100% in same cycle: no spam.
        let s5 = AlertWindowSample(tool: "Claude Code", accountID: "claude:default", accountLabel: "default",
                                   windowLabel: "5h", usedPercent: 100, resetsAt: reset1, bestFallback: "team")
        #expect(AlertEngine.evaluate(windows: [s5], expiries: [], preferences: prefs, ledger: &ledger, now: t0.addingTimeInterval(240)).isEmpty)

        // Window resets (drops to 0% with new reset time): fires one reset recovery alert.
        let reset2 = reset1.addingTimeInterval(5 * 3600)
        let s6 = AlertWindowSample(tool: "Claude Code", accountID: "claude:default", accountLabel: "default",
                                   windowLabel: "5h", usedPercent: 0, resetsAt: reset2, bestFallback: nil)
        let e6 = AlertEngine.evaluate(windows: [s6], expiries: [], preferences: prefs, ledger: &ledger, now: reset1.addingTimeInterval(60))
        #expect(e6.count == 1)
        #expect(e6[0].kind == .quotaReset)

        // Repeated low reading after reset does not fire reset again.
        #expect(AlertEngine.evaluate(windows: [s6], expiries: [], preferences: prefs, ledger: &ledger, now: reset1.addingTimeInterval(120)).isEmpty)

        // Ledger persists atomically with mode 0600 and survives reload.
        let box = Sandbox()
        try ledger.save(box.env)
        let loaded = AlertLedger.load(box.env)
        #expect(loaded == ledger)
        var st = stat()
        #expect(stat(AlertLedger.url(box.env).path, &st) == 0 && (st.st_mode & 0o777) == 0o600)
    }

    @Test func respectsPreferencesAndDeduplicatesExpiries() {
        defer { L10n.override = nil }
        L10n.override = .en

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = AlertLedger()
        let expiry = AlertExpirySample(kind: .cliRefresh, tool: "Claude Code", accountID: "claude:work",
                                       accountLabel: "team", daysLeft: 3, stamp: 1_800_259_200)
        let disabled = AlertPreferences(quotaWarning: false, quotaReset: false, signInExpiry: false)
        #expect(AlertEngine.evaluate(windows: [], expiries: [expiry], preferences: disabled, ledger: &ledger, now: now).isEmpty)

        let enabled = AlertPreferences(quotaWarning: false, quotaReset: false, signInExpiry: true)
        let e1 = AlertEngine.evaluate(windows: [], expiries: [expiry], preferences: enabled, ledger: &ledger, now: now)
        #expect(e1.count == 1 && e1[0].kind == .signInExpiring)
        // Same stamp does not fire twice.
        #expect(AlertEngine.evaluate(windows: [], expiries: [expiry], preferences: enabled, ledger: &ledger, now: now.addingTimeInterval(3600)).isEmpty)
        // New stamp (after renew) fires again when it later approaches expiry.
        let renewed = AlertExpirySample(kind: .cliRefresh, tool: "Claude Code", accountID: "claude:work",
                                        accountLabel: "team", daysLeft: 2, stamp: 1_805_000_000)
        let e2 = AlertEngine.evaluate(windows: [], expiries: [renewed], preferences: enabled, ledger: &ledger, now: now.addingTimeInterval(86400))
        #expect(e2.count == 1 && e2[0].kind == .signInExpiring)
    }
}

@Suite struct UpdateCheckerTests {
    @Test func semVerParsesAndComparesCorrectly() {
        #expect(SemVer("v1.2.3") == SemVer("1.2.3"))
        #expect(SemVer("1.2") == SemVer("1.2.0"))
        #expect(SemVer("1.2.0")! < SemVer("1.10.0")!)
        #expect(SemVer("1.2.0-beta.1")! < SemVer("1.2.0")!)
        #expect(SemVer("dev") == nil)
        #expect(SemVer("not.a.ver") == nil)
    }

    @Test func checksGitHubLatestReleaseCleanly() async {
        final class MockHTTP: HTTPGetter, @unchecked Sendable {
            var status = 200
            var body = Data()
            var fail = false
            func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
                if fail { throw URLError(.notConnectedToInternet) }
                return (status, body)
            }
        }
        let http = MockHTTP()
        http.body = Data(#"{"tag_name":"v1.4.0","name":"Switcher 1.4.0","html_url":"https://github.com/raydocs/switcher/releases/tag/v1.4.0"}"#.utf8)

        let avail = await UpdateChecker.check(currentVersion: "1.3.2", http: http)
        if case .updateAvailable(let cur, let rel) = avail {
            #expect(cur == "1.3.2")
            #expect(rel.tagName == "v1.4.0")
        } else {
            Issue.record("expected updateAvailable, got \(avail)")
        }

        let upToDate = await UpdateChecker.check(currentVersion: "1.4.0", http: http)
        #expect(upToDate == .upToDate(current: "1.4.0", latest: "v1.4.0"))

        http.status = 404
        #expect(await UpdateChecker.check(currentVersion: "1.4.0", http: http) == .noReleases)

        http.fail = true
        if case .failed = await UpdateChecker.check(currentVersion: "1.4.0", http: http) {
            // expected
        } else {
            Issue.record("expected failed on transport error")
        }
    }
}

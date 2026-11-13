import Foundation
import Testing
@testable import SwitcherCore

final class QuotaFakeHTTP: HTTPGetter, @unchecked Sendable {
    var status = 200
    var body = Data()
    var fail = false
    var calls: [(url: URL, headers: [String: String])] = []
    /// Runs while the request is "in flight" (an account switch mid-read).
    var onGet: (() -> Void)?

    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        calls.append((url, headers))
        onGet?()
        if fail { throw URLError(.timedOut) }
        return (status, body)
    }
}

final class QuotaBox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-quota-\(UUID().uuidString)", isDirectory: true)
    let env: CLIEnv
    let profiles: CLIProfiles
    let keychain = MemoryCLIKeychain()
    let http = QuotaFakeHTTP()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let token = "sk-ant-oat01-TOPSECRET"

    init() {
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        env = CLIEnv(home: root.path)
        profiles = CLIProfiles(env: env)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func claude(_ name: String? = "work") -> CLIProfile {
        guard let name else { return profiles.defaultProfile(.claude) }
        return try! profiles.add(.claude, name: name)
    }

    func codex(_ name: String = "work") -> CLIProfile { try! profiles.add(.codex, name: name) }

    func write(_ path: String, _ text: String) {
        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    func account(_ p: CLIProfile, _ uuid: String) {
        write(p.path + "/.claude.json", #"{"oauthAccount":{"accountUuid":"\#(uuid)","organizationUuid":"o","emailAddress":"x@example.com"}}"#)
    }

    func credentials(_ p: CLIProfile, expiresIn: TimeInterval = 3600) {
        let ms = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
        keychain.items[claudeKeychainService(configDir: p.envValue)] =
            #"{"claudeAiOauth":{"accessToken":"\#(Self.token)","refreshToken":"rt-SECRET","expiresAt":\#(ms),"subscriptionType":"max"}}"#
    }

    /// A statusline copy captured `age` seconds ago; windows reset `five`/`seven` seconds from now.
    func statusline(_ p: CLIProfile, age: TimeInterval, five: TimeInterval = 3600, seven: TimeInterval = 86_400) {
        let captured = ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))
        let t = now.timeIntervalSince1970
        write(p.path + "/rate-limits.json", """
        {"capturedAt":"\(captured)","rate_limits":{
         "five_hour":{"used_percentage":42.5,"resets_at":\(Int(t + five))},
         "seven_day":{"used_percentage":10,"resets_at":\(Int(t + seven))}}}
        """)
    }

    func read(_ p: CLIProfile) async throws -> CLIQuota {
        try await ClaudeCodeQuota.read(profile: p, profiles: profiles, keychain: keychain, http: http, now: now)
    }
}

@Suite struct ClaudeQuotaTests {
    static let limitsShape = """
    {"limits":[
      {"kind":"session","percent":30,"resets_at":"2026-11-12T05:00:00Z"},
      {"kind":"weekly_all","percent":55.5,"resets_at":"2026-11-15T00:00:00.000Z"},
      {"kind":"weekly_scoped","percent":80,"resets_at":"2026-11-15T00:00:00Z","scope":{"model":{"id":"opus","display_name":"Opus"}}},
      {"kind":"weekly_scoped","percent":101,"resets_at":null},
      {"kind":"mystery","percent":1}]}
    """
    static let namedShape = """
    {"five_hour":{"utilization":12,"resets_at":"2026-11-12T05:00:00Z"},
     "seven_day":{"utilization":34,"resets_at":null},
     "seven_day_opus":{"utilization":56,"resets_at":"2026-11-15T00:00:00Z"},
     "seven_day_sonnet":{"utilization":-3,"resets_at":"2026-11-15T00:00:00Z"}}
    """

    @Test func freshStatuslineAnswersWithoutARequest() async throws {
        let b = QuotaBox(), p = b.claude()
        b.statusline(p, age: 60)
        b.credentials(p)
        let q = try await b.read(p)
        #expect(q.source == "statusline")
        #expect(q.plan == "max")
        #expect(q.windows.map(\.label) == ["5h", "week"])
        #expect(q.windows[0].usedPercent == 42.5)
        #expect(q.windows[0].resetsAt == b.now.addingTimeInterval(3600).roundedToSecond)
        #expect(q.observedAt == b.now.addingTimeInterval(-60).roundedToSecond)
        #expect(b.http.calls.isEmpty)
    }

    @Test func freshStatuslineNeedsNoCredentials() async throws {
        let b = QuotaBox(), p = b.claude()
        b.statusline(p, age: 10)
        let q = try await b.read(p)
        #expect(q.source == "statusline" && q.plan == nil)
        #expect(b.http.calls.isEmpty)
    }

    @Test func staleStatuslineIsReplacedByTheEndpoint() async throws {
        let b = QuotaBox(), p = b.claude()
        b.statusline(p, age: 600)
        b.credentials(p)
        b.http.body = Data(Self.namedShape.utf8)
        let q = try await b.read(p)
        #expect(q.source == "usage endpoint")
        #expect(b.http.calls.count == 1)
    }

    @Test func windowsPastTheirResetAreDropped() async throws {
        let b = QuotaBox(), p = b.claude()
        b.statusline(p, age: 60, five: -10, seven: 86_400)
        let q = try await b.read(p)
        #expect(q.windows.map(\.label) == ["week"])
        // Every window past its reset: no statusline reading at all.
        b.statusline(p, age: 60, five: -10, seven: -1)
        await #expect(throws: CLIQuotaError.signedOut) { try await b.read(p) }
        #expect(b.http.calls.isEmpty)
    }

    @Test func futureDatedStatuslineIsIgnored() async throws {
        let b = QuotaBox(), p = b.claude()
        b.statusline(p, age: -3600)
        await #expect(throws: CLIQuotaError.signedOut) { try await b.read(p) }
    }

    @Test func endpointLimitsShape() async throws {
        let b = QuotaBox(), p = b.claude()
        b.credentials(p)
        b.http.body = Data(Self.limitsShape.utf8)
        let q = try await b.read(p)
        #expect(q.source == "usage endpoint" && q.observedAt == b.now && q.plan == "max")
        // 101 % and the unknown kind are rejected.
        #expect(q.windows.map(\.label) == ["5h", "week", "week (Opus)"])
        #expect(q.windows.map(\.usedPercent) == [30, 55.5, 80])
        #expect(q.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-11-12T05:00:00Z"))
        #expect(q.windows[1].resetsAt == ISO8601DateFormatter.lenient("2026-11-15T00:00:00.000Z"))
    }

    @Test func endpointNamedShape() async throws {
        let b = QuotaBox(), p = b.claude()
        b.credentials(p)
        b.http.body = Data(Self.namedShape.utf8)
        let q = try await b.read(p)
        // -3 % is rejected.
        #expect(q.windows.map(\.label) == ["5h", "week", "week (Opus)"])
        #expect(q.windows[1].resetsAt == nil)
    }

    @Test func endpointRequestCarriesTheTokenAndBetaHeader() async throws {
        let b = QuotaBox(), p = b.claude()
        b.credentials(p)
        b.http.body = Data(Self.namedShape.utf8)
        _ = try await b.read(p)
        #expect(b.http.calls.count == 1)
        #expect(b.http.calls[0].url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(b.http.calls[0].headers["Authorization"] == "Bearer \(QuotaBox.token)")
        #expect(b.http.calls[0].headers["anthropic-beta"] == "oauth-2025-04-20")
    }

    // Review finding 6: a response for an account that changed mid-read is not accepted.
    @Test func anAccountChangeDuringTheReadIsRejected() async throws {
        let b = QuotaBox(), p = b.claude()
        b.credentials(p)
        b.account(p, "A")
        b.http.body = Data(Self.namedShape.utf8)
        b.http.onGet = { b.account(p, "B") }
        await #expect(throws: CLIQuotaError.unavailable("the account changed during the read; try again")) { try await b.read(p) }
    }

    @Test func aTokenChangeDuringTheReadIsRejected() async throws {
        let b = QuotaBox(), p = b.claude()
        b.credentials(p)
        b.account(p, "A")
        b.http.body = Data(Self.namedShape.utf8)
        b.http.onGet = { b.keychain.items[claudeKeychainService(configDir: p.envValue)] = #"{"claudeAiOauth":{"accessToken":"other","expiresAt":9999999999999}}"# }
        await #expect(throws: CLIQuotaError.unavailable("the account changed during the read; try again")) { try await b.read(p) }
        // Unchanged credentials still read.
        b.http.onGet = nil
        b.credentials(p)
        #expect(try await b.read(p).windows.isEmpty == false)
    }

    @Test func tokenFromThePlaintextFileFallbackWorksToo() async throws {
        let b = QuotaBox(), p = b.claude()
        let ms = Int((b.now.timeIntervalSince1970 + 3600) * 1000)
        b.write(p.path + "/.credentials.json", #"{"claudeAiOauth":{"accessToken":"file-token","expiresAt":\#(ms)}}"#)
        b.http.body = Data(Self.namedShape.utf8)
        _ = try await b.read(p)
        #expect(b.http.calls[0].headers["Authorization"] == "Bearer file-token")
    }

    @Test func http429WithoutFallbackThrowsAClearError() async throws {
        let b = QuotaBox(), p = b.claude()
        b.credentials(p)
        b.http.status = 429
        do {
            _ = try await b.read(p)
            Issue.record("expected an error")
        } catch let e as CLIQuotaError {
            #expect(e.errorDescription?.contains("429") == true)
            #expect(e.errorDescription?.contains("do not poll or retry") == true)
        }
        #expect(b.http.calls.count == 1)
    }

    @Test func http429FallsBackToAStatuslineUpTo15MinutesOld() async throws {
        let b = QuotaBox(), p = b.claude()
        b.credentials(p)
        b.http.status = 429
        b.statusline(p, age: 10 * 60)
        let q = try await b.read(p)
        #expect(q.source == "statusline" && q.plan == "max")
        #expect(q.observedAt == b.now.addingTimeInterval(-600).roundedToSecond)
    }

    @Test func tooOldStatuslineDoesNotStandInForCurrentQuota() async throws {
        let b = QuotaBox(), p = b.claude()
        b.credentials(p)
        b.http.status = 429
        b.statusline(p, age: 16 * 60)
        do {
            _ = try await b.read(p)
            Issue.record("expected an error")
        } catch let e as CLIQuotaError {
            #expect(e.errorDescription?.contains("too old") == true)
        }
    }

    @Test func transportFailureAndBadBodyFallBackOrThrow() async throws {
        let b = QuotaBox(), p = b.claude()
        b.credentials(p)
        b.http.fail = true
        await #expect(throws: CLIQuotaError.self) { try await b.read(p) }
        b.http.fail = false
        b.http.body = Data("not json".utf8)
        await #expect(throws: CLIQuotaError.self) { try await b.read(p) }
        b.statusline(p, age: 400)
        #expect(try await b.read(p).source == "statusline")
    }

    @Test func expiredTokenThrowsSignInExpiredWithoutARequest() async throws {
        let b = QuotaBox(), p = b.claude()
        b.credentials(p, expiresIn: -1)
        await #expect(throws: CLIQuotaError.signInExpired) { try await b.read(p) }
        // Even with an older statusline: the sign-in problem is not hidden.
        b.statusline(p, age: 400)
        await #expect(throws: CLIQuotaError.signInExpired) { try await b.read(p) }
        #expect(b.http.calls.isEmpty)
    }

    @Test func noCredentialsIsSignedOut() async throws {
        let b = QuotaBox(), p = b.claude()
        await #expect(throws: CLIQuotaError.signedOut) { try await b.read(p) }
        #expect(b.http.calls.isEmpty)
    }

    @Test func defaultProfileUsesTheUnsuffixedKeychainItem() async throws {
        let b = QuotaBox(), p = b.claude(nil)
        b.credentials(p)
        b.http.body = Data(Self.namedShape.utf8)
        _ = try await b.read(p)
        #expect(b.keychain.items.keys.contains("Claude Code-credentials"))
        #expect(b.http.calls.count == 1)
    }
}

@Suite struct ClaudeRenewTests {
    final class Runs {
        var calls: [(file: String, args: [String], cwd: String, env: [String: String], timeout: TimeInterval)] = []
        var fail = false
        var run: ClaudeCodeQuota.Run {
            { f, a, c, e, t in
                self.calls.append((f, a, c, e, t))
                if self.fail { throw CLIQuotaError.unavailable("boom") }
            }
        }
    }

    static let ambient = ["PATH": "/usr/bin", "CLAUDE_CODE_OAUTH_TOKEN": "x", "ANTHROPIC_API_KEY": "y", "CLAUDE_CONFIG_DIR": "/elsewhere", "HOME": "/h"]

    @Test func profileRunsWithItsOwnConfigDirAndACleanEnvironment() {
        let b = QuotaBox(), p = b.claude(), runs = Runs()
        let ok = ClaudeCodeQuota.renewLogin(profile: p, claudeBinary: "/bin/claude", stateDir: b.root.path + "/state", now: b.now,
                                            environment: Self.ambient, run: runs.run)
        #expect(ok)
        #expect(runs.calls.count == 1)
        let c = runs.calls[0]
        #expect(c.file == "/bin/claude")
        #expect(c.args == ["-p", "reply with exactly: ok", "--model", "haiku", "--no-session-persistence", "--setting-sources", "",
                           "--strict-mcp-config", "--tools", "", "--disable-slash-commands"])
        #expect(c.env["CLAUDE_CONFIG_DIR"] == p.path)
        #expect(c.env["CLAUDE_CODE_OAUTH_TOKEN"] == nil && c.env["ANTHROPIC_API_KEY"] == nil)
        #expect(c.env["PATH"] == "/usr/bin" && c.env["HOME"] == "/h")
        #expect(c.cwd == NSTemporaryDirectory())
        #expect(c.timeout == 20)
    }

    @Test func defaultProfileLeavesTheVariableUnset() {
        let b = QuotaBox(), p = b.claude(nil), runs = Runs()
        #expect(ClaudeCodeQuota.renewLogin(profile: p, claudeBinary: "/bin/claude", stateDir: b.root.path + "/state", now: b.now,
                                           environment: Self.ambient, run: runs.run))
        #expect(runs.calls[0].env["CLAUDE_CONFIG_DIR"] == nil)
        #expect(runs.calls[0].env["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    }

    @Test func throttledPerProfileForThirtyMinutes() {
        let b = QuotaBox(), p = b.claude("a"), other = b.claude("b"), runs = Runs()
        let state = b.root.path + "/state"
        func renew(_ p: CLIProfile, at: TimeInterval) -> Bool {
            ClaudeCodeQuota.renewLogin(profile: p, claudeBinary: "/bin/claude", stateDir: state, now: b.now.addingTimeInterval(at),
                                       environment: [:], run: runs.run)
        }
        #expect(renew(p, at: 0))
        #expect(!renew(p, at: 29 * 60))
        #expect(renew(other, at: 29 * 60))
        #expect(renew(p, at: 31 * 60))
        #expect(runs.calls.count == 3)
    }

    @Test func aFailedRunStillCountsAsAnAttempt() {
        let b = QuotaBox(), p = b.claude(), runs = Runs()
        runs.fail = true
        let state = b.root.path + "/state"
        #expect(!ClaudeCodeQuota.renewLogin(profile: p, claudeBinary: "/bin/claude", stateDir: state, now: b.now, environment: [:], run: runs.run))
        runs.fail = false
        #expect(!ClaudeCodeQuota.renewLogin(profile: p, claudeBinary: "/bin/claude", stateDir: state, now: b.now.addingTimeInterval(60), environment: [:], run: runs.run))
        #expect(runs.calls.count == 1)
    }
}

@Suite struct CodexQuotaTests {
    static let limits = """
    {"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800003600},\
    "secondary":{"usedPercent":60.5,"windowDurationMins":10080,"resetsAt":1800090000}}}
    """

    /// A fake `codex app-server`: canned answers to each request, one line each.
    func script(in b: QuotaBox, account: String = #"{"type":"chatgpt","planType":"plus"}"#, limits: String = CodexQuotaTests.limits,
                afterLimits: String = "", hangOnLimits: Bool = false) -> String {
        let path = b.root.path + "/fake-app-server-\(UUID().uuidString).sh"
        b.write(path, """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"initialize"'*) echo '{"id":1,"result":{"userAgent":"fake"}}' ;;
            *'"account/read"'*) echo '{"id":2,"result":{"account":\(account)}}' ;;
            *'"account/rateLimits/read"'*)
              \(hangOnLimits ? "exec sleep 60" : "")
              \(afterLimits)
              echo '{"id":3,"result":\(limits)}' ;;
          esac
        done
        """)
        return path
    }

    final class Spawns {
        var servers: [CodexServer] = []
        var seen: [(exe: String, args: [String], env: [String: String])] = []
        func spawn(script: String) -> CodexQuota.Spawn {
            { exe, args, env in
                self.seen.append((exe, args, env))
                let s = try CodexServer(executable: "/bin/sh", arguments: [script], environment: env)
                self.servers.append(s)
                return s
            }
        }
    }

    func signIn(_ p: CLIProfile, accountID: String = "acct-1", box: QuotaBox) {
        box.write(p.path + "/auth.json", #"{"auth_mode":"chatgpt","tokens":{"account_id":"\#(accountID)","refresh_token":"rt-SECRET"}}"#)
    }

    @Test func happyPath() async throws {
        let b = QuotaBox(), p = b.codex(), spawns = Spawns()
        signIn(p, box: b)
        let q = try await CodexQuota.read(profile: p, codexBinary: "/opt/codex", now: b.now, environment: ["PATH": "/usr/bin", "CODEX_HOME": "/other"],
                                          timeout: 10, spawn: spawns.spawn(script: script(in: b)))
        #expect(q.source == "codex app-server" && q.plan == "plus" && q.observedAt == b.now)
        #expect(q.windows == [CLIQuotaWindow(label: "5h", usedPercent: 25, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)),
                              CLIQuotaWindow(label: "week", usedPercent: 60.5, resetsAt: Date(timeIntervalSince1970: 1_800_090_000))])
        #expect(spawns.seen[0].exe == "/opt/codex" && spawns.seen[0].args == ["app-server"])
        #expect(spawns.seen[0].env["CODEX_HOME"] == p.path && spawns.seen[0].env["PATH"] == "/usr/bin")
        #expect(!spawns.servers[0].isRunning)
    }

    @Test func defaultProfileLeavesCodexHomeUnset() async throws {
        let b = QuotaBox(), p = b.profiles.defaultProfile(.codex), spawns = Spawns()
        signIn(p, box: b)
        _ = try await CodexQuota.read(profile: p, codexBinary: "codex", now: b.now, environment: ["CODEX_HOME": "/other"],
                                      timeout: 10, spawn: spawns.spawn(script: script(in: b)))
        #expect(spawns.seen[0].env["CODEX_HOME"] == nil)
    }

    @Test func bucketsByLimitIdAndOddWindowLengths() async throws {
        let b = QuotaBox(), p = b.codex(), spawns = Spawns()
        signIn(p, box: b)
        let limits = """
        {"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1800003600}},\
        "spark":{"limitName":"Spark","primary":{"usedPercent":2,"windowDurationMins":45,"resetsAt":1800003600}}}}
        """
        let q = try await CodexQuota.read(profile: p, codexBinary: "codex", now: b.now, timeout: 10,
                                          spawn: spawns.spawn(script: script(in: b, limits: limits)))
        #expect(q.windows.map(\.label) == ["5h", "Spark 45m"])
    }

    @Test func outOfRangeWindowIsRejected() async throws {
        let b = QuotaBox(), p = b.codex(), spawns = Spawns()
        signIn(p, box: b)
        let limits = #"{"rateLimits":{"primary":{"usedPercent":140,"windowDurationMins":300,"resetsAt":1800003600}}}"#
        await #expect(throws: CLIQuotaError.unavailable("Unsupported quota window schema.")) {
            try await CodexQuota.read(profile: p, codexBinary: "codex", now: b.now, timeout: 10, spawn: spawns.spawn(script: self.script(in: b, limits: limits)))
        }
        #expect(!spawns.servers[0].isRunning)
    }

    @Test func nonChatGPTAccountIsRefused() async throws {
        let b = QuotaBox(), p = b.codex(), spawns = Spawns()
        signIn(p, box: b)
        let s = script(in: b, account: #"{"type":"apiKey"}"#)
        do {
            _ = try await CodexQuota.read(profile: p, codexBinary: "codex", now: b.now, timeout: 10, spawn: spawns.spawn(script: s))
            Issue.record("expected an error")
        } catch let e as CLIQuotaError {
            #expect(e.errorDescription?.contains("ChatGPT") == true)
        }
        #expect(!spawns.servers[0].isRunning)
    }

    @Test func accountChangedDuringTheReadIsAnError() async throws {
        let b = QuotaBox(), p = b.codex(), spawns = Spawns()
        signIn(p, box: b)
        let swap = #"printf '%s' '{"tokens":{"account_id":"acct-2"}}' > "$CODEX_HOME/auth.json""#
        let s = script(in: b, afterLimits: swap)
        await #expect(throws: CLIQuotaError.unavailable("Account changed during quota read; rerun.")) {
            try await CodexQuota.read(profile: p, codexBinary: "codex", now: b.now, timeout: 10, spawn: spawns.spawn(script: s))
        }
        #expect(!spawns.servers[0].isRunning)
    }

    @Test func notSignedInNeverSpawnsAnything() async throws {
        let b = QuotaBox(), p = b.codex(), spawns = Spawns()
        await #expect(throws: CLIQuotaError.signedOut) {
            try await CodexQuota.read(profile: p, codexBinary: "codex", now: b.now, timeout: 10, spawn: spawns.spawn(script: self.script(in: b)))
        }
        #expect(spawns.seen.isEmpty)
    }

    @Test func timeoutKillsTheServer() async throws {
        let b = QuotaBox(), p = b.codex(), spawns = Spawns()
        signIn(p, box: b)
        let s = script(in: b, hangOnLimits: true)
        let started = Date()
        do {
            _ = try await CodexQuota.read(profile: p, codexBinary: "codex", now: b.now, timeout: 1.5, spawn: spawns.spawn(script: s))
            Issue.record("expected a timeout")
        } catch let e as CLIQuotaError {
            #expect(e.errorDescription?.contains("timed out") == true)
        }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(!spawns.servers[0].isRunning)
    }

    @Test func serverThatExitsEarlyIsAnError() async throws {
        let b = QuotaBox(), p = b.codex(), spawns = Spawns()
        signIn(p, box: b)
        let path = b.root.path + "/dies.sh"
        b.write(path, "#!/bin/sh\nexit 3\n")
        await #expect(throws: CLIQuotaError.self) {
            try await CodexQuota.read(profile: p, codexBinary: "codex", now: b.now, timeout: 10, spawn: spawns.spawn(script: path))
        }
    }
}

@Suite struct CLIQuotaCacheTests {
    @Test func roundTripPerProfileAndNoSecrets() async throws {
        let b = QuotaBox(), p = b.claude(), c = b.codex()
        b.credentials(p)
        b.http.body = Data(ClaudeQuotaTests.namedShape.utf8)
        let quota = try await b.read(p)
        let cache = CLIQuotaCache(env: b.env)
        #expect(cache.load().isEmpty)
        try cache.store(quota, for: p, accountKey: "A:o")
        let other = CLIQuota(windows: [CLIQuotaWindow(label: "week", usedPercent: 7, resetsAt: nil)], source: "codex app-server",
                             observedAt: Date(timeIntervalSince1970: 1_800_000_000), plan: "pro")
        try cache.store(other, for: c, accountKey: "acct-1")

        let again = CLIQuotaCache(env: b.env)
        #expect(again.quota(for: p, accountKey: "A:o") == quota)
        #expect(again.quota(for: c, accountKey: "acct-1") == other)
        // Another account in the same profile does not see the old entry.
        #expect(again.quota(for: p, accountKey: "B:o") == nil)
        #expect(again.quota(for: p, accountKey: nil) == nil)
        #expect(again.load().count == 2)

        let path = b.env.config + "/quota-cache.json"
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!text.contains(QuotaBox.token))
        #expect(!text.contains("rt-SECRET"))
        #expect(!text.contains("@"))
        var st = stat()
        #expect(stat(path, &st) == 0 && (st.st_mode & 0o777) == 0o600)
    }

    @Test func aCorruptFileReadsAsEmptyAndIsReplaced() throws {
        let b = QuotaBox(), p = b.claude()
        b.write(b.env.config + "/quota-cache.json", "{nope")
        let cache = CLIQuotaCache(env: b.env)
        #expect(cache.load().isEmpty)
        let q = CLIQuota(windows: [], source: "statusline", observedAt: b.now)
        try cache.store(q, for: p, accountKey: nil)
        #expect(cache.quota(for: p, accountKey: nil) == q)
        #expect(cache.quota(for: p, accountKey: "A") == nil)
    }
}

private extension Date {
    /// The cache and the statusline keep whole seconds.
    var roundedToSecond: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}

import Foundation

// Quota of CLI profiles: Claude Code (statusline copy, else the OAuth usage endpoint) and Codex
// (`codex app-server` over stdio). Ported from token-arcade's remaining-range.
//
// Nothing here refreshes a token, prints one or stores one. Reads never change a profile; the
// only thing that can (`ClaudeCodeQuota.renewLogin`) runs the real CLI and is called explicitly.

public struct CLIQuotaWindow: Equatable, Codable, Sendable {
    /// `5h`, `week`, `week (Opus)`, `<n>m`, …
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(label: String, usedPercent: Double, resetsAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct CLIQuota: Equatable, Codable, Sendable {
    public var windows: [CLIQuotaWindow]
    /// `statusline`, `usage endpoint` or `codex app-server`.
    public var source: String
    public var observedAt: Date
    public var plan: String?

    public init(windows: [CLIQuotaWindow], source: String, observedAt: Date, plan: String? = nil) {
        self.windows = windows
        self.source = source
        self.observedAt = observedAt
        self.plan = plan
    }
}

public enum CLIQuotaError: Error, LocalizedError, Equatable {
    /// No usable sign-in for this profile.
    case signedOut
    /// The stored access token has run out. Switcher never refreshes it; renew it with the CLI.
    case signInExpired
    case unavailable(String)

    /// The service said too many requests (HTTP 429): wait the longest before asking again.
    public var isRateLimited: Bool {
        if case .unavailable(let m) = self { return m.contains("HTTP 429") }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .signedOut: "not signed in"
        case .signInExpired: "the sign-in has expired; renew it with the CLI"
        case .unavailable(let m): m
        }
    }
}

// MARK: - HTTP

public protocol HTTPGetter {
    /// The status code and body. Throws only when no response arrived.
    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data)
}

/// URLSession with a 15 s timeout, no redirects followed and no cookies.
public final class URLSessionHTTPGetter: HTTPGetter {
    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await Self.sharedSession.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data)
    }
}

// MARK: - JSON helpers

enum QuotaJSON {
    /// A finite JSON number (not a boolean).
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func percent(_ v: Any?) -> Double? {
        guard let d = number(v), d >= 0, d <= 100 else { return nil }
        return d
    }
}

// MARK: - Claude Code

public enum ClaudeCodeQuota {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// A statusline reading younger than this answers without any request.
    public static let statuslineFresh: TimeInterval = 5 * 60
    /// When the usage request fails, a statusline reading up to this old still answers.
    public static let statuslineFallback: TimeInterval = 15 * 60
    /// Attempts to renew a profile's login are at least this far apart.
    public static let renewInterval: TimeInterval = 30 * 60
    static let renewTimeout: TimeInterval = 20

    public static func read(profile: CLIProfile, profiles: CLIProfiles, keychain: CLIKeychain, http: HTTPGetter, now: Date = Date()) async throws -> CLIQuota {
        guard profile.kind == .claude else { throw CLIQuotaError.unavailable("not a Claude Code profile") }
        let passive = readStatusline(profile: profile, now: now)
        let oauth = profiles.claudeOAuth(profile, keychain: keychain)
        let plan = oauth?["subscriptionType"] as? String

        if var p = passive, now.timeIntervalSince(p.observedAt) < statuslineFresh {
            p.plan = plan
            return p
        }

        // A sign-in problem is reported as such; a statusline reading never hides it.
        guard let oauth, let token = oauth["accessToken"] as? String, !token.isEmpty else { throw CLIQuotaError.signedOut }
        if let expiresMs = QuotaJSON.number(oauth["expiresAt"]), Date(timeIntervalSince1970: expiresMs / 1000) <= now {
            throw CLIQuotaError.signInExpired
        }

        // Who this read is for: the account and a fingerprint of the token, compared again after
        // the response. The fingerprint stays in memory; it is never stored.
        let before = identityStamp(profile: profile, profiles: profiles, token: token)
        let result: CLIQuota
        do {
            var quota = try await requestUsage(token: token, http: http, now: now)
            quota.plan = plan
            result = quota
        } catch {
            let message = (error as? CLIQuotaError)?.errorDescription ?? "Claude usage request failed or timed out."
            guard var p = passive else {
                throw error is CLIQuotaError ? error : CLIQuotaError.unavailable(message)
            }
            guard now.timeIntervalSince(p.observedAt) <= statuslineFallback else {
                throw CLIQuotaError.unavailable("\(message) The last statusline reading (\(ISO8601DateFormatter().string(from: p.observedAt))) is too old to stand in for current quota.")
            }
            p.plan = plan
            result = p
        }
        guard identityStamp(profile: profile, profiles: profiles, keychain: keychain) == before else {
            throw CLIQuotaError.unavailable("the account changed during the read; try again")
        }
        return result
    }

    struct IdentityStamp: Equatable {
        var accountKey: String?
        var tokenPrefix: String?
    }

    static func identityStamp(profile: CLIProfile, profiles: CLIProfiles, token: String?) -> IdentityStamp {
        IdentityStamp(accountKey: profiles.identity(profile)?.accountKey,
                      tokenPrefix: token.map { String(SHA256.hex(Data($0.utf8)).prefix(16)) })
    }

    static func identityStamp(profile: CLIProfile, profiles: CLIProfiles, keychain: CLIKeychain) -> IdentityStamp {
        identityStamp(profile: profile, profiles: profiles,
                      token: profiles.claudeOAuth(profile, keychain: keychain)?["accessToken"] as? String)
    }

    static func requestUsage(token: String, http: HTTPGetter, now: Date) async throws -> CLIQuota {
        let status: Int, data: Data
        do {
            (status, data) = try await http.get(usageURL, headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"])
        } catch {
            throw CLIQuotaError.unavailable("Claude usage request failed or timed out.")
        }
        guard (200..<300).contains(status) else {
            throw CLIQuotaError.unavailable("Claude usage HTTP \(status)\(status == 429 ? "; do not poll or retry now" : "").")
        }
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CLIQuotaError.unavailable("Claude usage returned invalid JSON.")
        }
        let windows = normalize(raw)
        guard !windows.isEmpty else { throw CLIQuotaError.unavailable("Claude usage returned no usable windows.") }
        return CLIQuota(windows: windows, source: "usage endpoint", observedAt: now)
    }

    /// Both response shapes: `limits[]` (session / weekly_all / weekly_scoped) or `five_hour`,
    /// `seven_day`, `seven_day_opus`, `seven_day_sonnet`. Windows with a value outside 0…100 or an
    /// unreadable reset time are dropped.
    static func normalize(_ raw: [String: Any]) -> [CLIQuotaWindow] {
        var out: [CLIQuotaWindow] = []
        func add(_ label: String, _ percent: Any?, _ reset: Any?) {
            guard let p = QuotaJSON.percent(percent) else { return }
            var date: Date?
            if let reset, !(reset is NSNull) {
                guard let s = reset as? String, let d = ISO8601DateFormatter.lenient(s) else { return }
                date = d
            }
            out.append(CLIQuotaWindow(label: label, usedPercent: p, resetsAt: date))
        }
        if let limits = raw["limits"] as? [Any], !limits.isEmpty {
            for case let limit as [String: Any] in limits {
                switch limit["kind"] as? String {
                case "session": add("5h", limit["percent"], limit["resets_at"])
                case "weekly_all": add("week", limit["percent"], limit["resets_at"])
                case "weekly_scoped":
                    let scope = limit["scope"] as? [String: Any]
                    let name = CLIProfiles.nonEmpty((scope?["model"] as? [String: Any])?["display_name"]) ?? CLIProfiles.nonEmpty(scope?["surface"])
                    add(name.map { "week (\($0))" } ?? "week (scoped)", limit["percent"], limit["resets_at"])
                default: break
                }
            }
        } else {
            for (key, label) in [("five_hour", "5h"), ("seven_day", "week"), ("seven_day_opus", "week (Opus)"), ("seven_day_sonnet", "week (Sonnet)")] {
                if let v = raw[key] as? [String: Any] { add(label, v["utilization"], v["resets_at"]) }
            }
        }
        return out
    }

    /// `<profile>/rate-limits.json`, the statusline's copy of Claude Code's `rate_limits`. Nil when
    /// absent, malformed, dated in the future or with every window past its reset (a window that
    /// has reset no longer describes current usage; it is never extrapolated).
    static func readStatusline(profile: CLIProfile, now: Date) -> CLIQuota? {
        guard let data = FileManager.default.contents(atPath: profile.path + "/rate-limits.json"),
              let snap = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let captured = (snap["capturedAt"] as? String).flatMap(ISO8601DateFormatter.lenient),
              captured <= now.addingTimeInterval(60),
              let limits = snap["rate_limits"] as? [String: Any] else { return nil }
        var windows: [CLIQuotaWindow] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "week")] {
            guard let w = limits[key] as? [String: Any], let reset = QuotaJSON.number(w["resets_at"]),
                  let used = QuotaJSON.percent(w["used_percentage"]) else { continue }
            let resetsAt = Date(timeIntervalSince1970: reset)
            if resetsAt > now { windows.append(CLIQuotaWindow(label: label, usedPercent: used, resetsAt: resetsAt)) }
        }
        guard !windows.isEmpty else { return nil }
        return CLIQuota(windows: windows, source: "statusline", observedAt: captured)
    }

    // MARK: Keep-alive

    /// Runs one executable: `(file, arguments, cwd, environment, timeout)`. Throws on a failed run.
    public typealias Run = (_ file: String, _ arguments: [String], _ cwd: String, _ environment: [String: String], _ timeout: TimeInterval) throws -> Void

    /// token-arcade's keep-alive. Claude Code renews the access token only while it runs, so a
    /// profile nobody used for hours has an expired token. One minimal Haiku print run (no user
    /// settings, hooks, tools, MCP or session file) makes the CLI renew and store it itself; Switcher
    /// never touches the refresh token. Throttled per profile by a marker file under `stateDir`.
    /// Returns true when the run finished, so the caller reads the quota once more.
    public static func renewLogin(profile: CLIProfile, claudeBinary: String, stateDir: String, now: Date = Date(),
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  run: Run = ClaudeCodeQuota.defaultRun) -> Bool {
        guard profile.kind == .claude else { return false }
        let marker = stateDir + "/" + SHA256.hex(Data(profile.path.utf8)).prefix(16)
        if let last = FS.mtime(URL(fileURLWithPath: marker)) {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= 0, elapsed < renewInterval { return false }
        }
        do {
            try FS.makePrivateDir(URL(fileURLWithPath: stateDir, isDirectory: true))
            try FS.atomicWrite(Data(), to: URL(fileURLWithPath: marker))
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: marker)
        } catch { return false }

        var env = environment
        for key in ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR"] { env.removeValue(forKey: key) }
        if let dir = profile.envValue { env["CLAUDE_CONFIG_DIR"] = dir }
        do {
            try run(claudeBinary, renewArguments, NSTemporaryDirectory(), env, renewTimeout)
            return true
        } catch { return false }
    }

    static let renewArguments = ["-p", "reply with exactly: ok", "--model", "haiku", "--no-session-persistence",
                                 "--setting-sources", "", "--strict-mcp-config", "--tools", "", "--disable-slash-commands"]

    public static let defaultRun: Run = { file, args, cwd, env, timeout in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: file)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning {
            // SIGTERM first; a Claude that ignores it must not outlive the timeout and keep
            // requesting or writing credentials, so SIGKILL after a short grace and wait for it.
            p.terminateAndWait(grace: 2)
            throw CLIQuotaError.unavailable("claude did not finish within \(Int(timeout)) s")
        }
        guard p.terminationStatus == 0 else { throw CLIQuotaError.unavailable("claude exited with \(p.terminationStatus)") }
    }
}

// MARK: - Codex

/// A running `codex app-server` (or a stand-in): lines in, lines out, always killable.
public final class CodexServer: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let continuation: AsyncStream<String>.Continuation
    public let lines: AsyncStream<String>
    private let lock = NSLock()
    private var buffer = Data()
    private var killed = false

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    public init(executable: String, arguments: [String], environment: [String: String]) throws {
        (lines, continuation) = AsyncStream<String>.makeStream()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { h.readabilityHandler = nil; return }
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil }
            self.received(chunk)
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw error
        }
    }

    private func received(_ chunk: Data) {
        lock.lock()
        if chunk.isEmpty {
            let rest = buffer
            buffer = Data()
            lock.unlock()
            if !rest.isEmpty { continuation.yield(String(decoding: rest, as: UTF8.self)) }
            continuation.finish()
            return
        }
        buffer.append(chunk)
        var out: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            out.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer = Data(buffer[buffer.index(after: nl)...])
        }
        lock.unlock()
        out.forEach { continuation.yield($0) }
    }

    public func send(_ line: String) throws {
        try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Stops the process (SIGTERM, then SIGKILL after a second) and ends `lines`. Safe to repeat.
    public func kill() {
        lock.lock()
        let first = !killed
        killed = true
        lock.unlock()
        guard first else { return }
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminateAndWait(grace: 1)
        }
        continuation.finish()
    }

    deinit { kill() }
}

public enum CodexQuota {
    public static let defaultTimeout: TimeInterval = 25

    public typealias Spawn = (_ executable: String, _ arguments: [String], _ environment: [String: String]) throws -> CodexServer

    public static let defaultSpawn: Spawn = { exe, args, env in try CodexServer(executable: exe, arguments: args, environment: env) }

    public static func read(profile: CLIProfile, codexBinary: String, now: Date = Date(),
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            timeout: TimeInterval = CodexQuota.defaultTimeout,
                            spawn: Spawn = CodexQuota.defaultSpawn) async throws -> CLIQuota {
        guard profile.kind == .codex else { throw CLIQuotaError.unavailable("not a Codex profile") }
        guard let accountID = accountID(profile) else { throw CLIQuotaError.signedOut }

        var env = environment
        env.removeValue(forKey: "OPENAI_API_KEY")
        if let home = profile.envValue { env["CODEX_HOME"] = home } else { env.removeValue(forKey: "CODEX_HOME") }
        let server: CodexServer
        do { server = try spawn(codexBinary, ["app-server"], env) } catch { throw CLIQuotaError.unavailable("Unable to launch codex app-server.") }
        defer { server.kill() }

        let timedOut = Flag()
        let timer = DispatchWorkItem { timedOut.set(); server.kill() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }

        var iterator = server.lines.makeAsyncIterator()
        var next = 0
        func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            next += 1
            let id = next
            do { try server.send(json(["id": id, "method": method, "params": params])) }
            catch { throw CLIQuotaError.unavailable(timedOut.value ? timeoutMessage(timeout) : "Codex app-server input closed.") }
            while let line = await iterator.next() {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let got = QuotaJSON.number(obj["id"]), Int(exactly: got) == id else { continue }
                if let err = obj["error"] as? [String: Any] {
                    let code = QuotaJSON.number(err["code"]).flatMap { Int(exactly: $0) }.map(String.init) ?? "unknown"
                    throw CLIQuotaError.unavailable("Codex RPC failed (code \(code)).")
                }
                return obj["result"] as? [String: Any] ?? [:]
            }
            throw CLIQuotaError.unavailable(timedOut.value ? timeoutMessage(timeout) : "Codex app-server exited before returning quota.")
        }

        _ = try await call("initialize", ["clientInfo": ["name": "switcher", "title": "Switcher", "version": "1"]])
        try? server.send(json(["method": "initialized", "params": [String: Any]()]))
        let account = try await call("account/read", ["refreshToken": false])["account"] as? [String: Any]
        guard account?["type"] as? String == "chatgpt" else {
            throw CLIQuotaError.unavailable("This Codex profile is not signed in with a ChatGPT subscription.")
        }
        let result = try await call("account/rateLimits/read", [:])
        guard self.accountID(profile) == accountID else { throw CLIQuotaError.unavailable("Account changed during quota read; rerun.") }

        return CLIQuota(windows: try windows(result), source: "codex app-server", observedAt: now, plan: CLIProfiles.nonEmpty(account?["planType"]))
    }

    static func timeoutMessage(_ t: TimeInterval) -> String { "Quota read timed out after \(Int(t)) seconds." }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    static func json(_ obj: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// `tokens.account_id` (or `id_token`'s `chatgpt_account_id`) of a signed-in profile's `auth.json`.
    static func accountID(_ profile: CLIProfile) -> String? {
        guard let d = FileManager.default.contents(atPath: profile.path + "/auth.json"),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let tokens = o["tokens"] as? [String: Any],
              CLIProfiles.nonEmpty(tokens["refresh_token"]) != nil else { return nil }
        if let id = CLIProfiles.nonEmpty(tokens["account_id"]) { return id }
        let claims = CLIProfiles.nonEmpty(tokens["id_token"]).flatMap(CLIProfiles.jwtClaims) ?? [:]
        let openai = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        return CLIProfiles.nonEmpty(openai["chatgpt_account_id"])
    }

    /// `rateLimitsByLimitId` (every bucket) or the single `rateLimits`; primary and secondary windows.
    static func windows(_ result: [String: Any]) throws -> [CLIQuotaWindow] {
        var buckets: [(id: String, bucket: [String: Any])] = []
        if let by = result["rateLimitsByLimitId"] as? [String: Any] {
            for key in by.keys.sorted(by: { ($0 == "codex" ? "" : $0) < ($1 == "codex" ? "" : $1) }) {
                if let b = by[key] as? [String: Any] { buckets.append((CLIProfiles.nonEmpty(key) ?? "codex", b)) }
            }
        } else if let b = result["rateLimits"] as? [String: Any] {
            buckets.append((CLIProfiles.nonEmpty(b["limitId"]) ?? "codex", b))
        }
        var out: [CLIQuotaWindow] = []
        for (id, bucket) in buckets {
            let prefix = id == "codex" ? "" : (CLIProfiles.nonEmpty(bucket["limitName"]) ?? id) + " "
            for slot in ["primary", "secondary"] {
                guard let w = bucket[slot] as? [String: Any] else { continue }
                guard let used = QuotaJSON.percent(w["usedPercent"]),
                      let rawMinutes = QuotaJSON.number(w["windowDurationMins"]),
                      rawMinutes >= 1, rawMinutes <= 10_000_000 else {
                    throw CLIQuotaError.unavailable("Unsupported quota window schema.")
                }
                let minutes = Int(rawMinutes.rounded())
                let reset = QuotaJSON.number(w["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
                out.append(CLIQuotaWindow(label: prefix + windowLabel(minutes: minutes), usedPercent: used, resetsAt: reset))
            }
        }
        guard !out.isEmpty else { throw CLIQuotaError.unavailable("No percentage quota windows returned.") }
        return out
    }

    static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 300: "5h"
        case 10080: "week"
        default: "\(minutes)m"
        }
    }
}

// MARK: - Antigravity CLI

public enum AgyCLIQuota {
    private static let lock = NSLock()
    private static var renewedTokens: [String: (fingerprint: String, token: String, expires: Date)] = [:]
    private static var projects: [String: (fingerprint: String, project: String)] = [:]

    struct IdentityStamp: Equatable {
        var accountKey: String?
        var tokenPrefix: String
    }

    public static func read(profile: CLIProfile, profiles: CLIProfiles, keychain: CLIKeychain,
                            send: AntigravityUsage.Send? = nil, now: Date = Date()) async throws -> CLIQuota {
        guard profile.kind == .agy else { throw CLIQuotaError.unavailable("not an Antigravity CLI profile") }
        guard let record = profiles.agyTokenRecord(profile, keychain: keychain),
              CLIProfiles.isUsableAgyCredential(record.credential, now: now) else {
            throw CLIQuotaError.signedOut
        }
        let before = identityStamp(profile: profile, profiles: profiles, record: record, keychain: keychain)
        let transport = send ?? AntigravityUsage.defaultSend

        var access = try await accessToken(profile: profile, credential: record.credential,
                                           fingerprint: before.tokenPrefix, now: now, forceRenew: false, send: transport)
        let fetched: (plan: String?, buckets: [QuotaBucket])
        do {
            fetched = try await queryCloudCode(profile: profile, fingerprint: before.tokenPrefix, token: access, send: transport)
        } catch is AntigravityUsage.Refused {
            access = try await accessToken(profile: profile, credential: record.credential,
                                           fingerprint: before.tokenPrefix, now: now, forceRenew: true, send: transport)
            do {
                fetched = try await queryCloudCode(profile: profile, fingerprint: before.tokenPrefix, token: access, send: transport)
            } catch is AntigravityUsage.Refused {
                throw CLIQuotaError.unavailable(L10n.t("Google no longer accepts this sign-in. Sign in again.", "Google 已不接受这个登录，请重新登录。"))
            }
        }

        guard let currentRecord = profiles.agyTokenRecord(profile, keychain: keychain),
              identityStamp(profile: profile, profiles: profiles, record: currentRecord, keychain: keychain) == before else {
            throw CLIQuotaError.unavailable("the account changed during the read; try again")
        }

        let windows = fetched.buckets.map { b in
            CLIQuotaWindow(label: windowLabel(b.pool), usedPercent: Double(b.used), resetsAt: b.resetsAt)
        }
        guard !windows.isEmpty else {
            throw CLIQuotaError.unavailable("Antigravity quota returned no usable windows.")
        }
        let plan = fetched.plan ?? profiles.identity(profile, keychain: keychain)?.plan
        return CLIQuota(windows: windows, source: "google cloud code", observedAt: now, plan: plan)
    }

    static func windowLabel(_ pool: QuotaBucket.Pool) -> String {
        switch pool {
        case .gemini5h: "5h"
        case .geminiWeekly: "week"
        case .claude5h: "Claude 5h"
        case .claudeWeekly: "Claude week"
        case .argonWeekly: "Argon week"
        }
    }

    static func identityStamp(profile: CLIProfile, profiles: CLIProfiles, record: CLIProfiles.AgyTokenRecord, keychain: CLIKeychain) -> IdentityStamp {
        let secret = record.credential.refreshToken ?? record.credential.accessToken ?? ""
        return IdentityStamp(accountKey: profiles.identity(profile, keychain: keychain)?.accountKey,
                             tokenPrefix: String(SHA256.hex(Data(secret.utf8)).prefix(16)))
    }

    private static func accessToken(profile: CLIProfile, credential: AntigravityUsage.Credential,
                                    fingerprint: String, now: Date, forceRenew: Bool,
                                    send: AntigravityUsage.Send) async throws -> String {
        if !forceRenew {
            let cached = lock.withLock { renewedTokens[profile.path] }
            if let cached, cached.fingerprint == fingerprint, cached.expires > now.addingTimeInterval(60) {
                return cached.token
            }
            if let access = credential.accessToken {
                if let expiry = credential.expiry {
                    if expiry > now.addingTimeInterval(60) { return access }
                } else {
                    return access
                }
            }
        }
        guard let refresh = credential.refreshToken else {
            throw CLIQuotaError.unavailable(L10n.t("Google no longer accepts this sign-in. Sign in again.", "Google 已不接受这个登录，请重新登录。"))
        }
        var req = URLRequest(url: AntigravityUsage.tokenURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": AntigravityUsage.clientID,
            "client_secret": AntigravityUsage.clientSecret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ]
        req.httpBody = Data(form.map { "\($0.key)=\(AntigravityUsage.formEncode($0.value))" }.joined(separator: "&").utf8)
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await send(req)
        } catch {
            throw CLIQuotaError.unavailable("Antigravity token request failed or timed out.")
        }
        if response.statusCode == 429 {
            throw CLIQuotaError.unavailable("Antigravity quota HTTP 429; do not poll or retry now.")
        }
        if response.statusCode == 400 || response.statusCode == 401 {
            throw CLIQuotaError.unavailable(L10n.t("Google no longer accepts this sign-in. Sign in again.", "Google 已不接受这个登录，请重新登录。"))
        }
        guard (200..<300).contains(response.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = CLIProfiles.nonEmpty(obj["access_token"]) else {
            throw CLIQuotaError.unavailable("Antigravity token HTTP \(response.statusCode).")
        }
        let expires = now.addingTimeInterval(QuotaJSON.number(obj["expires_in"]) ?? 3600)
        lock.withLock { renewedTokens[profile.path] = (fingerprint, token, expires) }
        return token
    }

    private static func queryCloudCode(profile: CLIProfile, fingerprint: String, token: String,
                                       send: AntigravityUsage.Send) async throws -> (plan: String?, buckets: [QuotaBucket]) {
        var plan: String?
        var project: String? = lock.withLock {
            guard let cached = projects[profile.path], cached.fingerprint == fingerprint else { return nil }
            return cached.project
        }
        let assistBody = Data(#"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8)
        if let data = try await post(AntigravityUsage.loadCodeAssistPath, token: token, body: assistBody, send: send) {
            plan = AntigravityUsage.parsePlan(data)
            if let p = AntigravityUsage.parseProject(data) {
                project = p
                lock.withLock { projects[profile.path] = (fingerprint, p) }
            }
        }
        let payload = try JSONSerialization.data(withJSONObject: project.map { ["project": $0] } ?? [:])
        guard let quotaData = try await post(AntigravityUsage.quotaPath, token: token, body: payload, wantComplete: true, send: send) else {
            throw CLIQuotaError.unavailable(L10n.t("Antigravity's quota is unavailable right now.", "暂时读不到 Antigravity 额度。"))
        }
        return (plan, AntigravityUsage.parseBuckets(quotaData))
    }

    private static func post(_ path: String, token: String, body: Data, wantComplete: Bool = false,
                             send: AntigravityUsage.Send) async throws -> Data? {
        var good: Data?
        var lastStatus: Int?
        for base in AntigravityUsage.bases {
            var req = URLRequest(url: URL(string: base + path)!, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.httpBody = body
            for (k, v) in [
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Authorization": "Bearer \(token)",
                "User-Agent": AntigravityUsage.userAgent,
            ] {
                req.setValue(v, forHTTPHeaderField: k)
            }
            guard let (data, response) = try? await send(req) else { continue }
            if response.statusCode == 401 { throw AntigravityUsage.Refused() }
            if response.statusCode == 429 {
                throw CLIQuotaError.unavailable("Antigravity quota HTTP 429; do not poll or retry now.")
            }
            lastStatus = response.statusCode
            guard (200..<300).contains(response.statusCode) else { continue }
            if good == nil { good = data }
            if !wantComplete || AntigravityUsage.parseBuckets(data).filter({ $0.pool != .argonWeekly }).count == 4 {
                return data
            }
        }
        if good == nil, wantComplete, let status = lastStatus {
            throw CLIQuotaError.unavailable("Antigravity quota HTTP \(status).")
        }
        return good
    }
}

// MARK: - Cache

/// The last good quota per profile id, in `<CLIEnv.config>/quota-cache.json` (0600). A quota holds
/// percentages, reset times, a plan name and a source label: no tokens, no emails. Each disk entry
/// requires a non-empty `accountKey` (the opaque account id, never a token or a hash of one): when
/// a profile is signed in as someone else, or has no stable `accountKey`, disk entries are never
/// reused across logins (unattributed readings live only in memory, bound to `credentialFingerprint`).
public struct CLIQuotaCache {
    struct Entry: Codable {
        var quota: CLIQuota
        var accountKey: String?
    }

    struct File: Codable {
        var version = 2
        var profiles: [String: Entry] = [:]
    }

    private static let memoryLock = NSLock()
    private static nonisolated(unsafe) var ephemeral: [String: (fingerprint: String, quota: CLIQuota)] = [:]

    public let url: URL

    public init(env: CLIEnv) { url = URL(fileURLWithPath: env.config + "/quota-cache.json") }

    private func memoryKey(for profile: CLIProfile) -> String { "\(url.path)\n\(profile.id)" }

    public func load() -> [String: CLIQuota] {
        readFile().profiles.compactMapValues { entry in
            guard let k = entry.accountKey, !k.isEmpty else { return nil }
            return entry.quota
        }
    }

    /// The cached quota, only when it was read for `accountKey` (or, when `accountKey` is nil,
    /// in-memory for the exact `credentialFingerprint` of this session).
    public func quota(for profile: CLIProfile, accountKey: String?, credentialFingerprint: String? = nil) -> CLIQuota? {
        if let accountKey, !accountKey.isEmpty {
            guard let e = readFile().profiles[profile.id], e.accountKey == accountKey else { return nil }
            return e.quota
        }
        guard let fp = credentialFingerprint, !fp.isEmpty else { return nil }
        let key = memoryKey(for: profile)
        return Self.memoryLock.withLock {
            guard let hit = Self.ephemeral[key], hit.fingerprint == fp else { return nil }
            return hit.quota
        }
    }

    /// Read, merge and write under one lock (the app reads Claude, Codex and Agy at the same time,
    /// and the CLI may run too), so one writer never drops another's entry. Readings without a
    /// stable `accountKey` stay in memory only (bound to `credentialFingerprint`) and clear any
    /// older disk entry for `profile`.
    public func store(_ quota: CLIQuota, for profile: CLIProfile, accountKey: String?, credentialFingerprint: String? = nil) throws {
        let memKey = memoryKey(for: profile)
        guard let accountKey, !accountKey.isEmpty else {
            Self.memoryLock.withLock {
                if let fp = credentialFingerprint, !fp.isEmpty {
                    Self.ephemeral[memKey] = (fp, quota)
                } else {
                    Self.ephemeral.removeValue(forKey: memKey)
                }
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try removeDiskEntry(for: profile)
            }
            return
        }
        Self.memoryLock.withLock { _ = Self.ephemeral.removeValue(forKey: memKey) }
        try FS.makePrivateDir(url.deletingLastPathComponent())
        let lock = try FileLock(url.appendingPathExtension("lock"), timeout: 10)
        defer { withExtendedLifetime(lock) {} }
        var file = readFile()
        file.profiles[profile.id] = Entry(quota: quota, accountKey: accountKey)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try FS.atomicWrite(try enc.encode(file), to: url)
    }

    public func remove(for profile: CLIProfile) {
        let memKey = memoryKey(for: profile)
        Self.memoryLock.withLock { _ = Self.ephemeral.removeValue(forKey: memKey) }
        if FileManager.default.fileExists(atPath: url.path) {
            try? removeDiskEntry(for: profile)
        }
    }

    private func removeDiskEntry(for profile: CLIProfile) throws {
        try FS.makePrivateDir(url.deletingLastPathComponent())
        let lock = try FileLock(url.appendingPathExtension("lock"), timeout: 10)
        defer { withExtendedLifetime(lock) {} }
        var file = readFile()
        guard file.profiles.removeValue(forKey: profile.id) != nil else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try FS.atomicWrite(try enc.encode(file), to: url)
    }

    func readFile() -> File {
        guard let data = FileManager.default.contents(atPath: url.path) else { return File() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(File.self, from: data)) ?? File()
    }
}

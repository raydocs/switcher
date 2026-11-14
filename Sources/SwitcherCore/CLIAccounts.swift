import Foundation

// Who each CLI profile is signed in as, how long its sign-in lasts, and `switcher cli doctor`.
// Nothing here prints, logs or returns a token.

public struct CLIIdentity: Equatable, Sendable {
    public var email: String?
    public var organization: String?
    /// Codex: the ChatGPT plan; Claude: the subscription type from the credentials.
    public var plan: String?
    /// A stable account key (Claude account + organization UUID, Codex ChatGPT account id).
    public var accountKey: String?
}

public struct CLISignIn: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case signedIn
        case signedOut
        /// Signed in with an API key or another kind Switcher does not show quota for.
        case other(String)
    }

    public var state: State
    /// When the access token runs out (the CLI renews it while it runs).
    public var accessExpiresAt: Date?
    /// When the sign-in itself runs out unless the CLI is used before then.
    public var refreshExpiresAt: Date?
    public var lastRefresh: Date?
}

/// Read-only access to the keychain items doctor and the account rows need.
public protocol CLIKeychain: AnyObject {
    /// The item's value, or nil when there is none.
    func read(service: String) -> String?
    /// Whether the item exists, without reading it.
    func exists(service: String) -> Bool
    /// The item's value under an explicit keychain account (`nil` uses the login keychain user).
    func read(service: String, account: String?) -> String?
    /// Whether the item exists under an explicit keychain account.
    func exists(service: String, account: String?) -> Bool
    /// Every `Claude Code-credentials*` service name in the login keychain.
    func claudeServices() -> [String]
}

public extension CLIKeychain {
    func read(service: String, account: String?) -> String? {
        guard account == nil else { return nil }
        return read(service: service)
    }

    func exists(service: String, account: String?) -> Bool {
        guard account == nil else { return false }
        return exists(service: service)
    }
}

public final class LiveCLIKeychain: CLIKeychain {
    let account: String
    public init(account: String = NSUserName()) { self.account = account }

    public func read(service: String) -> String? { read(service: service, account: nil) }

    public func read(service: String, account: String?) -> String? {
        let (status, out) = Self.security(["find-generic-password", "-a", account ?? self.account, "-s", service, "-w"])
        guard status == 0 else { return nil }
        let raw = out.hasSuffix("\n") ? String(out.dropLast()) : out
        return Self.decodeSecurityOutput(raw)
    }

    public func exists(service: String) -> Bool { exists(service: service, account: nil) }

    public func exists(service: String, account: String?) -> Bool {
        Self.security(["find-generic-password", "-a", account ?? self.account, "-s", service]).0 == 0
    }

    /// `security -w` prints lowercase hex whenever the secret contains non-ASCII UTF-8 or newlines.
    static func decodeSecurityOutput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("{"), !trimmed.hasPrefix("["),
              !trimmed.hasPrefix("go-keyring-base64:"), !trimmed.hasPrefix("go-keyring-encoded:"),
              let data = AntigravityFiles.decodeHex(trimmed),
              let decoded = String(data: data, encoding: .utf8) else {
            return raw
        }
        return decoded
    }

    public func claudeServices() -> [String] {
        // Attributes only; `dump-keychain` without -d never prints secrets.
        let (_, out) = Self.security(["dump-keychain"])
        var found = Set<String>()
        for line in out.split(separator: "\n") where line.contains("\"svce\"") && line.contains("Claude Code-credentials") {
            if let q = line.range(of: "=\"")?.upperBound, let end = line[q...].firstIndex(of: "\"") {
                found.insert(String(line[q..<end]))
            }
        }
        return found.sorted()
    }

    static func security(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// A keychain for tests.
public final class MemoryCLIKeychain: CLIKeychain {
    public var items: [String: String] = [:]
    public init() {}
    public func read(service: String) -> String? { items[service] }
    public func exists(service: String) -> Bool { items[service] != nil }
    public func read(service: String, account: String?) -> String? {
        account.map { items["\(service)/\($0)"] } ?? items[service]
    }
    public func exists(service: String, account: String?) -> Bool {
        read(service: service, account: account) != nil
    }
    public func claudeServices() -> [String] { items.keys.filter { $0.hasPrefix("Claude Code-credentials") }.sorted() }
}

extension CLIProfiles {
    static func nonEmpty(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    struct AgyTokenRecord {
        var raw: String
        var json: [String: Any]
        var credential: AntigravityUsage.Credential
        var fromKeychain: Bool
    }

    static func regularFileContents(_ path: String) -> Data? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    static func isUsableAgyCredential(_ c: AntigravityUsage.Credential, now: Date = Date()) -> Bool {
        if c.refreshToken != nil { return true }
        guard c.accessToken != nil else { return false }
        return c.expiry.map { $0 > now } ?? true
    }

    func agyRawToken(_ profile: CLIProfile, keychain: CLIKeychain?) -> (raw: String, fromKeychain: Bool)? {
        if !profile.isDefault {
            guard folderProblem(profile) == nil else { return nil }
            let cliDir = profile.path + "/antigravity-cli"
            guard Self.isRealDirectory(cliDir),
                  let data = Self.regularFileContents(cliDir + "/antigravity-oauth-token") else { return nil }
            return (String(decoding: data, as: UTF8.self), false)
        }
        let cliFile = profile.path + "/antigravity-cli/antigravity-oauth-token"
        let marker = profile.path + "/antigravity-cli/cache/antigravity-keyring-unavailable"
        let legacyFile = profile.path + "/jetski-standalone-oauth-token"
        if let mtime = FS.mtime(URL(fileURLWithPath: marker)), abs(Date().timeIntervalSince(mtime)) < 3600,
           let data = Self.regularFileContents(cliFile)
        {
            return (String(decoding: data, as: UTF8.self), false)
        }
        if let kc = keychain?.read(service: "gemini", account: "antigravity") {
            return (kc, true)
        }
        if let data = Self.regularFileContents(cliFile) {
            return (String(decoding: data, as: UTF8.self), false)
        }
        if let data = Self.regularFileContents(legacyFile) {
            return (String(decoding: data, as: UTF8.self), false)
        }
        return nil
    }

    func agyTokenRecord(_ profile: CLIProfile, keychain: CLIKeychain?) -> AgyTokenRecord? {
        guard let (raw, fromKeychain) = agyRawToken(profile, keychain: keychain),
              let body = AntigravityFiles.decodeKeyringBody(raw),
              let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let credential = AntigravityUsage.Credential(keyring: raw) else { return nil }
        return AgyTokenRecord(raw: raw, json: json, credential: credential, fromKeychain: fromKeychain)
    }

    private func agyDefaultFallbackEmail() -> String? {
        let legacy = env.defaultFolder(.agy) + "/jetski-standalone-oauth-token"
        if let d = Self.regularFileContents(legacy),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let email = Self.nonEmpty(obj["id_token_email"]), email.contains("@")
        {
            return email
        }
        let appStorage = URL(fileURLWithPath: env.home + "/Library/Application Support/Antigravity/User/globalStorage/app_storage.json")
        if let doc = try? OrderedJSON(contentsOf: appStorage),
           let email = AntigravityFiles.lastLogin.lazy.compactMap({ doc.string($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { $0.contains("@") })
        {
            return email
        }
        return nil
    }

    public func identity(_ profile: CLIProfile, keychain: CLIKeychain? = nil) -> CLIIdentity? {
        switch profile.kind {
        case .claude:
            guard let d = fm.contents(atPath: env.claudeJSON(profile)),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let a = o["oauthAccount"] as? [String: Any] else { return nil }
            let email = Self.nonEmpty(a["emailAddress"])
            let org = Self.nonEmpty(a["organizationName"])
            let key = Self.nonEmpty(a["accountUuid"]).map { "\($0):\(Self.nonEmpty(a["organizationUuid"]) ?? "")" }
            guard email != nil || org != nil || key != nil else { return nil }
            return CLIIdentity(email: email, organization: org, plan: nil, accountKey: key)
        case .codex:
            guard let auth = codexAuth(profile),
                  let tokens = auth["tokens"] as? [String: Any],
                  Self.nonEmpty(tokens["refresh_token"]) != nil else { return nil }
            let claims = Self.nonEmpty(tokens["id_token"]).flatMap(Self.jwtClaims) ?? [:]
            let openai = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
            let accountID = Self.nonEmpty(tokens["account_id"]) ?? Self.nonEmpty(openai["chatgpt_account_id"])
            return CLIIdentity(email: Self.nonEmpty(claims["email"]), organization: nil,
                               plan: Self.nonEmpty(openai["chatgpt_plan_type"]), accountKey: accountID)
        case .agy:
            guard let record = agyTokenRecord(profile, keychain: keychain),
                  Self.isUsableAgyCredential(record.credential) else { return nil }
            let tokenObj = record.json["token"] as? [String: Any]
            let rawIDToken = Self.nonEmpty(record.json["id_token"]) ?? Self.nonEmpty(tokenObj?["id_token"])
            let claims = rawIDToken.flatMap(Self.jwtClaims) ?? [:]
            var email = Self.nonEmpty(record.json["id_token_email"]).flatMap { $0.contains("@") ? $0 : nil }
                ?? Self.nonEmpty(claims["email"]).flatMap { $0.contains("@") ? $0 : nil }
            if email == nil, profile.isDefault, record.fromKeychain {
                email = agyDefaultFallbackEmail()
            }
            let sub = Self.nonEmpty(claims["sub"])
            let tier = Self.nonEmpty(record.json["user_tier"])
            let plan = tier.map { AntigravityUsage.paidTiers[$0] ?? $0 }
            let key = email?.lowercased() ?? sub.map { "sub:\($0)" }
            guard email != nil || plan != nil || key != nil else { return nil }
            return CLIIdentity(email: email, organization: nil, plan: plan, accountKey: key)
        }
    }

    func codexAuth(_ profile: CLIProfile) -> [String: Any]? {
        guard let d = fm.contents(atPath: profile.path + "/auth.json") else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// A JWT's payload, decoded without checking the signature (identity display only).
    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The Claude sign-in JSON (`claudeAiOauth`): the folder's keychain item, else its plaintext file.
    func claudeOAuth(_ profile: CLIProfile, keychain: CLIKeychain) -> [String: Any]? {
        let service = claudeKeychainService(configDir: profile.envValue)
        let raw = keychain.read(service: service) ?? fm.contents(atPath: profile.path + "/.credentials.json").map { String(decoding: $0, as: UTF8.self) }
        guard let raw, let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        return o["claudeAiOauth"] as? [String: Any]
    }

    /// Non-nil when a credential item or file exists on disk/keychain but is not valid JSON.
    public func credentialProblem(_ profile: CLIProfile, keychain: CLIKeychain) -> String? {
        switch profile.kind {
        case .claude:
            let service = claudeKeychainService(configDir: profile.envValue)
            if let raw = keychain.read(service: service) {
                if (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] == nil {
                    return "keychain item \"\(service)\" is not valid JSON"
                }
            } else if let d = fm.contents(atPath: profile.path + "/.credentials.json") {
                if (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] == nil {
                    return "\(profile.path)/.credentials.json is not valid JSON"
                }
            }
            return nil
        case .codex:
            let path = profile.path + "/auth.json"
            if let d = fm.contents(atPath: path), (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] == nil {
                return "\(path) is not valid JSON"
            }
            return nil
        case .agy:
            guard let (raw, fromKeychain) = agyRawToken(profile, keychain: keychain) else { return nil }
            guard let body = AntigravityFiles.decodeKeyringBody(raw),
                  (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] != nil else {
                return fromKeychain
                    ? "keychain item \"gemini/antigravity\" is not valid JSON"
                    : "the saved OAuth token file in \(profile.path) is not valid JSON"
            }
            return nil
        }
    }

    public func signIn(_ profile: CLIProfile, keychain: CLIKeychain) -> CLISignIn {
        func date(_ v: Any?) -> Date? { (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        switch profile.kind {
        case .claude:
            guard let o = claudeOAuth(profile, keychain: keychain), Self.nonEmpty(o["accessToken"]) != nil else {
                return CLISignIn(state: .signedOut)
            }
            return CLISignIn(state: .signedIn, accessExpiresAt: date(o["expiresAt"]), refreshExpiresAt: date(o["refreshTokenExpiresAt"]))
        case .codex:
            guard let auth = codexAuth(profile) else { return CLISignIn(state: .signedOut) }
            let tokens = auth["tokens"] as? [String: Any]
            let mode = Self.nonEmpty(auth["auth_mode"]) ?? (tokens != nil ? "chatgpt" : "apikey")
            let normalized = mode.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
            let last = Self.nonEmpty(auth["last_refresh"]).flatMap { ISO8601DateFormatter.lenient($0) }
            guard Self.nonEmpty(tokens?["refresh_token"]) != nil else {
                // An API-key sign-in with no key (`{}`, a null or empty key, or `tokens: null`) is no sign-in at all.
                let noKey = normalized == "apikey" && Self.nonEmpty(auth["OPENAI_API_KEY"]) == nil
                return CLISignIn(state: normalized.contains("chatgpt") || noKey ? .signedOut : .other(mode), lastRefresh: last)
            }
            return CLISignIn(state: normalized.contains("chatgpt") ? .signedIn : .other(mode), lastRefresh: last)
        case .agy:
            guard let record = agyTokenRecord(profile, keychain: keychain),
                  Self.isUsableAgyCredential(record.credential) else { return CLISignIn(state: .signedOut) }
            return CLISignIn(state: .signedIn, accessExpiresAt: record.credential.expiry)
        }
    }

    /// The Claude subscription type the credentials name (`pro`, `max`, …).
    public func claudeSubscription(_ profile: CLIProfile, keychain: CLIKeychain) -> String? {
        Self.nonEmpty(claudeOAuth(profile, keychain: keychain)?["subscriptionType"])
    }

    /// A non-secret SHA-256 digest of `profile`'s current credentials, or `nil` when signed out.
    /// Used in memory to tell whether a sign-in or renewal replaced an older credential.
    public func credentialFingerprint(_ profile: CLIProfile, keychain: CLIKeychain) -> String? {
        let state = signIn(profile, keychain: keychain)
        guard state.state != .signedOut else { return nil }
        let key = identity(profile, keychain: keychain)?.accountKey ?? ""
        let raw: String
        switch profile.kind {
        case .claude:
            guard let o = claudeOAuth(profile, keychain: keychain), let access = Self.nonEmpty(o["accessToken"]) else { return nil }
            let refresh = Self.nonEmpty(o["refreshToken"]) ?? ""
            let exp = (o["expiresAt"] as? NSNumber)?.stringValue ?? ""
            let rexp = (o["refreshTokenExpiresAt"] as? NSNumber)?.stringValue ?? ""
            raw = "claude|\(key)|\(access)|\(refresh)|\(exp)|\(rexp)"
        case .codex:
            guard let auth = codexAuth(profile) else { return nil }
            let tokens = auth["tokens"] as? [String: Any]
            let refresh = Self.nonEmpty(tokens?["refresh_token"]) ?? ""
            let access = Self.nonEmpty(tokens?["access_token"]) ?? ""
            let idTok = Self.nonEmpty(tokens?["id_token"]) ?? ""
            let apiKey = Self.nonEmpty(auth["OPENAI_API_KEY"]) ?? ""
            raw = "codex|\(key)|\(refresh)|\(access)|\(idTok)|\(apiKey)|\(state.lastRefresh?.timeIntervalSince1970 ?? 0)"
        case .agy:
            guard let rec = agyTokenRecord(profile, keychain: keychain), Self.isUsableAgyCredential(rec.credential) else { return nil }
            raw = "agy|\(key)|\(rec.credential.refreshToken ?? "")|\(rec.credential.accessToken ?? "")|\(rec.credential.expiry?.timeIntervalSince1970 ?? 0)"
        }
        return SHA256.hex(Data(raw.utf8))
    }
}

extension ISO8601DateFormatter {
    static func lenient(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - doctor

public struct DoctorFinding: Equatable, Sendable {
    public enum Level: String, Sendable { case ok, note, warn, problem }
    public var level: Level
    public var message: String
}

public struct CLIDoctor {
    public var profiles: CLIProfiles
    public var keychain: CLIKeychain
    /// rc files to check for the PATH block.
    public var rcFiles: [String]
    /// Resolves a command the way a shell would: (shell mode label, path or nil). Injected in tests.
    public var resolve: (_ command: String) -> [(String, String?)]

    public init(profiles: CLIProfiles, keychain: CLIKeychain, rcFiles: [String], resolve: @escaping (String) -> [(String, String?)]) {
        self.profiles = profiles
        self.keychain = keychain
        self.rcFiles = rcFiles
        self.resolve = resolve
    }

    /// How `zsh` finds a command in a login, an interactive and a plain shell.
    public static func zshResolve(_ command: String) -> [(String, String?)] {
        [("zsh -lc", ["-lc"]), ("zsh -ic", ["-ic"]), ("zsh -c", ["-c"])].map { label, flags in
            (label, lastPathLine(shell: "/bin/zsh", flags: flags, script: "command -v \(command)", timeout: 10))
        }
    }

    /// Runs `shell flags… script` and returns the last output line when it is an absolute path.
    static func lastPathLine(shell: String, flags: [String], script: String, timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = flags + [script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // Drain stdout while the shell runs: a startup file that prints more than a pipe holds
        // would otherwise block the shell on write and never let it exit.
        let reader = DrainedOutput(out.fileHandleForReading)
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminateAndWait(grace: 1)
            reader.finish(waiting: 1)
            return nil
        }
        let s = String(decoding: reader.finish(waiting: 1), as: UTF8.self)
        let last = s.split(separator: "\n").last.map(String.init)
        return last?.hasPrefix("/") == true ? last : nil
    }

    public func run() -> [DoctorFinding] {
        var f: [DoctorFinding] = []
        let env = profiles.env
        func add(_ l: DoctorFinding.Level, _ m: String) { f.append(DoctorFinding(level: l, message: m)) }

        // Shims and PATH.
        for kind in CLIKind.allCases {
            let shim = env.shim(kind)
            guard CLIShim.isShim(shim) else {
                add(.warn, "\(kind.command): no Switcher shim yet, so the pointer has no effect (run `switcher cli install`)")
                continue
            }
            if let real = CLIShim.realBinary(ofShim: shim) {
                if !real.hasPrefix("/") || !CLIShim.isRegularExecutable(real) {
                    add(.problem, "\(kind.command): the shim runs \(real), which is missing")
                } else if CLIShim.isShim(real) {
                    add(.problem, "\(kind.command): the shim runs another shim (\(real))")
                }
            }
            for (mode, path) in resolve(kind.command) {
                if path == shim { continue }
                add(.warn, "\(kind.command): `\(mode)` finds \(path ?? "nothing") before the shim; new processes there ignore the pointer")
            }
        }
        for rc in rcFiles {
            let text: String
            do { text = try CLIShim.readRC(rc) } catch {
                add(.problem, error.localizedDescription)
                continue
            }
            switch CLIShim.rcState(text) {
            case .absent: add(.note, "\(rc): no Switcher PATH line")
            case .notLast: add(.warn, "\(rc): lines after Switcher's PATH line may put another claude/codex/agy first; `switcher cli install` moves it to the end")
            case .malformed: add(.problem, "\(rc): incomplete or duplicated Switcher lines; fix or remove them by hand")
            case .last: break
            }
        }

        // Pointers and profiles.
        for kind in CLIKind.allCases {
            let root = env.profilesRoot(kind)
            if let raw = try? String(contentsOfFile: env.pointer(kind), encoding: .utf8) {
                let line = raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if line != "default", !line.isEmpty, profiles.active(kind).isDefault {
                    if CLIPath.problem(line, root: root) == nil, CLIProfiles.lstatMode(line) == nil {
                        add(.warn, "\(kind.displayName): the pointer points to a missing profile folder (\(line)); new processes use the default account")
                    } else {
                        add(.warn, "\(kind.displayName): the pointer names \(line), which is not a valid profile folder; new processes use the default account")
                    }
                }
            }
            if CLIProfiles.lstatMode(root) != nil, !CLIProfiles.isRealDirectory(root) {
                add(.problem, "\(kind.displayName): \(root) is not a real folder (a symlink or a file)")
            } else {
                for name in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted() where !name.hasPrefix(".") {
                    let path = root + "/" + name
                    if !CLIPath.isValidName(name) || !CLIProfiles.isRealDirectory(path) {
                        add(.note, "\(kind.displayName): \(path) is skipped (a symlink, a file or an unusual name)")
                    }
                }
            }
            for p in profiles.list(kind) {
                let label = "\(kind.displayName) \(p.name)"
                if let problem = profiles.credentialProblem(p, keychain: keychain) {
                    add(.problem, "\(label): \(problem)")
                } else {
                    let s = profiles.signIn(p, keychain: keychain)
                    switch s.state {
                    case .signedOut: add(.warn, "\(label): not signed in; run \(kind.loginCommand(p))")
                    case .other(let mode): add(.note, "\(label): signed in with \(mode); quota is not shown for it")
                    case .signedIn:
                        if let r = s.refreshExpiresAt {
                            let days = r.timeIntervalSinceNow / 86_400
                            if days < 0 { add(.problem, "\(label): the sign-in ran out; run \(kind.loginCommand(p))") }
                            else if days < 5 { add(.warn, "\(label): the sign-in runs out in \(Int(days.rounded(.up))) day(s) unless it is used") }
                        }
                    }
                }
                if kind == .agy, !p.isDefault {
                    let marker = p.path + "/antigravity-cli/cache/antigravity-keyring-unavailable"
                    var mst = stat()
                    if lstat(marker, &mst) != 0 || (mst.st_mode & S_IFMT) != S_IFREG {
                        add(.warn, "\(label): keyring-isolation marker is missing (`switcher cli link agy` restores it)")
                    }
                }
                for c in profiles.checkLinks(p) {
                    switch c.state {
                    case .ok, .nothingToShare: break
                    case .missing: add(.note, "\(label): \(c.item) is not linked yet (`switcher cli link` adds it)")
                    case .wrongTarget(let t): add(.warn, "\(label): \(c.item) links to \(t), not the default folder")
                    case .replaced: add(.warn, "\(label): \(c.item) is a real file now, not a link; it no longer follows the default folder")
                    }
                }
                let mcp = profiles.mcpDifference(p)
                if !mcp.missing.isEmpty { add(.note, "\(label): MCP servers only the default account has: \(mcp.missing.joined(separator: ", "))") }
            }
        }

        // Claude keychain items nobody uses, and the stale plaintext fallback.
        let expected = Set(profiles.list(.claude).map { claudeKeychainService(configDir: $0.envValue) })
        let byHash: [String: String] = Dictionary(uniqueKeysWithValues: [env.defaultFolder(.claude), env.defaultFolder(.claude) + "/"].map { (claudeKeychainService(configDir: $0), $0) })
        for service in keychain.claudeServices() where !expected.contains(service) {
            let why = byHash[service].map { " (it is what CLAUDE_CONFIG_DIR=\($0) reads; leave that variable unset for the default account)" } ?? " (another tool's folder, e.g. Orca, or a deleted profile)"
            add(.note, "keychain item \"\(service)\" is not one of Switcher's profiles\(why). Switcher never deletes it.")
        }
        let defaultClaude = profiles.defaultProfile(.claude)
        if keychain.exists(service: claudeKeychainService(configDir: nil)), FileManager.default.fileExists(atPath: defaultClaude.path + "/.credentials.json") {
            add(.note, "\(defaultClaude.path)/.credentials.json exists next to the keychain sign-in; Claude Code reads the keychain first. Switcher never deletes it.")
        }
        if f.allSatisfy({ $0.level == .note }) { add(.ok, "no problems found") }
        return f
    }
}

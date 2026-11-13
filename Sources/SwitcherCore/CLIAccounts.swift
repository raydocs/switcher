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
    /// Every `Claude Code-credentials*` service name in the login keychain.
    func claudeServices() -> [String]
}

public final class LiveCLIKeychain: CLIKeychain {
    let account: String
    public init(account: String = NSUserName()) { self.account = account }

    public func read(service: String) -> String? {
        let (status, out) = Self.security(["find-generic-password", "-a", account, "-s", service, "-w"])
        guard status == 0 else { return nil }
        return out.hasSuffix("\n") ? String(out.dropLast()) : out
    }

    public func exists(service: String) -> Bool {
        Self.security(["find-generic-password", "-a", account, "-s", service]).0 == 0
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
    public func claudeServices() -> [String] { items.keys.filter { $0.hasPrefix("Claude Code-credentials") }.sorted() }
}

extension CLIProfiles {
    public func identity(_ profile: CLIProfile) -> CLIIdentity? {
        switch profile.kind {
        case .claude:
            guard let d = fm.contents(atPath: env.claudeJSON(profile)),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let a = o["oauthAccount"] as? [String: Any] else { return nil }
            let key = (a["accountUuid"] as? String).map { "\($0):\(a["organizationUuid"] as? String ?? "")" }
            return CLIIdentity(email: a["emailAddress"] as? String, organization: a["organizationName"] as? String, plan: nil, accountKey: key)
        case .codex:
            guard let auth = codexAuth(profile), let tokens = auth["tokens"] as? [String: Any] else { return nil }
            let claims = (tokens["id_token"] as? String).flatMap(Self.jwtClaims) ?? [:]
            let openai = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
            let accountID = tokens["account_id"] as? String ?? openai["chatgpt_account_id"] as? String
            return CLIIdentity(email: claims["email"] as? String, organization: nil,
                               plan: openai["chatgpt_plan_type"] as? String, accountKey: accountID)
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

    public func signIn(_ profile: CLIProfile, keychain: CLIKeychain) -> CLISignIn {
        func date(_ v: Any?) -> Date? { (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        switch profile.kind {
        case .claude:
            guard let o = claudeOAuth(profile, keychain: keychain), o["accessToken"] is String else { return CLISignIn(state: .signedOut) }
            return CLISignIn(state: .signedIn, accessExpiresAt: date(o["expiresAt"]), refreshExpiresAt: date(o["refreshTokenExpiresAt"]))
        case .codex:
            guard let auth = codexAuth(profile) else { return CLISignIn(state: .signedOut) }
            let mode = auth["auth_mode"] as? String ?? (auth["tokens"] != nil ? "chatgpt" : "apikey")
            let last = (auth["last_refresh"] as? String).flatMap { ISO8601DateFormatter.lenient($0) }
            guard (auth["tokens"] as? [String: Any])?["refresh_token"] is String else {
                return CLISignIn(state: mode == "chatgpt" ? .signedOut : .other(mode), lastRefresh: last)
            }
            return CLISignIn(state: mode.lowercased().contains("chatgpt") ? .signedIn : .other(mode), lastRefresh: last)
        }
    }

    /// The Claude subscription type the credentials name (`pro`, `max`, …).
    public func claudeSubscription(_ profile: CLIProfile, keychain: CLIKeychain) -> String? {
        claudeOAuth(profile, keychain: keychain)?["subscriptionType"] as? String
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
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = flags + ["command -v \(command)"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return (label, nil) }
            let deadline = Date().addingTimeInterval(10)
            while p.isRunning, Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate(); return (label, nil) }
            let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let last = s.split(separator: "\n").last.map(String.init)
            return (label, last?.hasPrefix("/") == true ? last : nil)
        }
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
                if !FileManager.default.isExecutableFile(atPath: real) { add(.problem, "\(kind.command): the shim runs \(real), which is missing") }
                else if CLIShim.isShim(real) { add(.problem, "\(kind.command): the shim runs another shim (\(real))") }
            }
            for (mode, path) in resolve(kind.command) {
                if path == shim { continue }
                add(.warn, "\(kind.command): `\(mode)` finds \(path ?? "nothing") before the shim; new processes there ignore the pointer")
            }
        }
        for rc in rcFiles {
            let text = (try? String(contentsOfFile: rc, encoding: .utf8)) ?? ""
            switch CLIShim.rcState(text) {
            case .absent: add(.note, "\(rc): no Switcher PATH line")
            case .notLast: add(.warn, "\(rc): lines after Switcher's PATH line may put another claude/codex first; `switcher cli install` moves it to the end")
            case .last: break
            }
        }

        // Pointers and profiles.
        for kind in CLIKind.allCases {
            if let raw = try? String(contentsOfFile: env.pointer(kind), encoding: .utf8) {
                let line = raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if line != "default", !line.isEmpty, profiles.active(kind).isDefault {
                    add(.warn, "\(kind.displayName): the pointer names \(line), which is not a valid profile folder; new processes use the default account")
                }
            }
            let root = env.profilesRoot(kind)
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted() where !name.hasPrefix(".") {
                let path = root + "/" + name
                if !CLIPath.isValidName(name) || !CLIProfiles.isRealDirectory(path) {
                    add(.note, "\(kind.displayName): \(path) is skipped (a symlink, a file or an unusual name)")
                }
            }
            for p in profiles.list(kind) {
                let label = "\(kind.displayName) \(p.name)"
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
        let byHash = Dictionary(uniqueKeysWithValues: [env.defaultFolder(.claude), env.defaultFolder(.claude) + "/"].map { (claudeKeychainService(configDir: $0), $0) })
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

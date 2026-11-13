import Foundation

// The parts of `switcher cli …` worth testing: argument parsing, the list rows, and the
// environment `cli exec` hands to a command. The command line tool only prints and execs.

public enum CLICommands {
    /// `claude` / `cc` → Claude Code, `codex` / `co` → Codex.
    public static func kind(_ s: String?) -> CLIKind? {
        switch s?.lowercased() {
        case "claude", "cc": .claude
        case "codex", "co": .codex
        default: nil
        }
    }

    /// `<who>`: a number (1 = the default account), a name, or `default`.
    public static func profile(_ profiles: CLIProfiles, _ kind: CLIKind, _ who: String) throws -> CLIProfile {
        guard let p = profiles.resolve(kind, who) else {
            throw SwitcherError.message("no \(kind.displayName) account matches \"\(who)\" (see `switcher cli list`)")
        }
        return p
    }

    // MARK: exec

    public struct ExecRequest: Equatable, Sendable {
        public var kind: CLIKind
        public var who: String
        /// Empty: run the real binary of `kind`.
        public var command: [String]
    }

    /// `<cli> <who> [-- <command> [args…]]`.
    public static func parseExec(_ args: [String]) throws -> ExecRequest {
        let split = args.firstIndex(of: "--")
        let head = split.map { Array(args[..<$0]) } ?? args
        let command = split.map { Array(args[($0 + 1)...]) } ?? []
        guard let kind = kind(head.first) else { throw SwitcherError.message("say which CLI: claude or codex") }
        guard head.count >= 2 else { throw SwitcherError.message("say which account: a number, a name or default") }
        guard head.count == 2 else { throw SwitcherError.message("put the command after --, e.g. switcher cli exec \(kind.command) \(head[1]) -- <command>") }
        if split != nil, command.isEmpty { throw SwitcherError.message("nothing after --") }
        return ExecRequest(kind: kind, who: head[1], command: command)
    }

    /// What to change in the environment before the exec: set the profile's variable, or unset it
    /// for the default account (never set to `~/.claude`: that would read another keychain item),
    /// and always drop `SWITCHER_BYPASS` so a shim further down still honours the choice.
    public static func envEdits(_ profile: CLIProfile) -> [(name: String, value: String?)] {
        [(profile.kind.envVar, profile.envValue), ("SWITCHER_BYPASS", nil)]
    }

    /// `base` with `envEdits(profile)` applied.
    public static func environment(base: [String: String], profile: CLIProfile) -> [String: String] {
        var out = base
        for (name, value) in envEdits(profile) { out[name] = value }
        return out
    }

    // MARK: rc files

    /// `~/.zshrc`, and `~/.bashrc` only if it exists.
    public static func rcFiles(_ env: CLIEnv) -> [String] {
        let bash = env.home + "/.bashrc"
        return [env.home + "/.zshrc"] + (FileManager.default.fileExists(atPath: bash) ? [bash] : [])
    }

    // MARK: list

    public struct ListEntry: Codable, Equatable, Sendable {
        public var number: Int
        public var name: String
        public var path: String
        public var isDefault: Bool
        public var active: Bool
        public var email: String?
        public var organization: String?
        public var plan: String?
        /// `signedIn`, `signedOut` or `other`.
        public var signIn: String
        /// For `other`: how the account signs in (`apikey`, …).
        public var signInMode: String?
        /// When the sign-in runs out unless the CLI is used before then.
        public var signInGoodUntil: Date?
        /// Set when the account is not signed in.
        public var loginCommand: String?

        /// One line for the terminal.
        public func line() -> String {
            var parts = ["\(active ? "●" : " ") \(number). \(name)"]
            if let email { parts.append(email) }
            if let plan { parts.append("(\(plan))") }
            switch signIn {
            case "signedIn":
                parts.append(signInGoodUntil.map { "sign-in good until \(Self.day($0))" } ?? "signed in")
            case "other":
                parts.append("signed in with \(signInMode ?? "another method")")
            default:
                parts.append("not signed in → \(loginCommand ?? "")")
            }
            return parts.joined(separator: "  ")
        }

        static func day(_ d: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: d)
        }
    }

    public struct ListGroup: Codable, Equatable, Sendable {
        public var cli: String
        public var name: String
        /// Whether the PATH shim exists, so the pointer has an effect.
        public var shimInstalled: Bool
        public var profiles: [ListEntry]
    }

    /// Every CLI's profiles with who they are signed in as. Never contains a token.
    public static func list(_ profiles: CLIProfiles, keychain: CLIKeychain, kinds: [CLIKind] = CLIKind.allCases) -> [ListGroup] {
        kinds.map { kind in
            let active = profiles.active(kind)
            let entries = profiles.list(kind).enumerated().map { i, p -> ListEntry in
                let id = profiles.identity(p)
                let s = profiles.signIn(p, keychain: keychain)
                let signIn: String, mode: String?
                switch s.state {
                case .signedIn: (signIn, mode) = ("signedIn", nil)
                case .signedOut: (signIn, mode) = ("signedOut", nil)
                case .other(let m): (signIn, mode) = ("other", m)
                }
                let plan = id?.plan ?? (kind == .claude && s.state == .signedIn ? profiles.claudeSubscription(p, keychain: keychain) : nil)
                return ListEntry(number: i + 1, name: p.name, path: p.path, isDefault: p.isDefault, active: p.path == active.path,
                                 email: id?.email, organization: id?.organization, plan: plan,
                                 signIn: signIn, signInMode: mode, signInGoodUntil: s.state == .signedIn ? s.refreshExpiresAt : nil,
                                 loginCommand: s.state == .signedOut ? kind.loginCommand(p) : nil)
            }
            return ListGroup(cli: kind.command, name: kind.displayName, shimInstalled: CLIShim.isShim(profiles.env.shim(kind)), profiles: entries)
        }
    }

    public static func listJSON(_ groups: [ListGroup]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return String(decoding: try enc.encode(groups), as: UTF8.self)
    }
}

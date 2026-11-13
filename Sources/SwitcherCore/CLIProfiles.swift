import Foundation

// Claude Code and Codex CLI accounts as profile folders.
//
// A CLI account never moves: each one lives in its own folder, signed in there once, and is
// chosen per process with `CLAUDE_CONFIG_DIR` / `CODEX_HOME`. `~/.claude` and `~/.codex` are the
// default account (no variable set). Switching only rewrites a one-line pointer that Switcher's
// PATH shims read when a new `claude` / `codex` starts; running sessions keep their own folder.
//
// Paths are Strings end to end, never `URL` round trips: Claude Code names a folder's keychain
// item after the SHA-256 of the exact `CLAUDE_CONFIG_DIR` string (a symlink or a trailing slash
// gives another item), so a profile's path must reach the CLI byte for byte as registered.

public enum CLIKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The variable that picks the folder.
    public var envVar: String {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        }
    }

    /// The command the shim stands in for.
    public var command: String { rawValue }

    var defaultFolderName: String {
        switch self {
        case .claude: ".claude"
        case .codex: ".codex"
        }
    }

    /// The same folder names token-arcade reads.
    var profilesFolderName: String {
        switch self {
        case .claude: ".claude-profiles"
        case .codex: ".codex-profiles"
        }
    }

    /// The command to sign a profile in, as the user types it.
    public func loginCommand(_ profile: CLIProfile) -> String {
        // The default account clears the variable and bypasses the shim, which would otherwise
        // follow the pointer to another account.
        let prefix = profile.isDefault ? "env -u \(envVar) SWITCHER_BYPASS=1 " : "\(envVar)=\(shellQuote(profile.path)) "
        switch self {
        case .claude: return "\(prefix)claude   # then type /login"
        case .codex: return "\(prefix)codex login"
        }
    }
}

/// One CLI account folder.
public struct CLIProfile: Equatable, Codable, Sendable, Identifiable {
    public var kind: CLIKind
    /// `default`, or the folder's name under the profiles folder.
    public var name: String
    /// The exact string passed as the variable. For the default profile, the folder itself (the
    /// variable is left unset).
    public var path: String
    public var isDefault: Bool

    public var id: String { "\(kind.rawValue):\(name)" }

    /// What the variable is set to, or nil to leave it unset.
    public var envValue: String? { isDefault ? nil : path }
}

/// Where the CLI profiles, pointers and shims live. Tests point `home` at a temporary folder.
public struct CLIEnv: Sendable {
    public var home: String
    /// Pointer files: `~/.config/switcher`.
    public var config: String
    /// Generated shims: `~/.local/share/switcher/bin`.
    public var shimDir: String
    /// The real binaries the shims exec. Found at install time when nil.
    public var realBinaries: [CLIKind: String]

    public init(home: String, config: String? = nil, shimDir: String? = nil, realBinaries: [CLIKind: String] = [:]) {
        let home = CLIPath.trimmed(home)
        self.home = home
        self.config = config ?? home + "/.config/switcher"
        self.shimDir = shimDir ?? home + "/.local/share/switcher/bin"
        self.realBinaries = realBinaries
    }

    public static var live: CLIEnv { CLIEnv(home: NSHomeDirectory()) }

    public func defaultFolder(_ kind: CLIKind) -> String { home + "/" + kind.defaultFolderName }
    public func profilesRoot(_ kind: CLIKind) -> String { home + "/" + kind.profilesFolderName }
    public func pointer(_ kind: CLIKind) -> String { config + "/active-" + kind.rawValue }
    public func shim(_ kind: CLIKind) -> String { shimDir + "/" + kind.command }

    /// Claude Code keeps the default account's `.claude.json` next to the folder, not in it.
    public func claudeJSON(_ profile: CLIProfile) -> String {
        profile.isDefault ? home + "/.claude.json" : profile.path + "/.claude.json"
    }
}

public enum CLIPath {
    /// `/a/b/` → `/a/b` (only for the home folder we are given; profile paths are never repaired).
    static func trimmed(_ s: String) -> String {
        var s = s
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// A profile name: a plain folder name, safe inside single quotes and a pointer file.
    public static func isValidName(_ name: String) -> Bool {
        // The PATH shim enforces the same rule in sh: 1-64 of [A-Za-z0-9._-], not starting with . or -.
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 64, name != "default", bytes[0] != UInt8(ascii: "."), bytes[0] != UInt8(ascii: "-") else { return false }
        return bytes.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F || b == 0x2E
        }
    }

    /// Why `path` cannot be a profile path under `root`, or nil when it can: absolute, exactly
    /// `root/<valid name>`, no trailing slash, no `.`/`..`/empty components.
    public static func problem(_ path: String, root: String) -> String? {
        guard path.hasPrefix(root + "/") else { return "not inside \(root)" }
        let name = String(path.dropFirst(root.count + 1))
        guard isValidName(name) else { return "not a plain folder name: \(name)" }
        return nil
    }
}

/// Claude Code's keychain item for a config folder: `Claude Code-credentials`, plus `-` and the
/// first 8 hex digits of SHA-256 of the exact `CLAUDE_CONFIG_DIR` string when it is set.
/// Verified against claude 2.1.323 (a symlink or trailing slash changes the hash).
public func claudeKeychainService(configDir: String?) -> String {
    guard let configDir else { return "Claude Code-credentials" }
    return "Claude Code-credentials-" + SHA256.hex(Data(configDir.utf8)).prefix(8)
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: - Registry and pointer

public final class CLIProfiles {
    public let env: CLIEnv
    let fm = FileManager.default

    public init(env: CLIEnv = .live) { self.env = env }

    public func defaultProfile(_ kind: CLIKind) -> CLIProfile {
        CLIProfile(kind: kind, name: "default", path: env.defaultFolder(kind), isDefault: true)
    }

    /// The default account first, then every valid folder under the profiles folder by name.
    /// Symlinks and odd names are skipped (and reported by `doctor`).
    public func list(_ kind: CLIKind) -> [CLIProfile] {
        let root = env.profilesRoot(kind)
        let names = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { name in
            CLIPath.isValidName(name) && Self.isRealDirectory(root + "/" + name)
        }.sorted()
        return [defaultProfile(kind)] + names.map { CLIProfile(kind: kind, name: $0, path: root + "/" + $0, isDefault: false) }
    }

    /// `1` is the default account, `2…` the profiles in name order; or a name, or `default`.
    public func resolve(_ kind: CLIKind, _ query: String) -> CLIProfile? {
        let all = list(kind)
        if let n = Int(query), n >= 1, n <= all.count { return all[n - 1] }
        return all.first { $0.name == query } ?? all.first { $0.name.lowercased() == query.lowercased() }
    }

    /// The profile new `claude` / `codex` processes get. A missing or invalid pointer is the
    /// default account, as the shim reads it.
    public func active(_ kind: CLIKind) -> CLIProfile {
        guard let raw = try? String(contentsOfFile: env.pointer(kind), encoding: .utf8) else { return defaultProfile(kind) }
        let line = raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if line.isEmpty || line == "default" { return defaultProfile(kind) }
        guard CLIPath.problem(line, root: env.profilesRoot(kind)) == nil, Self.isRealDirectory(line) else { return defaultProfile(kind) }
        return CLIProfile(kind: kind, name: String(line.dropFirst(env.profilesRoot(kind).count + 1)), path: line, isDefault: false)
    }

    /// Point new processes at `profile`. Atomic; running sessions are not affected.
    public func setActive(_ profile: CLIProfile) throws {
        let line: String
        if profile.isDefault {
            line = "default"
        } else {
            if let p = CLIPath.problem(profile.path, root: env.profilesRoot(profile.kind)) { throw SwitcherError.message("\(profile.path): \(p)") }
            guard Self.isRealDirectory(profile.path) else { throw SwitcherError.message("\(profile.path) is not a folder") }
            line = profile.path
        }
        try FS.makePrivateDir(URL(fileURLWithPath: env.config, isDirectory: true))
        try FS.atomicWrite(Data((line + "\n").utf8), to: URL(fileURLWithPath: env.pointer(profile.kind)))
    }

    /// The next profile after the active one, wrapping around.
    public func next(_ kind: CLIKind) -> CLIProfile? {
        let all = list(kind)
        guard all.count > 1 else { return nil }
        let i = all.firstIndex { $0.path == active(kind).path } ?? 0
        return all[(i + 1) % all.count]
    }

    /// Create a profile folder (0700), link the shared configuration into it and, for Claude,
    /// seed its `.claude.json` with the default account's MCP servers and project trust. The
    /// account is signed in afterwards with `kind.loginCommand(profile)`.
    @discardableResult
    public func add(_ kind: CLIKind, name: String) throws -> CLIProfile {
        guard CLIPath.isValidName(name) else { throw SwitcherError.message("use letters, digits, - _ . for the name (not \"default\")") }
        let path = env.profilesRoot(kind) + "/" + name
        guard !FS.exists(URL(fileURLWithPath: path)) else { throw SwitcherError.message("\(path) already exists") }
        try FS.makePrivateDir(URL(fileURLWithPath: env.profilesRoot(kind), isDirectory: true))
        try FS.makePrivateDir(URL(fileURLWithPath: path, isDirectory: true))
        let profile = CLIProfile(kind: kind, name: name, path: path, isDefault: false)
        _ = try applyLinks(profile)
        if kind == .claude { try seedClaudeJSON(profile) }
        return profile
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: Shared configuration

    /// What every profile shares with the default folder, as symlinks into it: configuration,
    /// and the session history so `--resume` works after a switch. Sign-ins, `.claude.json`,
    /// caches and databases stay per profile. Verified on claude 2.1.323 / codex 0.167.2 that
    /// `plugin enable/disable` and `codex mcp add/remove` write through a `settings.json` /
    /// `config.toml` link without replacing it; `doctor` reports a link that was replaced anyway.
    public static func sharedItems(_ kind: CLIKind) -> [String] {
        switch kind {
        case .claude:
            ["agents", "commands", "skills", "plugins", "scripts", "hooks", "projects", "file-history", "todos",
             "CLAUDE.md", "settings.json", "keybindings.json", "history.jsonl"]
        case .codex:
            ["skills", "plugins", "rules", "prompts", "sessions", "archived_sessions",
             "AGENTS.md", "config.toml", "session_index.jsonl", "history.jsonl"]
        }
    }

    public enum LinkState: Equatable, Sendable {
        case ok
        /// Nothing there yet (applyLinks makes it).
        case missing
        /// The default folder has nothing to share under this name.
        case nothingToShare
        /// A symlink, but to somewhere else.
        case wrongTarget(String)
        /// A real file or folder took the link's place (a CLI rewrote it): never overwritten.
        case replaced
    }

    public struct LinkCheck: Equatable, Sendable {
        public var item: String
        public var state: LinkState
    }

    public func checkLinks(_ profile: CLIProfile) -> [LinkCheck] {
        guard !profile.isDefault else { return [] }
        let source = env.defaultFolder(profile.kind)
        return Self.sharedItems(profile.kind).map { item in
            let link = profile.path + "/" + item, target = source + "/" + item
            var st = stat()
            if lstat(link, &st) != 0 {
                return LinkCheck(item: item, state: FS.exists(URL(fileURLWithPath: target)) ? .missing : .nothingToShare)
            }
            guard (st.st_mode & S_IFMT) == S_IFLNK else { return LinkCheck(item: item, state: .replaced) }
            let dest = (try? fm.destinationOfSymbolicLink(atPath: link)) ?? ""
            return LinkCheck(item: item, state: dest == target ? .ok : .wrongTarget(dest))
        }
    }

    /// Make every missing link. Never replaces anything already there. Returns the items linked.
    @discardableResult
    public func applyLinks(_ profile: CLIProfile) throws -> [String] {
        var made: [String] = []
        for check in checkLinks(profile) where check.state == .missing {
            try fm.createSymbolicLink(atPath: profile.path + "/" + check.item, withDestinationPath: env.defaultFolder(profile.kind) + "/" + check.item)
            made.append(check.item)
        }
        return made
    }

    /// Keys of the default `~/.claude.json` a new profile starts with. Everything else (the
    /// signed-in account, its caches and flags) Claude Code writes for the new account itself.
    public static let seededClaudeKeys = ["mcpServers", "projects", "hasCompletedOnboarding", "theme"]

    func seedClaudeJSON(_ profile: CLIProfile) throws {
        let dest = env.claudeJSON(profile)
        guard !FS.exists(URL(fileURLWithPath: dest)),
              let data = fm.contents(atPath: env.claudeJSON(defaultProfile(.claude))),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let seed = root.filter { Self.seededClaudeKeys.contains($0.key) }
        guard !seed.isEmpty else { return }
        let out = try JSONSerialization.data(withJSONObject: seed, options: [.prettyPrinted, .sortedKeys])
        try FS.atomicWrite(out, to: URL(fileURLWithPath: dest))
    }

    /// `mcpServers` names the default account has and this profile lacks, and the other way round.
    public func mcpDifference(_ profile: CLIProfile) -> (missing: [String], extra: [String]) {
        guard profile.kind == .claude, !profile.isDefault else { return ([], []) }
        func names(_ path: String) -> Set<String> {
            guard let d = fm.contents(atPath: path), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let m = o["mcpServers"] as? [String: Any] else { return [] }
            return Set(m.keys)
        }
        let base = names(env.claudeJSON(defaultProfile(.claude))), mine = names(env.claudeJSON(profile))
        return (base.subtracting(mine).sorted(), mine.subtracting(base).sorted())
    }
}

// MARK: - SHA-256 (no CryptoKit dependency issues on the command line tool; tiny and tested)

enum SHA256 {
    static func hex(_ data: Data) -> String { digest(data).map { String(format: "%02x", $0) }.joined() }

    static func digest(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var msg = [UInt8](data)
        let bitLength = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8((v >> (UInt32($0) * 8)) & 0xff) } }
    }
}

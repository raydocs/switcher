import Foundation

/// Display metadata for CLI profiles, stored in `<CLIEnv.config>/cli-meta.json` (0600).
///
/// CLI profile folders are never renamed on disk because Claude Code hashes the raw
/// `CLAUDE_CONFIG_DIR` string to name its keychain entry. Aliases live here instead, keyed by
/// `"<kind>:<folderName>"`.
public struct CLIMeta: Codable, Equatable, Sendable {
    public var version = 1
    public var aliases: [String: String] = [:]

    public init(version: Int = 1, aliases: [String: String] = [:]) {
        self.version = version
        self.aliases = aliases
    }

    public static func key(_ kind: CLIKind, _ name: String) -> String { "\(kind.rawValue):\(name)" }

    public func alias(for profile: CLIProfile) -> String? {
        alias(kind: profile.kind, name: profile.name)
    }

    public func alias(kind: CLIKind, name: String) -> String? {
        aliases[Self.key(kind, name)]
    }

    /// Set or clear (`nil` / empty) a display alias for a CLI profile.
    /// Up to 32 characters, no control characters, not solely digits, and unique per CLI kind.
    public mutating func setAlias(kind: CLIKind, name: String, _ raw: String?) throws {
        let key = Self.key(kind, name)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            aliases.removeValue(forKey: key)
            return
        }
        guard trimmed.count <= 32,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !trimmed.allSatisfy(\.isNumber) else {
            throw SwitcherError.message(L10n.t(
                "An alias is up to 32 characters, without control characters, and not only digits.",
                "别名最多 32 个字符，不能包含控制字符，也不能全是数字。"))
        }
        let prefix = kind.rawValue + ":"
        let lower = trimmed.lowercased()
        if aliases.contains(where: { $0.key.hasPrefix(prefix) && $0.key != key && $0.value.lowercased() == lower }) {
            throw SwitcherError.message(L10n.t(
                "Another \(kind.displayName) account already uses that alias.",
                "另一个 \(kind.displayName) 账号已经在使用这个别名。"))
        }
        aliases[key] = trimmed
    }

    public mutating func remove(kind: CLIKind, name: String) {
        aliases.removeValue(forKey: Self.key(kind, name))
    }

    /// Returns the profile name matching `query` by alias for `kind`, if any.
    public func profileName(kind: CLIKind, matchingAlias query: String) -> String? {
        let prefix = kind.rawValue + ":"
        let exact = aliases.first { $0.key.hasPrefix(prefix) && $0.value == query }
            ?? aliases.first { $0.key.hasPrefix(prefix) && $0.value.lowercased() == query.lowercased() }
        return exact.map { String($0.key.dropFirst(prefix.count)) }
    }

    // MARK: Storage

    public static func url(_ env: CLIEnv) -> URL {
        URL(fileURLWithPath: env.config + "/cli-meta.json")
    }

    public static func load(_ env: CLIEnv) -> CLIMeta {
        FS.readCodable(CLIMeta.self, from: url(env)) ?? CLIMeta()
    }

    public func save(_ env: CLIEnv) throws {
        try FS.makePrivateDir(URL(fileURLWithPath: env.config, isDirectory: true))
        try FS.writeCodable(self, to: Self.url(env))
    }

    /// Load, mutate and atomically save under a dedicated lock.
    @discardableResult
    public static func edit<T>(_ env: CLIEnv, _ body: (inout CLIMeta) throws -> T) throws -> T {
        try FS.makePrivateDir(URL(fileURLWithPath: env.config, isDirectory: true))
        let lock = try FileLock(URL(fileURLWithPath: env.config + "/cli-meta.lock"), timeout: 5)
        defer { withExtendedLifetime(lock) {} }
        var meta = load(env)
        let before = meta
        let out = try body(&meta)
        if meta != before { try meta.save(env) }
        return out
    }
}

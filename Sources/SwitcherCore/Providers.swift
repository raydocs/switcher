import Foundation

public struct SwitchResult: Equatable {
    public var from: Identity?
    public var to: String?
    public var launched: Bool
}

public enum SwitchRefused: Error, LocalizedError, Equatable {
    case notInstalled(String)
    case nothingSaved

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let app): "\(app) is not installed."
        case .nothingSaved: "No sign-in is saved for that account yet. Sign in to it once in the app."
        }
    }
}

/// One app whose sign-in Switcher trades: Claude Desktop or Antigravity.
public final class Provider {
    public let id: ProviderID
    public let app: AppController
    public let vault: SignInVault
    let env: Env
    let identify: () -> Identity?
    let quitTimeout: TimeInterval
    public var log: (String) -> Void = { _ in }

    init(id: ProviderID, env: Env, app: AppController, vault: SignInVault, quitTimeout: TimeInterval, identify: @escaping () -> Identity?) {
        self.id = id
        self.env = env
        self.app = app
        self.vault = vault
        self.quitTimeout = quitTimeout
        self.identify = identify
    }

    /// Who the app is signed in to, as its own files say.
    public func current() -> Identity? { identify() }

    public func saved() -> [SavedLogin] { vault.saved(excluding: current()?.id) }

    var lockURL: URL { env.state.appendingPathComponent("lock") }

    /// Quit the app, set its sign-in aside, put `target`'s back (nobody's: the app opens on its
    /// sign-in page), and start it again when it was running, when `alwaysLaunch`, or to sign in.
    /// If anything fails after the app quit, it starts again as it was.
    @discardableResult
    public func switchTo(_ target: String?, alwaysLaunch: Bool = false, cancel: CancelToken? = nil, waiting: ((TimeInterval) -> Void)? = nil) throws -> SwitchResult {
        guard app.isInstalled else { throw SwitchRefused.notInstalled(app.name) }
        let lock = try FileLock(lockURL, timeout: 30)
        defer { withExtendedLifetime(lock) {} }
        if let target, !vault.isSaved(target), current()?.id != target { throw SwitchRefused.nothingSaved }
        let wasRunning = app.isRunning
        let from: Identity?
        do {
            if wasRunning { try app.quit(timeout: quitTimeout, cancel: cancel, waiting: waiting) }
            try vault.recover()
            from = current()
            if let from, from.id == target {
                try vault.dropStale(from.id)
            } else {
                try vault.swap(from: from, to: target)
                if let c = vault.cleanupPending { log("switched; tidying up is left for next time: \(c)") }
            }
        } catch {
            let quitFailed = error is QuitError
            if wasRunning, !quitFailed, !app.isRunning { try? app.launch() }
            throw error
        }
        let launch = wasRunning || alwaysLaunch || target == nil
        if launch { try app.launch() }
        return SwitchResult(from: from, to: target, launched: launch)
    }

    /// Finish or undo a switch cut short, when the app is not running.
    public func recoverIfIdle() {
        guard !app.isRunning, let lock = try? FileLock(lockURL, timeout: 0) else { return }
        withExtendedLifetime(lock) {
            do { try vault.recover() } catch { log("finishing an interrupted switch: \(error.localizedDescription)") }
        }
    }
}

// MARK: - Claude Desktop

extension Provider {
    /// Claude Desktop's sign-in: the claude.ai web session (cookies and site storage) and the tokens
    /// it caches in `config.json`, all encrypted with a key in the login keychain. They move as they
    /// are; nothing is decrypted or read.
    public static func claudeLayout(_ env: Env) -> SignInLayout {
        let d = env.claudeData
        return SignInLayout(
            items: ["Cookies", "Cookies-journal", "Local Storage", "Session Storage", "IndexedDB", "WebStorage"].map { d.appendingPathComponent($0) },
            jsonKeys: [.init(file: env.claudeConfig, vaultName: "config.json", keys: ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"])],
            secrets: [],
            drop: [d.appendingPathComponent("bridge-state.json")]
        )
    }

    public static func claude(env: Env = .live, app: AppController = MacApp.claude, keychain: SecretStore = KeychainCLI()) -> Provider {
        let vault = SignInVault(env: env, provider: .claude, layout: claudeLayout(env), keychain: keychain)
        // Long: Claude asks "still working, quit anyway?" while a task runs, and the answer may take a while.
        let provider = Provider(id: .claude, env: env, app: app, vault: vault, quitTimeout: 600) {
            guard let id = ClaudeFiles.lastKnownAccount(env) else { return nil }
            return Identity(id: id, email: ClaudeFiles.emails(env)[id])
        }
        return provider
    }
}

public enum ClaudeFiles {
    public static func lastKnownAccount(_ env: Env) -> String? {
        guard let doc = try? OrderedJSON(contentsOf: env.claudeConfig), let id = doc.string("lastKnownAccountUuid"), isUUID(id) else { return nil }
        return id
    }

    /// Account → email, from what Claude's own files say.
    public static func emails(_ env: Env) -> [String: String] {
        var out: [String: String] = [:]
        if let root = try? FS.readJSONObject(env.claudeJSON), let oa = root["oauthAccount"] as? [String: Any],
           let id = oa["accountUuid"] as? String, let email = oa["emailAddress"] as? String, isUUID(id)
        {
            out[id] = email
        }
        for account in FS.children(env.claudeCoworkSessions) where isUUID(account.lastPathComponent) && out[account.lastPathComponent] == nil {
            search: for org in FS.children(account) where FS.isDirectory(org) {
                for rec in FS.children(org).prefix(25) where rec.lastPathComponent.hasPrefix("local_") && rec.pathExtension == "json" {
                    if let d = try? FS.readJSONObject(rec), let email = d["emailAddress"] as? String, email.contains("@") {
                        out[account.lastPathComponent] = email
                        break search
                    }
                }
            }
        }
        return out
    }

    /// claude.ai caches the signed-in account in its IndexedDB, V8-serialized: the key `uuid` with
    /// the 36-character id, and soon after it `email_address` with the email, each value a one-byte
    /// string (`"`, its length, its bytes). Reads just that pair from the raw files under a Claude
    /// data folder (the live one, or a saved sign-in's): the LevelDB tables, and the blob files
    /// IndexedDB keeps large values in. Nothing there is encrypted.
    public static func webEmails(_ dataDir: URL) -> [String: String] {
        let idb = dataDir.appendingPathComponent("IndexedDB", isDirectory: true)
        let db = idb.appendingPathComponent("https_claude.ai_0.indexeddb.leveldb", isDirectory: true)
        let blobs = idb.appendingPathComponent("https_claude.ai_0.indexeddb.blob", isDirectory: true)
        var files = FS.children(db).filter { ["ldb", "log"].contains($0.pathExtension) }
        if let walk = FileManager.default.enumerator(at: blobs, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walk where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        // Oldest first, so a later write wins.
        files.sort { (FS.mtime($0) ?? .distantPast) < (FS.mtime($1) ?? .distantPast) }
        let idKey = Data("uuid\"$".utf8) // `$` is 36, the id's length
        let emailKey = Data("email_address\"".utf8)
        var out: [String: String] = [:]
        for file in files {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 64 << 20,
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            var from = data.startIndex
            while let hit = data.range(of: idKey, in: from..<data.endIndex) {
                from = hit.upperBound
                guard hit.upperBound + 36 <= data.endIndex else { break }
                let id = String(decoding: data[hit.upperBound..<(hit.upperBound + 36)], as: UTF8.self)
                guard isUUID(id) else { continue }
                let window = (hit.upperBound + 36)..<min(data.endIndex, hit.upperBound + 36 + 64)
                guard let key = data.range(of: emailKey, in: window), key.upperBound < data.endIndex else { continue }
                let length = Int(data[key.upperBound])
                let start = key.upperBound + 1
                guard length > 2, length < 128, start + length <= data.endIndex else { continue }
                let email = String(decoding: data[start..<(start + length)], as: UTF8.self)
                if email.contains("@"), email.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && $0 != "\"" }) {
                    out[id.lowercased()] = email
                }
            }
        }
        return out
    }
}

public func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

// MARK: - Antigravity

extension Provider {
    static let antigravityKeychain = SignInLayout.SecretRef(service: "gemini", account: "antigravity", shape: .goKeyring)

    /// Antigravity 2.x's sign-in: the Google OAuth token its language server keeps in the login
    /// keychain (`gemini` / `antigravity`), the copy it falls back to in
    /// `~/.gemini/jetski-standalone-oauth-token`, and the last sign-in its onboarding remembers
    /// (`jetski.onboarding.*` before 2.3x, `agy.onboarding.*` since).
    public static func antigravityLayout(_ env: Env) -> SignInLayout {
        SignInLayout(
            items: [env.antigravityTokenFile],
            jsonKeys: [.init(file: env.antigravityAppStorage, vaultName: "app_storage.json", keys: AntigravityFiles.onboardingKeys)],
            secrets: [antigravityKeychain],
            drop: []
        )
    }

    public static func antigravity(env: Env = .live, app: AppController = MacApp.antigravity, keychain: SecretStore = KeychainCLI()) -> Provider {
        let vault = SignInVault(env: env, provider: .antigravity, layout: antigravityLayout(env), keychain: keychain)
        return Provider(id: .antigravity, env: env, app: app, vault: vault, quitTimeout: 60) {
            AntigravityFiles.identity(env, keychain: keychain)
        }
    }
}

public enum AntigravityFiles {
    static let lastLogin = ["agy.onboarding.lastLoginUsername", "jetski.onboarding.lastLoginUsername"]
    static let onboardingKeys = ["jetski.onboarding.lastLoginUsername", "jetski.onboarding.lastLoginIsGcpTos",
                                 "agy.onboarding.lastLoginUsername", "agy.onboarding.lastLoginIsGcpTos"]

    /// The account's email, which is also its ID here.
    public static func identity(_ env: Env, keychain: SecretStore) -> Identity? {
        let value = try? keychain.get(service: "gemini", account: "antigravity")
        if let value, let email = email(fromKeyring: value) {
            return Identity(id: email.lowercased(), email: email)
        }
        if let d = try? FS.readJSONObject(env.antigravityTokenFile), let email = d["id_token_email"] as? String, email.contains("@") {
            return Identity(id: email.lowercased(), email: email)
        }
        // Since 2.3x the keychain item carries no email and the token file is gone: while a token is
        // there, the sign-in its onboarding just remembered is the one in use. (Switcher moves these
        // keys with the token, so they never name another account's sign-in.)
        if value != nil, let doc = try? OrderedJSON(contentsOf: env.antigravityAppStorage),
           let email = lastLogin.lazy.compactMap({ doc.string($0) }).first(where: { $0.contains("@") })
        {
            return Identity(id: email.lowercased(), email: email)
        }
        return nil
    }

    /// go-keyring stores `go-keyring-base64:<base64 JSON>`.
    static func email(fromKeyring value: String) -> String? {
        var body = value
        let prefix = "go-keyring-base64:"
        if body.hasPrefix(prefix) {
            guard let data = Data(base64Encoded: String(body.dropFirst(prefix.count))) else { return nil }
            body = String(decoding: data, as: UTF8.self)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let email = obj["id_token_email"] as? String, email.contains("@") else { return nil }
        return email
    }
}

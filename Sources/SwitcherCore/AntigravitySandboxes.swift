import Darwin
import Foundation

/// How much of the user's real `$HOME` is symlinked into an Antigravity sandbox's isolated `home/`.
/// `.gemini` and `Library/Application Support` are NEVER symlinked so credentials and sessions stay isolated.
public enum SandboxLinkPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Links shell/git convenience files and standard project folders, but keeps `.ssh`, `.config`,
    /// `.npmrc`, and `.yarnrc` out of reach of sandboxed agents.
    case minimal
    /// Links everything in `.minimal` plus `.ssh`, `.config`, `.npmrc`, and `.yarnrc`.
    case full
    /// Links nothing from `$HOME` (macOS `Library/Keychains` bridge only).
    case none

    public var id: String { rawValue }

    public static let minimalItems: [String] = [
        ".zshrc", ".zshenv", ".zprofile",
        ".bashrc", ".bash_profile", ".profile",
        ".gitconfig", ".gitignore_global",
        "Desktop", "Documents", "Downloads", "Projects", "Developer",
    ]

    public static let fullOnlyItems: [String] = [
        ".ssh", ".config", ".npmrc", ".yarnrc",
    ]

    public var items: [String] {
        switch self {
        case .minimal: Self.minimalItems
        case .full: Self.minimalItems + Self.fullOnlyItems
        case .none: []
        }
    }
}

/// On-disk metadata persisted in `<sandbox>/sandbox.json` (mode 0600).
public struct AntigravitySandboxMeta: Codable, Equatable, Sendable {
    public var name: String
    public var alias: String?
    public var linkPolicy: SandboxLinkPolicy
    public var createdAt: Date
    public var lastAppVersion: String?
    public var defaultWorkspace: String?

    public init(name: String, alias: String? = nil, linkPolicy: SandboxLinkPolicy = .minimal,
                createdAt: Date = Date(), lastAppVersion: String? = nil, defaultWorkspace: String? = nil) {
        self.name = name
        self.alias = alias
        self.linkPolicy = linkPolicy
        self.createdAt = createdAt
        self.lastAppVersion = lastAppVersion
        self.defaultWorkspace = defaultWorkspace
    }
}

/// One parallel Antigravity sandbox (supports running an independent Antigravity App window
/// AND concurrent `agy` CLI sessions on its own Google account).
public struct AntigravitySandbox: Equatable, Identifiable, Sendable {
    public var name: String
    public var alias: String?
    public var linkPolicy: SandboxLinkPolicy
    public var path: URL
    public var homePath: URL
    public var dataPath: URL
    public var email: String?
    public var signedIn: Bool
    public var running: Bool
    public var pid: pid_t?
    public var quota: AntigravityQuota?
    public var defaultWorkspace: String?
    public var createdAt: Date?

    public var id: String { name }

    public var label: String {
        if let alias, !alias.isEmpty { return alias }
        return name
    }

    public var secondaryLabel: String? {
        if let alias, !alias.isEmpty {
            return email ?? name
        }
        return email
    }

    public init(name: String, alias: String? = nil, linkPolicy: SandboxLinkPolicy = .minimal,
                path: URL, homePath: URL, dataPath: URL, email: String? = nil,
                signedIn: Bool = false, running: Bool = false, pid: pid_t? = nil,
                quota: AntigravityQuota? = nil, defaultWorkspace: String? = nil, createdAt: Date? = nil) {
        self.name = name
        self.alias = alias
        self.linkPolicy = linkPolicy
        self.path = path
        self.homePath = homePath
        self.dataPath = dataPath
        self.email = email
        self.signedIn = signedIn
        self.running = running
        self.pid = pid
        self.quota = quota
        self.defaultWorkspace = defaultWorkspace
        self.createdAt = createdAt
    }
}

/// Live process snapshot for one sandbox's desktop Antigravity window.
public struct SandboxProcessSnapshot: Equatable, Sendable {
    public var main: pid_t?
    public var all: [pid_t]

    public var isRunning: Bool { main != nil || !all.isEmpty }

    public init(main: pid_t? = nil, all: [pid_t] = []) {
        self.main = main
        self.all = all
    }
}

/// Summary returned by `AntigravitySandboxes.heal(_:force:)`.
public struct SandboxHealReport: Equatable, Sendable {
    public var locksCleaned: [String]
    public var cachesPurged: [String]
    public var versionChanged: Bool
    public var oldVersion: String?
    public var newVersion: String?
    public var updaterSuppressed: Bool
    public var markersRefreshed: Bool

    public init(locksCleaned: [String] = [], cachesPurged: [String] = [], versionChanged: Bool = false,
                oldVersion: String? = nil, newVersion: String? = nil, updaterSuppressed: Bool = false,
                markersRefreshed: Bool = false) {
        self.locksCleaned = locksCleaned
        self.cachesPurged = cachesPurged
        self.versionChanged = versionChanged
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.updaterSuppressed = updaterSuppressed
        self.markersRefreshed = markersRefreshed
    }
}

/// Process operations for parallel Antigravity sandboxes (mocked in tests so tests never touch live processes).
public protocol SandboxProcessControl: Sendable {
    func runningProcesses(for sandboxName: String, dataDir: URL) -> SandboxProcessSnapshot
    func launchApp(binary: URL, arguments: [String], environment: [String: String], logFile: URL) throws -> pid_t
    func stop(processes: SandboxProcessSnapshot, force: Bool) throws
    func antigravityBinary() -> URL?
    func antigravityVersion(binary: URL?) -> String?
    func agyBinary(home: String, path: String?) -> String?
}

public final class LiveSandboxProcessControl: SandboxProcessControl, @unchecked Sendable {
    public static let shared = LiveSandboxProcessControl()

    public init() {}

    public func runningProcesses(for sandboxName: String, dataDir: URL) -> SandboxProcessSnapshot {
        guard let list = Proc.list() else { return SandboxProcessSnapshot() }
        var markers: Set<String> = ["--user-data-dir=\(dataDir.path)"]
        if let real = realPath(dataDir.path) {
            markers.insert("--user-data-dir=\(real)")
        }

        var mainPID: pid_t?
        var allPIDs: [pid_t] = []

        for proc in list.resolved {
            guard let info = Proc.argsAndEnv(pid: proc.pid) else { continue }
            // Never conflate interactive `agy` CLI terminals with the desktop App window.
            if info.env[Proc.sandboxRoleEnvKey] == "cli" { continue }

            let matchesEnv = info.env[Proc.sandboxEnvKey] == sandboxName
            let matchesArg = info.argv.contains { markers.contains($0) }
            guard matchesEnv || matchesArg else { continue }

            allPIDs.append(proc.pid)
            if mainPID == nil,
               proc.path.contains("/Contents/MacOS/"),
               !info.argv.contains(where: { $0.hasPrefix("--type=") }) {
                mainPID = proc.pid
            }
        }
        if mainPID == nil {
            mainPID = allPIDs.first
        }
        return SandboxProcessSnapshot(main: mainPID, all: allPIDs)
    }

    public func launchApp(binary: URL, arguments: [String], environment: [String: String], logFile: URL) throws -> pid_t {
        try FS.makePrivateDir(logFile.deletingLastPathComponent())
        let fd = open(logFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError.current("creating \(logFile.path)") }
        let logHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = arguments
        proc.environment = environment
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        try proc.run()
        try? logHandle.close()
        return proc.processIdentifier
    }

    public func stop(processes: SandboxProcessSnapshot, force: Bool) throws {
        guard processes.isRunning else { return }
        if force {
            for pid in processes.all where pid > 0 { kill(pid, SIGKILL) }
            waitGone(processes.all, timeout: 1.0)
            return
        }
        // 1. Ask Electron's main process to quit cleanly so workspace state flushes.
        if let main = processes.main, main > 0 {
            kill(main, SIGTERM)
            waitGone([main], timeout: 5.0)
        }
        // 2. Ask any lingering helpers/sidecars (e.g. language_server) to exit.
        let remaining = processes.all.filter { $0 > 0 && !Proc.isGone($0) }
        if !remaining.isEmpty {
            for pid in remaining { kill(pid, SIGTERM) }
            waitGone(remaining, timeout: 3.0)
        }
        // 3. Escalate stubborn sidecars.
        let stubborn = processes.all.filter { $0 > 0 && !Proc.isGone($0) }
        if !stubborn.isEmpty {
            for pid in stubborn { kill(pid, SIGKILL) }
            waitGone(stubborn, timeout: 1.0)
        }
    }

    public func antigravityBinary() -> URL? {
        if let custom = ProcessInfo.processInfo.environment["ANTIGRAVITY_BIN"], !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        if let url = MacApp.antigravity.executableURL, FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        let fallbacks = [
            "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
            NSHomeDirectory() + "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
        ]
        for path in fallbacks where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func antigravityVersion(binary: URL?) -> String? {
        if let binary {
            let plist = binary.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
            if let data = try? Data(contentsOf: plist),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                if let short = dict["CFBundleShortVersionString"] as? String, !short.isEmpty { return short }
                if let ver = dict["CFBundleVersion"] as? String, !ver.isEmpty { return ver }
            }
        }
        return MacApp.antigravity.bundleVersion
    }

    public func agyBinary(home: String, path: String? = nil) -> String? {
        let env = CLIEnv(home: home)
        if let custom = ProcessInfo.processInfo.environment["AGY_BIN"], !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        let effectivePath = path ?? (ProcessInfo.processInfo.environment["PATH"] ?? "")
        var candidates: [String] = [
            env.home + "/.local/libexec/agy",
            env.home + "/.local/bin/agy",
        ]
        candidates += effectivePath.split(separator: ":").map { CLIPath.trimmed(String($0)) + "/agy" }
        candidates += CLIShim.homeBinDirs(env: env).map { $0 + "/agy" }
        if path == nil {
            candidates += ["/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        }
        return candidates.first { c in
            !c.hasPrefix(env.shimDir + "/") && FileManager.default.isExecutableFile(atPath: c)
        }
    }

    private func waitGone(_ pids: [pid_t], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ Proc.isGone($0) }) { return }
            usleep(50_000)
        }
    }

    private func realPath(_ path: String) -> String? {
        guard let c = realpath(path, nil) else { return nil }
        defer { free(c) }
        return String(cString: c)
    }
}

/// Stand-in process controller for hermetic unit tests.
public final class FakeSandboxProcessControl: SandboxProcessControl, @unchecked Sendable {
    public struct LaunchRecord: Equatable, Sendable {
        public var binary: URL
        public var arguments: [String]
        public var environment: [String: String]
        public var logFile: URL
    }

    private let lock = NSLock()
    public var installedBinary: URL?
    public var installedVersion: String?
    public var installedAgyBinary: String?
    public var runningByName: [String: SandboxProcessSnapshot] = [:]
    public private(set) var launches: [LaunchRecord] = []
    public private(set) var stops: [(snapshot: SandboxProcessSnapshot, force: Bool)] = []
    public var nextPID: pid_t = 40_000

    public init(binary: URL? = URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/MacOS/Antigravity"),
                version: String? = "2.31.0",
                agyBinary: String? = "/usr/local/bin/agy") {
        self.installedBinary = binary
        self.installedVersion = version
        self.installedAgyBinary = agyBinary
    }

    public func runningProcesses(for sandboxName: String, dataDir: URL) -> SandboxProcessSnapshot {
        lock.withLock { runningByName[sandboxName] ?? SandboxProcessSnapshot() }
    }

    public func launchApp(binary: URL, arguments: [String], environment: [String: String], logFile: URL) throws -> pid_t {
        try FS.makePrivateDir(logFile.deletingLastPathComponent())
        try FS.atomicWrite(Data("fake launch\n".utf8), to: logFile)
        return lock.withLock {
            let pid = nextPID
            nextPID += 1
            launches.append(LaunchRecord(binary: binary, arguments: arguments, environment: environment, logFile: logFile))
            if let name = environment[Proc.sandboxEnvKey] {
                runningByName[name] = SandboxProcessSnapshot(main: pid, all: [pid])
            }
            return pid
        }
    }

    public func stop(processes: SandboxProcessSnapshot, force: Bool) throws {
        lock.withLock {
            stops.append((processes, force))
            let keys = runningByName.filter { $0.value == processes }.map(\.key)
            for name in keys {
                runningByName.removeValue(forKey: name)
            }
        }
    }

    public func antigravityBinary() -> URL? { lock.withLock { installedBinary } }
    public func antigravityVersion(binary: URL?) -> String? { lock.withLock { installedVersion } }
    public func agyBinary(home: String, path: String?) -> String? { lock.withLock { installedAgyBinary } }
}

/// Manages isolated Antigravity parallel sandboxes under `env.antigravitySandboxes` (`~/.antigravity-sandboxes/`).
///
/// Each sandbox has its own `home/` (`HOME`) and `data/` (`--user-data-dir`), and uses file-backed
/// OAuth storage (`SSH_CONNECTION` + `WSL_INTEROP=1` + `antigravity-keyring-unavailable` markers) so
/// multiple Antigravity desktop windows and `agy` CLI terminals can run side-by-side on separate accounts
/// without contending for the single macOS Login Keychain slot (`gemini`/`antigravity`).
public final class AntigravitySandboxes: @unchecked Sendable {
    public let env: Env
    public let processControl: SandboxProcessControl

    /// Far-future mtime (2036-01-01 UTC) written to `antigravity-keyring-unavailable` sentinel files
    /// so `agy` and Antigravity's `CompositeTokenStorage` stay on file-backed tokens inside the sandbox.
    static let markerFutureDate = Date(timeIntervalSince1970: 2_082_758_400)

    /// Ephemeral Chromium/Electron caches safe to purge when host Antigravity upgrades.
    static let ephemeralCacheDirs = [
        "Cache", "Code Cache", "GPUCache", "DawnCache",
        "DawnWebGPUCache", "DawnGraphiteCache", "CachedData",
    ]

    /// Stale lock files removed during auto-heal when no sandbox process is alive.
    static let staleLockNames = [
        "SingletonLock", "SingletonSocket", "SingletonCookie", "DevToolsActivePort",
    ]

    /// Token file candidates inside `<sandbox>/home/.gemini/` (checked newest-first).
    static let tokenRelativePaths = [
        ".gemini/jetski-standalone-oauth-token",
        ".gemini/antigravity-cli/antigravity-oauth-token",
        ".gemini/antigravity/antigravity-oauth-token",
        ".gemini/oauth_creds.json",
    ]

    /// Keyring-unavailable cache markers for Desktop App, `agy` CLI, and Antigravity IDE.
    static let keyringMarkerRelativePaths = [
        ".gemini/cache/antigravity-keyring-unavailable",
        ".gemini/antigravity-cli/cache/antigravity-keyring-unavailable",
        ".gemini/antigravity/cache/antigravity-keyring-unavailable",
    ]

    static let sshConnectionValue = "127.0.0.1 50000 127.0.0.1 22"
    static let sshClientValue = "127.0.0.1 50000 22"
    static let maxKeptLogs = 5

    public init(env: Env = .live, processControl: SandboxProcessControl = LiveSandboxProcessControl.shared) {
        self.env = env
        self.processControl = processControl
    }

    public var root: URL { env.antigravitySandboxes }

    public static func quotaCacheKey(for name: String) -> String { "sandbox:\(name)" }

    // MARK: Validation & paths

    public static func isValidName(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower != "default", lower != "main" else { return false }
        return CLIPath.isValidName(name)
    }

    public static func validateName(_ name: String) throws {
        guard isValidName(name) else {
            throw SwitcherError.message(L10n.t(
                "Invalid sandbox name \"\(name)\". Use 1–64 letters, digits, '.', '_', or '-' (starting with a letter or digit, not \"default\" or \"main\").",
                "无效的分身名称“\(name)”。请使用 1–64 个字母、数字、.、_ 或 -（以字母或数字开头，且不能叫 default 或 main）。"))
        }
    }

    public func sandboxDir(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    public func homeDir(_ name: String) -> URL {
        sandboxDir(name).appendingPathComponent("home", isDirectory: true)
    }

    public func dataDir(_ name: String) -> URL {
        sandboxDir(name).appendingPathComponent("data", isDirectory: true)
    }

    public func logsDir(_ name: String) -> URL {
        sandboxDir(name).appendingPathComponent("logs", isDirectory: true)
    }

    public func metaURL(_ name: String) -> URL {
        sandboxDir(name).appendingPathComponent("sandbox.json")
    }

    public func pidURL(_ name: String) -> URL {
        sandboxDir(name).appendingPathComponent("run.pid")
    }

    /// Suggests the next free short name (`acc2`, `acc3`, …).
    public func suggestedName() -> String {
        let taken = Set(existingNames().map { $0.lowercased() })
        var n = 2
        while taken.contains("acc\(n)") { n += 1 }
        return "acc\(n)"
    }

    private func existingNames() -> [String] {
        guard FS.isDirectory(root) else { return [] }
        return FS.children(root)
            .filter { FS.isDirectory($0) && Self.isValidName($0.lastPathComponent) }
            .map(\.lastPathComponent)
    }

    // MARK: Inspection

    public func list(quotas: [String: AntigravityQuota] = [:]) -> [AntigravitySandbox] {
        existingNames().compactMap { inspect($0, quotas: quotas) }
            .sorted { a, b in
                let ta = a.createdAt ?? .distantFuture
                let tb = b.createdAt ?? .distantFuture
                if ta != tb { return ta < tb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    public func sandbox(named name: String, quotas: [String: AntigravityQuota] = [:]) -> AntigravitySandbox? {
        guard Self.isValidName(name), FS.isDirectory(sandboxDir(name)) else { return nil }
        return inspect(name, quotas: quotas)
    }

    /// Resolves a sandbox by 1-based list number, exact name, alias, or signed-in email.
    public func resolve(_ query: String, quotas: [String: AntigravityQuota] = [:]) -> AntigravitySandbox? {
        let all = list(quotas: quotas)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let n = Int(q), n >= 1, n <= all.count { return all[n - 1] }
        let lower = q.lowercased()
        if let exact = all.first(where: { $0.name.lowercased() == lower }) { return exact }
        if let byAlias = all.first(where: { $0.alias?.lowercased() == lower }) { return byAlias }
        if let byEmail = all.first(where: { $0.email?.lowercased() == lower }) { return byEmail }
        return nil
    }

    private func inspect(_ name: String, quotas: [String: AntigravityQuota]) -> AntigravitySandbox {
        let dir = sandboxDir(name)
        let home = homeDir(name)
        let data = dataDir(name)
        let meta = loadMeta(name)
        let token = tokenPayload(for: name)
        let email = identityEmail(for: name, tokenPayload: token)
        let procs = processControl.runningProcesses(for: name, dataDir: data)
        let quota = quotas[Self.quotaCacheKey(for: name)]
        return AntigravitySandbox(
            name: name,
            alias: meta?.alias,
            linkPolicy: meta?.linkPolicy ?? .minimal,
            path: dir,
            homePath: home,
            dataPath: data,
            email: email,
            signedIn: token != nil,
            running: procs.isRunning,
            pid: procs.main,
            quota: quota,
            defaultWorkspace: meta?.defaultWorkspace,
            createdAt: meta?.createdAt ?? FS.mtime(dir)
        )
    }

    /// Reads the newest non-empty OAuth token JSON stored inside the sandbox's `.gemini/`.
    public func tokenPayload(for name: String) -> String? {
        let home = homeDir(name)
        var candidates: [(url: URL, mtime: Date)] = []
        for rel in Self.tokenRelativePaths {
            let url = home.appendingPathComponent(rel)
            guard FS.isFile(url) else { continue }
            candidates.append((url, FS.mtime(url) ?? .distantPast))
        }
        candidates.sort { $0.mtime > $1.mtime }
        for candidate in candidates {
            guard let raw = try? String(contentsOf: candidate.url, encoding: .utf8) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, AntigravityUsage.Credential(keyring: trimmed) != nil {
                return trimmed
            }
        }
        return nil
    }

    /// All signed-in sandboxes with their quota cache key and token payload, for `Switchboard.refreshAntigravityUsage`.
    public func allTokenPayloads() -> [(key: String, name: String, payload: String)] {
        existingNames().compactMap { name in
            guard let payload = tokenPayload(for: name) else { return nil }
            return (Self.quotaCacheKey(for: name), name, payload)
        }
    }

    /// Determines the Google email bound to a sandbox (token payload -> `google_accounts.json` -> `app_storage.json`).
    public func identityEmail(for name: String, tokenPayload cachedToken: String? = nil) -> String? {
        let home = homeDir(name)
        let token = cachedToken ?? tokenPayload(for: name)
        if let token, let email = AntigravityUsage.extractEmail(fromTokenPayload: token) {
            return email
        }
        // Check all token files in case one has id_token_email even if another was newer.
        for rel in Self.tokenRelativePaths {
            let url = home.appendingPathComponent(rel)
            if let raw = try? String(contentsOf: url, encoding: .utf8),
               let email = AntigravityUsage.extractEmail(fromTokenPayload: raw) {
                return email
            }
        }
        let googleAccounts = home.appendingPathComponent(".gemini/google_accounts.json")
        if let obj = try? FS.readJSONObject(googleAccounts),
           let active = obj["active"] as? String, active.contains("@") {
            return active
        }
        if token != nil {
            let storage = dataDir(name).appendingPathComponent("app_storage.json")
            if let doc = try? OrderedJSON(contentsOf: storage),
               let email = AntigravityFiles.lastLogin.lazy.compactMap({ doc.string($0) }).first(where: { $0.contains("@") }) {
                return email
            }
        }
        return nil
    }

    // MARK: Create & edit

    @discardableResult
    public func create(name: String, alias: String? = nil, linkPolicy: SandboxLinkPolicy = .minimal,
                       inheritHostConfig: Bool = true, defaultWorkspace: String? = nil) throws -> AntigravitySandbox {
        try Self.validateName(name)
        let dir = sandboxDir(name)
        if FS.exists(dir) {
            throw SwitcherError.message(L10n.t(
                "Sandbox \"\(name)\" already exists.",
                "分身“\(name)”已存在。"))
        }

        try FS.makePrivateDir(root)
        excludeFromBackup(root)
        try FS.makePrivateDir(dir)
        try FS.makePrivateDir(homeDir(name))
        try FS.makePrivateDir(dataDir(name))
        try FS.makePrivateDir(logsDir(name))
        try FS.makePrivateDir(homeDir(name).appendingPathComponent(".gemini", isDirectory: true))

        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = AntigravitySandboxMeta(
            name: name,
            alias: (trimmedAlias?.isEmpty == false) ? trimmedAlias : nil,
            linkPolicy: linkPolicy,
            createdAt: Date(),
            lastAppVersion: processControl.antigravityVersion(binary: processControl.antigravityBinary()),
            defaultWorkspace: defaultWorkspace
        )
        try saveMeta(meta)

        try applyLinkPolicy(linkPolicy, to: name)
        try writeKeyringBypassMarkers(for: name)
        if inheritHostConfig {
            inheritNonCredentialHostConfig(into: name)
        }
        _ = suppressSandboxAutoUpdate(for: name)
        hardenPermissions(for: name)

        return inspect(name, quotas: [:])
    }

    public func setAlias(_ name: String, _ alias: String?) throws {
        try ensureExists(name)
        var meta = loadMeta(name) ?? AntigravitySandboxMeta(name: name)
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.alias = (trimmed?.isEmpty == false) ? trimmed : nil
        try saveMeta(meta)
    }

    public func setLinkPolicy(_ name: String, _ policy: SandboxLinkPolicy) throws {
        try ensureExists(name)
        var meta = loadMeta(name) ?? AntigravitySandboxMeta(name: name)
        meta.linkPolicy = policy
        try saveMeta(meta)
        try applyLinkPolicy(policy, to: name)
    }

    public func setDefaultWorkspace(_ name: String, _ workspace: String?) throws {
        try ensureExists(name)
        var meta = loadMeta(name) ?? AntigravitySandboxMeta(name: name)
        let trimmed = workspace?.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.defaultWorkspace = (trimmed?.isEmpty == false) ? trimmed : nil
        try saveMeta(meta)
    }

    // MARK: Lifecycle (heal, launch, stop, remove)

    /// Cleans stale locks, purges ephemeral caches if host Antigravity updated (or `force`),
    /// suppresses sandbox auto-updates, and refreshes keyring-bypass markers.
    @discardableResult
    public func heal(_ name: String, force: Bool = false) throws -> SandboxHealReport {
        try ensureExists(name)
        let data = dataDir(name)
        let procs = processControl.runningProcesses(for: name, dataDir: data)
        var report = SandboxHealReport()

        if !procs.isRunning {
            for lockName in Self.staleLockNames {
                let target = data.appendingPathComponent(lockName)
                if FS.exists(target) {
                    FS.removeIfExists(target)
                    report.locksCleaned.append(lockName)
                }
            }
            if FS.exists(pidURL(name)) {
                FS.removeIfExists(pidURL(name))
                report.locksCleaned.append("run.pid")
            }
        }

        var meta = loadMeta(name) ?? AntigravitySandboxMeta(name: name)
        let oldVer = meta.lastAppVersion
        let newVer = processControl.antigravityVersion(binary: processControl.antigravityBinary())
        let versionChanged = newVer != nil && oldVer != newVer
        report.oldVersion = oldVer
        report.newVersion = newVer
        report.versionChanged = versionChanged

        if (versionChanged || force), !procs.isRunning, FS.isDirectory(data) {
            for cacheName in Self.ephemeralCacheDirs {
                let cdir = data.appendingPathComponent(cacheName)
                if FS.exists(cdir) {
                    FS.removeIfExists(cdir)
                    report.cachesPurged.append(cacheName)
                }
            }
            if let newVer {
                meta.lastAppVersion = newVer
                try? saveMeta(meta)
            }
        }

        try applyLinkPolicy(meta.linkPolicy, to: name)
        try writeKeyringBypassMarkers(for: name)
        report.markersRefreshed = true
        report.updaterSuppressed = suppressSandboxAutoUpdate(for: name)
        hardenPermissions(for: name)
        return report
    }

    /// Launches an isolated Antigravity desktop App window for `name`.
    /// If already running, returns its existing PID without spawning a duplicate.
    @discardableResult
    public func launch(_ name: String, workspace: String? = nil, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws -> pid_t {
        try ensureExists(name)
        let data = dataDir(name)
        let procs = processControl.runningProcesses(for: name, dataDir: data)
        if let existing = procs.main, procs.isRunning {
            return existing
        }

        guard let binary = processControl.antigravityBinary() else {
            throw SwitcherError.message(L10n.t(
                "Antigravity.app is not installed.",
                "未安装 Antigravity.app。"))
        }

        let meta = loadMeta(name) ?? AntigravitySandboxMeta(name: name)
        let targetWorkspace = workspace ?? meta.defaultWorkspace
        if let targetWorkspace, !targetWorkspace.isEmpty {
            guard FileManager.default.fileExists(atPath: targetWorkspace) else {
                throw SwitcherError.message(L10n.t(
                    "Workspace folder does not exist: \(targetWorkspace)",
                    "项目目录不存在：\(targetWorkspace)"))
            }
        }

        _ = try heal(name, force: false)

        let environment = appEnvironment(for: name, base: baseEnvironment)
        var arguments = ["--user-data-dir=\(data.path)"]
        if let targetWorkspace, !targetWorkspace.isEmpty {
            arguments.append(targetWorkspace)
        }

        let logFile = nextLogURL(for: name)
        let pid = try processControl.launchApp(binary: binary, arguments: arguments, environment: environment, logFile: logFile)
        try? FS.atomicWrite(Data("\(pid)\n".utf8), to: pidURL(name))
        pruneLogs(for: name)
        return pid
    }

    /// Stops only this sandbox's Antigravity desktop processes (never touches the main app or `agy` CLI terminals).
    @discardableResult
    public func stop(_ name: String, force: Bool = false) throws -> Bool {
        try ensureExists(name)
        let procs = processControl.runningProcesses(for: name, dataDir: dataDir(name))
        guard procs.isRunning else {
            FS.removeIfExists(pidURL(name))
            return false
        }
        try processControl.stop(processes: procs, force: force)
        FS.removeIfExists(pidURL(name))
        return true
    }

    /// Stops the sandbox if running, then moves its folder to the Trash (or removes it if Trash is unavailable).
    public func remove(_ name: String) throws {
        try ensureExists(name)
        _ = try stop(name, force: false)
        let dir = sandboxDir(name)
        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: Environment & `agy` CLI concurrency

    /// Environment passed to an isolated Antigravity desktop App launch.
    public func appEnvironment(for name: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var out = base
        out["HOME"] = homeDir(name).path
        out["SSH_CONNECTION"] = Self.sshConnectionValue
        out["SSH_CLIENT"] = Self.sshClientValue
        out["WSL_INTEROP"] = "1"
        out[Proc.sandboxEnvKey] = name
        out[Proc.sandboxRoleEnvKey] = "app"
        return out
    }

    /// Prepares the sandbox (markers + links) and returns the isolated environment for running `agy` CLI concurrently.
    public func agyEnvironment(for name: String, base: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        try ensureExists(name)
        let meta = loadMeta(name) ?? AntigravitySandboxMeta(name: name)
        try applyLinkPolicy(meta.linkPolicy, to: name)
        try writeKeyringBypassMarkers(for: name)
        hardenPermissions(for: name)

        var out = base
        out["HOME"] = homeDir(name).path
        out["WSL_INTEROP"] = "1"
        out["SSH_CONNECTION"] = Self.sshConnectionValue
        out["SSH_CLIENT"] = Self.sshClientValue
        out["AGY_SWAP_SKIP_SYNC"] = "1"
        out[Proc.sandboxEnvKey] = name
        out[Proc.sandboxRoleEnvKey] = "cli"
        return out
    }

    /// Self-contained shell command a user can paste into any terminal to run `agy` inside this sandbox.
    public func standaloneAgyCommand(for name: String) -> String {
        let home = shellQuote(homeDir(name).path)
        let sshConn = shellQuote(Self.sshConnectionValue)
        let sshClient = shellQuote(Self.sshClientValue)
        let sb = shellQuote(name)
        return "HOME=\(home) WSL_INTEROP=1 SSH_CONNECTION=\(sshConn) SSH_CLIENT=\(sshClient) \(Proc.sandboxEnvKey)=\(sb) \(Proc.sandboxRoleEnvKey)=cli agy"
    }

    /// Most recent launch log file for `name`, if any.
    public func latestLogURL(for name: String) -> URL? {
        let dir = logsDir(name)
        guard FS.isDirectory(dir) else { return nil }
        return FS.children(dir)
            .filter { $0.pathExtension == "log" }
            .max { (FS.mtime($0) ?? .distantPast) < (FS.mtime($1) ?? .distantPast) }
    }

    // MARK: Internals

    private func ensureExists(_ name: String) throws {
        try Self.validateName(name)
        guard FS.isDirectory(sandboxDir(name)) else {
            throw SwitcherError.message(L10n.t(
                "No Antigravity sandbox named \"\(name)\". Create one with `switcher sandbox add \(name)`.",
                "没有名为“\(name)”的 Antigravity 分身。可以用 `switcher sandbox add \(name)` 创建。"))
        }
    }

    private func loadMeta(_ name: String) -> AntigravitySandboxMeta? {
        guard let data = try? Data(contentsOf: metaURL(name)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AntigravitySandboxMeta.self, from: data)
    }

    private func saveMeta(_ meta: AntigravitySandboxMeta) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try FS.atomicWrite(try enc.encode(meta), to: metaURL(meta.name))
    }

    private func writeKeyringBypassMarkers(for name: String) throws {
        let home = homeDir(name)
        let fm = FileManager.default
        for rel in Self.keyringMarkerRelativePaths {
            let marker = home.appendingPathComponent(rel)
            try FS.makePrivateDir(marker.deletingLastPathComponent())
            if !FS.isFile(marker) {
                try FS.atomicWrite(Data(), to: marker)
            }
            try? fm.setAttributes([.modificationDate: Self.markerFutureDate], ofItemAtPath: marker.path)
        }
    }

    /// Reconciles symlinks inside `<sandbox>/home/` against `policy`.
    /// Only removes symlinks previously created by a broader policy that point back into `env.home`.
    private func applyLinkPolicy(_ policy: SandboxLinkPolicy, to name: String) throws {
        let fm = FileManager.default
        let home = homeDir(name)
        try FS.makePrivateDir(home)
        try FS.makePrivateDir(home.appendingPathComponent(".gemini", isDirectory: true))

        let allowed = Set(policy.items)
        let allManaged = SandboxLinkPolicy.minimalItems + SandboxLinkPolicy.fullOnlyItems

        for item in allManaged {
            let src = env.home.appendingPathComponent(item)
            let dst = home.appendingPathComponent(item)
            if allowed.contains(item) {
                if FS.exists(src), !FS.exists(dst) {
                    try? fm.createSymbolicLink(atPath: dst.path, withDestinationPath: src.path)
                }
            } else {
                // Only remove symlinks pointing to the real host home (never delete user-created real files).
                if let dest = try? fm.destinationOfSymbolicLink(atPath: dst.path), dest == src.path {
                    try? fm.removeItem(at: dst)
                }
            }
        }

        // macOS Chromium Safe Storage expects ~/Library/Keychains; bridging it prevents Keychain
        // Assistant popups while SSH_CONNECTION + markers keep Antigravity's OAuth token isolated.
        let realKeychains = env.home.appendingPathComponent("Library/Keychains", isDirectory: true)
        if FS.exists(realKeychains) {
            let profLib = home.appendingPathComponent("Library", isDirectory: true)
            try? fm.createDirectory(at: profLib, withIntermediateDirectories: true)
            let profKeychains = profLib.appendingPathComponent("Keychains")
            if !FS.exists(profKeychains) {
                try? fm.createSymbolicLink(atPath: profKeychains.path, withDestinationPath: realKeychains.path)
            }
        }
    }

    /// Strict allowlist host config inheritance: copies editor preferences, keybindings, filtered
    /// `~/.gemini/settings.json`, and links custom skills/`GEMINI.md`. NEVER copies tokens, cookies,
    /// accounts, or conversations.
    private func inheritNonCredentialHostConfig(into name: String) {
        let fm = FileManager.default
        let dstHome = homeDir(name)
        let dstGemini = dstHome.appendingPathComponent(".gemini", isDirectory: true)
        let dstUser = dataDir(name).appendingPathComponent("User", isDirectory: true)

        // 1. ~/.gemini/settings.json (strip any credential-bearing keys)
        let srcGeminiSettings = env.gemini.appendingPathComponent("settings.json")
        let dstGeminiSettings = dstGemini.appendingPathComponent("settings.json")
        if FS.isFile(srcGeminiSettings), !FS.exists(dstGeminiSettings),
           let raw = try? FS.readJSONObject(srcGeminiSettings) {
            let filtered = Self.stripSensitiveKeys(raw)
            if let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.prettyPrinted, .sortedKeys]) {
                try? FS.atomicWrite(data, to: dstGeminiSettings)
            }
        }

        // 2. Link ~/.gemini/GEMINI.md and ~/.gemini/antigravity/skills (shared rules & skills)
        let srcGeminiMD = env.gemini.appendingPathComponent("GEMINI.md")
        let dstGeminiMD = dstGemini.appendingPathComponent("GEMINI.md")
        if FS.isFile(srcGeminiMD), !FS.exists(dstGeminiMD) {
            try? fm.createSymbolicLink(atPath: dstGeminiMD.path, withDestinationPath: srcGeminiMD.path)
        }
        let srcSkills = env.gemini.appendingPathComponent("antigravity/skills", isDirectory: true)
        if FS.isDirectory(srcSkills) {
            let dstAgyDir = dstGemini.appendingPathComponent("antigravity", isDirectory: true)
            try? FS.makePrivateDir(dstAgyDir)
            let dstSkills = dstAgyDir.appendingPathComponent("skills")
            if !FS.exists(dstSkills) {
                try? fm.createSymbolicLink(atPath: dstSkills.path, withDestinationPath: srcSkills.path)
            }
        }

        // 3. Antigravity User/settings.json & User/keybindings.json (non-credential editor prefs)
        let srcUser = env.antigravityData.appendingPathComponent("User", isDirectory: true)
        for file in ["settings.json", "keybindings.json"] {
            let src = srcUser.appendingPathComponent(file)
            let dst = dstUser.appendingPathComponent(file)
            if FS.isFile(src), !FS.exists(dst), let data = try? Data(contentsOf: src) {
                try? FS.makePrivateDir(dstUser)
                try? FS.atomicWrite(data, to: dst)
            }
        }
    }

    static func stripSensitiveKeys(_ obj: [String: Any]) -> [String: Any] {
        let exactBlocked: Set<String> = [
            "jetski-standalone-oauth-token", "google_accounts", "google_account_id",
            "lastLoginUsername", "oauth_creds", "credentials", "token",
            "refreshToken", "accessToken", "id_token", "id_token_email",
        ]
        let blockedSubstrings = ["oauth", "token", "secret", "credential", "cookie", "password"]
        var out: [String: Any] = [:]
        for (k, v) in obj {
            let lower = k.lowercased()
            if exactBlocked.contains(k) || blockedSubstrings.contains(where: { lower.contains($0) }) {
                continue
            }
            if let nested = v as? [String: Any] {
                out[k] = stripSensitiveKeys(nested)
            } else {
                out[k] = v
            }
        }
        return out
    }

    /// Disables auto-updates inside a sandbox so parallel instances never race host upgrades.
    @discardableResult
    private func suppressSandboxAutoUpdate(for name: String) -> Bool {
        var modified = false
        let data = dataDir(name)

        // 1. data/app_storage.json -> autoCheckForUpdates = "false"
        let appStorage = data.appendingPathComponent("app_storage.json")
        var storageObj = (try? FS.readJSONObject(appStorage)) ?? [:]
        if (storageObj["autoCheckForUpdates"] as? String) != "false" {
            storageObj["autoCheckForUpdates"] = "false"
            if let encoded = try? JSONSerialization.data(withJSONObject: storageObj, options: [.prettyPrinted, .sortedKeys]) {
                try? FS.atomicWrite(encoded, to: appStorage)
                modified = true
            }
        }

        // 2. data/User/settings.json -> update.mode = "none"
        let userSettings = data.appendingPathComponent("User/settings.json")
        var settingsObj = (try? FS.readJSONObject(userSettings)) ?? [:]
        if (settingsObj["update.mode"] as? String) != "none" {
            settingsObj["update.mode"] = "none"
            if let encoded = try? JSONSerialization.data(withJSONObject: settingsObj, options: [.prettyPrinted, .sortedKeys]) {
                try? FS.makePrivateDir(userSettings.deletingLastPathComponent())
                try? FS.atomicWrite(encoded, to: userSettings)
                modified = true
            }
        }
        return modified
    }

    private func hardenPermissions(for name: String) {
        let dirs = [
            root,
            sandboxDir(name),
            homeDir(name),
            homeDir(name).appendingPathComponent(".gemini", isDirectory: true),
            dataDir(name),
            logsDir(name),
        ]
        for dir in dirs where FS.isDirectory(dir) {
            _ = chmod(dir.path, 0o700)
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    private func nextLogURL(for name: String) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return logsDir(name).appendingPathComponent("launch-\(stamp)-\(suffix).log")
    }

    private func pruneLogs(for name: String) {
        let dir = logsDir(name)
        let logs = FS.children(dir)
            .filter { $0.pathExtension == "log" }
            .sorted { (FS.mtime($0) ?? .distantPast) > (FS.mtime($1) ?? .distantPast) }
        for old in logs.dropFirst(Self.maxKeptLogs) {
            FS.removeIfExists(old)
        }
    }
}

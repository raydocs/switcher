import Foundation

// Adding and removing CLI accounts: the folder name Switcher picks, who an account is, and the
// CLI's own sign-in run without a terminal.

extension CLIKind {
    /// The CLI's own sign-out, run inside the profile's folder before it is removed, so the
    /// sign-in it holds (Claude's keychain item) does not outlive the folder.
    public var logoutArguments: [String] {
        switch self {
        case .claude: ["auth", "logout"]
        case .codex: ["logout"]
        case .agy: []
        }
    }
}

extension CLIProfiles {
    /// The folder name for a new account when none is given: `account2`, `account3`, … (the
    /// default account is number 1). The folder never changes after sign-in (Claude's keychain
    /// item is named after its path), so rows show the email and this name only as a tag.
    public func suggestedName(_ kind: CLIKind, keychain: CLIKeychain? = nil, reserved: Set<String> = []) -> String {
        let taken = Set(list(kind).map { $0.name.lowercased() }).union(reserved.map { $0.lowercased() })
        let root = env.profilesRoot(kind)
        var n = 2
        while true {
            let name = "account\(n)"
            let path = root + "/" + name
            let orphanedKeychain = kind == .claude && keychain?.exists(service: claudeKeychainService(configDir: path)) == true
            if !taken.contains(name), !FS.exists(URL(fileURLWithPath: path)), !orphanedKeychain { return name }
            n += 1
        }
    }

    /// Other accounts of the same kind signed in as the same account (same account and
    /// organization for Claude, same ChatGPT account for Codex, same Google email for agy),
    /// falling back to a credential digest when the credentials carry no account identifier.
    public func duplicates(of profile: CLIProfile, keychain: CLIKeychain? = nil) -> [CLIProfile] {
        if let key = identity(profile, keychain: keychain)?.accountKey {
            return list(profile.kind).filter { $0.path != profile.path && identity($0, keychain: keychain)?.accountKey == key }
        }
        guard let kc = keychain, let fp = credentialFingerprint(profile, keychain: kc) else { return [] }
        return list(profile.kind).filter { $0.path != profile.path && credentialFingerprint($0, keychain: kc) == fp }
    }

    /// Undo `add` after a sign-in that did not finish: only a folder this run made, never the
    /// default one, and only while it holds no sign-in. Removes the folder itself; the shared
    /// items in it are links, removed as links (their targets in the default folder stay).
    public func discardUnsignedIn(_ profile: CLIProfile, keychain: CLIKeychain) throws {
        guard !profile.isDefault else { return }
        guard signIn(profile, keychain: keychain).state == .signedOut else {
            throw SwitcherError.message("\(profile.path) holds a sign-in now; leaving it")
        }
        try removeFolder(profile)
    }

    /// Remove an account: never the default one. When it is the active account, new processes go
    /// back to the default account first. The folder goes to the Trash (its sessions are shared
    /// links, so nothing of the default account goes with it). Sign the CLI out first
    /// (`kind.logoutArguments`) so its keychain item goes too.
    public func remove(_ profile: CLIProfile, toTrash: Bool = true) throws {
        guard !profile.isDefault else { throw SwitcherError.message("the default account stays; sign it out with the CLI itself") }
        guard folderProblem(profile) == nil else {
            throw SwitcherError.message("\(profile.path) is not one of Switcher's account folders")
        }
        if active(profile.kind).path == profile.path { try setActive(defaultProfile(profile.kind)) }
        if toTrash {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: profile.path, isDirectory: true), resultingItemURL: nil)
        } else {
            try removeFolder(profile)
        }
    }

    private func removeFolder(_ profile: CLIProfile) throws {
        guard !profile.isDefault, folderProblem(profile) == nil else {
            throw SwitcherError.message("\(profile.path) is not one of Switcher's account folders")
        }
        // FileManager removes symlinks as links; it never follows them into the default folder.
        try FileManager.default.removeItem(atPath: profile.path)
    }
}

/// The CLI's own sign-in (`claude auth login`, `codex login`, `AGY_CLI_CDE_AUTH_ACTION=login agy`)
/// run in a profile's folder with no terminal: it opens the browser and waits for the callback.
/// Output is kept (last 8 KiB) for an error message; stdin is empty. `cancel()` interrupts it the
/// way Ctrl-C would.
public final class CLILoginRun: @unchecked Sendable {
    public let profile: CLIProfile
    private let isLoginRun: Bool
    private let process = Process()
    private var readFD: Int32 = -1
    private let lock = NSLock()
    private var buffer = Data()
    private var pipe: Pipe?
    private var agyLoginStage: String?
    private var finalized = false
    private var finalizeError: String?

    public var promotionError: String? {
        lock.withLock { finalizeError }
    }

    public init(profile: CLIProfile, binary: String, arguments: [String]? = nil,
                workingDirectory: String? = nil,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.profile = profile
        self.isLoginRun = (arguments == nil)
        let cwd = workingDirectory ?? Self.inferredHome(for: profile)
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments ?? profile.kind.loginArguments
        var env = CLICommands.environment(base: baseEnvironment, profile: profile)
        if env["HOME"] == nil { env["HOME"] = cwd }
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
    }

    static func inferredHome(for profile: CLIProfile) -> String {
        let parent = (profile.path as NSString).deletingLastPathComponent
        return profile.isDefault ? parent : (parent as NSString).deletingLastPathComponent
    }

    /// Stage a temporary `HOME` inside `<profile>/antigravity-cli/.login-home-<uuid>` with
    /// `.gemini/cache/antigravity-keyring-unavailable` so `AGY_CLI_CDE_AUTH_ACTION=login` writes
    /// `<stage>/.gemini/jetski-standalone-oauth-token` instead of touching the login keychain.
    public static func prepareAgyLoginStaging(for profile: CLIProfile) throws -> String {
        guard profile.kind == .agy, !profile.isDefault else {
            throw SwitcherError.message("staging is only for named Antigravity CLI profiles")
        }
        let root = (profile.path as NSString).deletingLastPathComponent
        if let p = CLIPath.problem(profile.path, root: root) { throw SwitcherError.message("\(profile.path): \(p)") }
        guard CLIProfiles.isRealDirectory(root), CLIProfiles.isRealDirectory(profile.path) else {
            throw SwitcherError.message("\(profile.path) is not a real folder")
        }
        let fd = open(profile.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError.current("opening \(profile.path)") }
        defer { close(fd) }
        try CLIProfiles.prepareAgyProfile(dirFD: fd, profilePath: profile.path)

        let cliFD = openat(fd, "antigravity-cli", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard cliFD >= 0 else { throw SwitcherError.message("\(profile.path)/antigravity-cli is not a real folder") }
        defer { close(cliFD) }

        let stageName = ".login-home-\(UUID().uuidString)"
        guard mkdirat(cliFD, stageName, 0o700) == 0 else {
            throw POSIXError.current("creating \(profile.path)/antigravity-cli/\(stageName)")
        }
        let stagePath = profile.path + "/antigravity-cli/" + stageName
        let stageFD = openat(cliFD, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stageFD >= 0 else {
            try? FileManager.default.removeItem(atPath: stagePath)
            throw SwitcherError.message("\(stagePath) is not a real folder")
        }
        defer { close(stageFD) }

        guard mkdirat(stageFD, ".gemini", 0o700) == 0 else {
            try? FileManager.default.removeItem(atPath: stagePath)
            throw POSIXError.current("creating \(stagePath)/.gemini")
        }
        let geminiFD = openat(stageFD, ".gemini", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard geminiFD >= 0 else {
            try? FileManager.default.removeItem(atPath: stagePath)
            throw SwitcherError.message("\(stagePath)/.gemini is not a real folder")
        }
        defer { close(geminiFD) }

        guard mkdirat(geminiFD, "cache", 0o700) == 0 else {
            try? FileManager.default.removeItem(atPath: stagePath)
            throw POSIXError.current("creating \(stagePath)/.gemini/cache")
        }
        let cacheFD = openat(geminiFD, "cache", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard cacheFD >= 0 else {
            try? FileManager.default.removeItem(atPath: stagePath)
            throw SwitcherError.message("\(stagePath)/.gemini/cache is not a real folder")
        }
        defer { close(cacheFD) }

        let markerFD = openat(cacheFD, "antigravity-keyring-unavailable", O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard markerFD >= 0 else {
            try? FileManager.default.removeItem(atPath: stagePath)
            throw SwitcherError.message("\(stagePath)/.gemini/cache/antigravity-keyring-unavailable could not be created")
        }
        var mst = stat()
        let okMarker = fstat(markerFD, &mst) == 0
            && (mst.st_mode & S_IFMT) == S_IFREG
            && ftruncate(markerFD, 0) == 0
            && fchmod(markerFD, 0o600) == 0
        _ = futimens(markerFD, nil)
        close(markerFD)
        guard okMarker else {
            try? FileManager.default.removeItem(atPath: stagePath)
            throw SwitcherError.message("\(stagePath)/.gemini/cache/antigravity-keyring-unavailable could not be secured")
        }
        return stagePath
    }

    /// Move `<loginHome>/.gemini/jetski-standalone-oauth-token` into `<profile>/antigravity-cli/antigravity-oauth-token`
    /// via `renameat` (never copying) and remove `loginHome`. Throws when `succeeded` is true and the
    /// staged token cannot be verified and moved into place.
    public static func finalizeAgyLoginStaging(loginHome: String, for profile: CLIProfile, succeeded: Bool) throws {
        defer { try? FileManager.default.removeItem(atPath: loginHome) }
        guard succeeded, profile.kind == .agy, !profile.isDefault else { return }
        let root = (profile.path as NSString).deletingLastPathComponent
        if let problem = CLIPath.problem(profile.path, root: root) {
            throw SwitcherError.message("\(profile.path): \(problem)")
        }
        guard CLIProfiles.isRealDirectory(root), CLIProfiles.isRealDirectory(profile.path) else {
            throw SwitcherError.message("\(profile.path) is not a real folder")
        }
        let profileFD = open(profile.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard profileFD >= 0 else { throw POSIXError.current("opening \(profile.path)") }
        defer { close(profileFD) }

        let cliFD = openat(profileFD, "antigravity-cli", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard cliFD >= 0 else { throw SwitcherError.message("\(profile.path)/antigravity-cli is not a real folder") }
        defer { close(cliFD) }

        let dest = profile.path + "/antigravity-cli/antigravity-oauth-token"
        var dst = stat()
        if fstatat(cliFD, "antigravity-oauth-token", &dst, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (dst.st_mode & S_IFMT) == S_IFREG else {
                throw SwitcherError.message("\(dest) exists and is not a regular file")
            }
        } else if errno != ENOENT {
            throw POSIXError.current("checking \(dest)")
        }

        let stageFD = open(loginHome, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stageFD >= 0 else { throw SwitcherError.message("Antigravity CLI staging folder is missing") }
        defer { close(stageFD) }

        let geminiFD = openat(stageFD, ".gemini", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard geminiFD >= 0 else { throw SwitcherError.message("Antigravity CLI finished without writing a sign-in token") }
        defer { close(geminiFD) }

        let tokenFD = openat(geminiFD, "jetski-standalone-oauth-token", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard tokenFD >= 0 else {
            throw SwitcherError.message("Antigravity CLI finished without writing a sign-in token")
        }
        var sst = stat()
        guard fstat(tokenFD, &sst) == 0, (sst.st_mode & S_IFMT) == S_IFREG else {
            close(tokenFD)
            throw SwitcherError.message("staged Antigravity CLI token is not a regular file")
        }
        guard fchmod(tokenFD, 0o600) == 0 else {
            let err = POSIXError.current("setting permissions on staged Antigravity CLI token")
            close(tokenFD)
            throw err
        }
        close(tokenFD)

        guard renameat(geminiFD, "jetski-standalone-oauth-token", cliFD, "antigravity-oauth-token") == 0 else {
            throw POSIXError.current("moving Antigravity CLI token into \(dest)")
        }
    }

    public func start() throws {
        var staged: String?
        if profile.kind == .agy, isLoginRun {
            var env = process.environment ?? [:]
            env.removeValue(forKey: CLIKind.agy.envVar)
            env["AGY_CLI_CDE_AUTH_ACTION"] = "login"
            env["SWITCHER_BYPASS"] = "1"
            if !profile.isDefault {
                let path = try Self.prepareAgyLoginStaging(for: profile)
                staged = path
                agyLoginStage = path
                env["HOME"] = path
            }
            process.environment = env
        }
        let out = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = out
        // Never wait for end-of-file: a process started elsewhere at the same moment can inherit
        // the pipe's write end and hold it open. Read what is there, as it comes and at the end.
        readFD = out.fileHandleForReading.fileDescriptor
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        pipe = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { h.readabilityHandler = nil; return }
            if self.drain() { h.readabilityHandler = nil }
        }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            pipe = nil
            if let staged {
                agyLoginStage = nil
                try? Self.finalizeAgyLoginStaging(loginHome: staged, for: profile, succeeded: false)
            }
            throw error
        }
    }

    /// Everything readable now, without blocking. Returns true at EOF so the read-source is cleared.
    @discardableResult
    private func drain() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard readFD >= 0 else { return true }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readFD, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > 16384 { buffer = buffer.suffix(8192) }
            } else if n == 0 {
                return true
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            } else {
                return true
            }
        }
    }

    private func finishAfterExit(succeeded: Bool) {
        pipe?.fileHandleForReading.readabilityHandler = nil
        drain()
        let stage: String? = lock.withLock {
            guard !finalized else { return nil }
            finalized = true
            let s = agyLoginStage
            agyLoginStage = nil
            return s
        }
        if let stage {
            do {
                try Self.finalizeAgyLoginStaging(loginHome: stage, for: profile, succeeded: succeeded)
            } catch {
                let msg = error.localizedDescription
                lock.withLock {
                    finalizeError = msg
                    if !buffer.isEmpty, buffer.last != UInt8(ascii: "\n") {
                        buffer.append(UInt8(ascii: "\n"))
                    }
                    buffer.append(contentsOf: msg.utf8)
                    buffer.append(UInt8(ascii: "\n"))
                    if buffer.count > 16384 { buffer = buffer.suffix(8192) }
                }
            }
        }
    }

    public var isRunning: Bool { process.isRunning }

    /// Blocks until the sign-in ends. Returns its exit status (or `1` if staging promotion failed).
    @discardableResult
    public func wait() -> Int32 {
        process.waitUntilExit()
        let rawStatus = process.terminationStatus
        finishAfterExit(succeeded: rawStatus == 0)
        return (rawStatus == 0 && promotionError != nil) ? 1 : rawStatus
    }

    /// Waits up to `timeout` seconds for the process to exit without killing it.
    public func wait(timeout: TimeInterval) -> (exited: Bool, status: Int32) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        guard !process.isRunning else { return (false, -1) }
        let rawStatus = process.terminationStatus
        finishAfterExit(succeeded: rawStatus == 0)
        let status: Int32 = (rawStatus == 0 && promotionError != nil) ? 1 : rawStatus
        return (true, status)
    }

    /// Interrupt (SIGINT), then terminate and kill if it does not stop within `grace` seconds.
    public func cancel(grace: TimeInterval = 3) {
        if !process.isRunning {
            finishAfterExit(succeeded: process.terminationStatus == 0)
            return
        }
        process.interrupt()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        process.terminateAndWait(grace: 1)
        finishAfterExit(succeeded: false)
    }

    /// The last of what the CLI printed, for an error message.
    public func output() -> String {
        drain()
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer.suffix(8192), as: UTF8.self)
    }

    deinit {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let stage = agyLoginStage {
            try? FileManager.default.removeItem(atPath: stage)
        }
    }
}

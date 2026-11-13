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
        }
    }
}

extension CLIProfiles {
    /// The folder name for a new account when none is given: `account2`, `account3`, … (the
    /// default account is number 1). The folder never changes after sign-in (Claude's keychain
    /// item is named after its path), so rows show the email and this name only as a tag.
    public func suggestedName(_ kind: CLIKind) -> String {
        let taken = Set(list(kind).map { $0.name.lowercased() })
        var n = 2
        while taken.contains("account\(n)") || FS.exists(URL(fileURLWithPath: env.profilesRoot(kind) + "/account\(n)")) { n += 1 }
        return "account\(n)"
    }

    /// Other accounts of the same kind signed in as the same account (same account and
    /// organization for Claude, same ChatGPT account for Codex).
    public func duplicates(of profile: CLIProfile) -> [CLIProfile] {
        guard let key = identity(profile)?.accountKey else { return [] }
        return list(profile.kind).filter { $0.path != profile.path && identity($0)?.accountKey == key }
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
        guard Self.isRealDirectory(profile.path), CLIPath.problem(profile.path, root: env.profilesRoot(profile.kind)) == nil else {
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
        guard Self.isRealDirectory(profile.path), CLIPath.problem(profile.path, root: env.profilesRoot(profile.kind)) == nil else {
            throw SwitcherError.message("\(profile.path) is not one of Switcher's account folders")
        }
        // FileManager removes symlinks as links; it never follows them into the default folder.
        try FileManager.default.removeItem(atPath: profile.path)
    }
}

/// The CLI's own sign-in (`claude auth login`, `codex login`) run in a profile's folder with no
/// terminal: it opens the browser and waits for the callback. Output is kept (last 8 KiB) for an
/// error message; stdin is empty. `cancel()` interrupts it the way Ctrl-C would.
public final class CLILoginRun: @unchecked Sendable {
    public let profile: CLIProfile
    private let process = Process()
    private var readFD: Int32 = -1
    private let lock = NSLock()
    private var buffer = Data()

    public init(profile: CLIProfile, binary: String, arguments: [String]? = nil, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.profile = profile
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments ?? profile.kind.loginArguments
        process.environment = CLICommands.environment(base: baseEnvironment, profile: profile)
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public func start() throws {
        let out = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = out
        // Never wait for end-of-file: a process started elsewhere at the same moment can inherit
        // the pipe's write end and hold it open. Read what is there, as it comes and at the end.
        readFD = out.fileHandleForReading.fileDescriptor
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        out.fileHandleForReading.readabilityHandler = { [weak self] _ in self?.drain() }
        try process.run()
        pipe = out
    }

    private var pipe: Pipe?

    /// Everything readable now, without blocking.
    private func drain() {
        lock.lock(); defer { lock.unlock() }
        guard readFD >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readFD, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > 16384 { buffer = buffer.suffix(8192) }
            } else if n < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    public var isRunning: Bool { process.isRunning }

    /// Blocks until the sign-in ends. Returns its exit status.
    @discardableResult
    public func wait() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Interrupt (SIGINT), then terminate and kill if it does not stop within `grace` seconds.
    public func cancel(grace: TimeInterval = 3) {
        guard process.isRunning else { return }
        process.interrupt()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        process.terminateAndWait(grace: 1)
    }

    /// The last of what the CLI printed, for an error message.
    public func output() -> String {
        drain()
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer.suffix(8192), as: UTF8.self)
    }

    deinit {
        pipe?.fileHandleForReading.readabilityHandler = nil
    }
}

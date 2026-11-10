import AppKit
import Darwin
import Foundation

/// Lets a long wait (an app asking "still working, quit anyway?") be called off from the UI.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    public func cancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }
}

public enum QuitError: Error, LocalizedError, Equatable {
    case timedOut(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .timedOut(let app): "\(app) did not quit in time. Nothing was changed."
        case .cancelled: "Stopped waiting. Nothing was changed."
        }
    }
}

/// Starting, quitting and watching one app.
public protocol AppController: AnyObject {
    var name: String { get }
    var isInstalled: Bool { get }
    var isRunning: Bool { get }
    /// Ask the app to quit the way the Dock does, and wait for it and its helpers to exit.
    /// `waiting` is called about once a second with the seconds waited so far.
    func quit(timeout: TimeInterval, cancel: CancelToken?, waiting: ((TimeInterval) -> Void)?) throws
    func launch() throws
}

/// A real app, found by bundle identifier.
public final class MacApp: AppController {
    public let name: String
    public let bundleID: String
    private let fallbackURL: URL
    /// Helpers that may outlive the app and do not count (Electron's crash reporter).
    private let ignored: Set<String>

    public init(name: String, bundleID: String, fallbackPath: String, ignored: Set<String> = ["chrome_crashpad_handler"]) {
        self.name = name
        self.bundleID = bundleID
        self.fallbackURL = URL(fileURLWithPath: fallbackPath)
        self.ignored = ignored
    }

    /// Claude's `chrome-native-host` is started by Chrome for its extension and outlives Claude: it doesn't count.
    public static let claude = MacApp(name: "Claude", bundleID: "com.anthropic.claudefordesktop", fallbackPath: "/Applications/Claude.app", ignored: ["chrome_crashpad_handler", "chrome-native-host"])
    public static let antigravity = MacApp(name: "Antigravity", bundleID: "com.google.antigravity", fallbackPath: "/Applications/Antigravity.app")

    public var bundleURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        return FS.exists(fallbackURL) ? fallbackURL : nil
    }

    public var isInstalled: Bool { bundleURL != nil }

    /// The bundle's path as the process list reports programs: every link resolved, `/private` kept
    /// (Foundation's `resolvingSymlinksInPath` drops it, so nothing under /tmp or /var would match).
    var realBundlePath: String? {
        guard let url = bundleURL, let c = realpath(url.path, nil) else { return nil }
        defer { free(c) }
        return String(cString: c)
    }

    /// Processes whose program lives inside the app's bundle; nil when the process list can't be read.
    func processes() -> [(pid: pid_t, path: String)]? {
        guard let bundle = realBundlePath else { return [] }
        let prefix = bundle.hasSuffix("/") ? bundle : bundle + "/"
        guard let list = Proc.list() else { return nil }
        let mine = list.resolved.filter { proc in
            proc.path.hasPrefix(prefix) && !ignored.contains((proc.path as NSString).lastPathComponent)
        }
        // A process whose program can't be looked up but whose name looks like one of ours counts:
        // never move a sign-in while something of the app may still be running.
        let exe = bundleExecutable ?? name
        let unknown = list.unresolved.filter { p in
            !ignored.contains(where: { p.name.hasPrefix(String($0.prefix(15))) })
                && (p.name.hasPrefix(String(exe.prefix(15))) || p.name.hasPrefix(String(name.prefix(15))) || p.name.hasPrefix("language_serv") || p.name.hasPrefix("Electron"))
        }
        // Something we can't see into at all might be ours: count it, so nothing moves under it.
        return mine + unknown.map { ($0.pid, "?\($0.name)") } + list.unknown.map { ($0, "?") }
    }

    var bundleExecutable: String? {
        bundleURL.flatMap { Bundle(url: $0)?.executableURL?.lastPathComponent }
    }

    /// Running, or unknown (a failed process listing counts as running, so nothing moves under it).
    public var isRunning: Bool { processes().map { !$0.isEmpty } ?? true }

    public func quit(timeout: TimeInterval, cancel: CancelToken?, waiting: ((TimeInterval) -> Void)?) throws {
        guard let bundle = realBundlePath else { return }
        let main = bundle + "/Contents/MacOS/"
        for proc in processes() ?? [] where proc.path.hasPrefix(main) {
            kill(proc.pid, SIGTERM)
        }
        let start = Date()
        var lastTick = 0
        // Helpers can outlive the app (Antigravity's sidecars keep running, parented to launchd, and
        // may still hold the old sign-in). Once the app itself is gone, ask them to stop; if they
        // ignore that, make them.
        var mainGoneAt: Date?
        var termed = false, killed = false
        while let procs = processes(), !procs.isEmpty {
            if cancel?.isCancelled == true { throw QuitError.cancelled }
            let waited = Date().timeIntervalSince(start)
            if waited > timeout { throw QuitError.timedOut(name) }
            if Int(waited) > lastTick {
                lastTick = Int(waited)
                waiting?(waited)
            }
            if procs.contains(where: { $0.path.hasPrefix(main) }) {
                mainGoneAt = nil
            } else {
                let since = Date().timeIntervalSince(mainGoneAt ?? Date())
                if mainGoneAt == nil { mainGoneAt = Date() }
                // Ours by path, or by a name that is the app's own (one whose program was deleted
                // under it, as an update does); never one only a generic name points at.
                let own = [String((bundleExecutable ?? name).prefix(15)), String(name.prefix(15))]
                let leftover = procs.filter { p in
                    p.pid > 0 && (!p.path.hasPrefix("?") || own.contains { p.path.dropFirst().hasPrefix($0) })
                }
                if !termed, since >= Self.helperGrace {
                    for p in leftover { kill(p.pid, SIGTERM) }
                    termed = true
                } else if termed, !killed, since >= Self.helperGrace + 5 {
                    for p in leftover { kill(p.pid, SIGKILL) }
                    killed = true
                }
            }
            usleep(200_000)
        }
        // Unknown counts as running (nothing moves under it): keep waiting until the timeout.
        while isRunning {
            if cancel?.isCancelled == true { throw QuitError.cancelled }
            if Date().timeIntervalSince(start) > timeout { throw QuitError.timedOut(name) }
            usleep(200_000)
        }
    }

    /// How long helpers get to leave by themselves once the app has quit. Electron's own exit within
    /// a second; Antigravity's sidecars never do, so a longer wait only delays every switch.
    static let helperGrace: TimeInterval = 1

    public func launch() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", bundleID]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw SwitcherError.message("could not open \(name)") }
    }
}

enum Proc {
    /// Every process and its program; nil when the list can't be read.
    static func all() -> [(pid: pid_t, path: String)]? { list()?.resolved }

    struct Listing {
        var resolved: [(pid: pid_t, path: String)]
        /// Processes whose program could not be looked up (other than ones already gone), by name.
        var unresolved: [(pid: pid_t, name: String)]
        /// Live processes about which nothing at all could be read.
        var unknown: [pid_t] = []
    }

    static func isGone(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        if r <= 0 { return errno == ESRCH }
        return info.pbi_status == UInt32(SZOMB) // a zombie holds no files
    }

    static func list() -> Listing? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }
        var out = Listing(resolved: [], unresolved: [], unknown: [])
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var nameBuf = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
                out.resolved.append((pid, String(cString: buf)))
            } else if errno != ESRCH {
                // Gone (ESRCH) is fine; anything else is a process we can't see into.
                if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
                    out.unresolved.append((pid, String(cString: nameBuf)))
                } else if !isGone(pid) {
                    // Neither its program nor its name can be read, yet it is there: it could be anyone's.
                    out.unknown.append(pid)
                }
            }
        }
        return out
    }
}

/// A stand-in app for tests and dry runs.
public final class FakeApp: AppController {
    public let name: String
    public var isInstalled = true
    public var isRunning: Bool
    public private(set) var launches = 0
    public private(set) var quits = 0
    /// Refuse to quit (an app whose user pressed "Cancel").
    public var refusesToQuit = false
    /// Called while the app is quit, before it launches again: lets a test check what the swap did.
    public var whileQuit: (() -> Void)?

    public init(name: String = "Fake", running: Bool = false) {
        self.name = name
        self.isRunning = running
    }

    public func quit(timeout: TimeInterval, cancel: CancelToken?, waiting: ((TimeInterval) -> Void)?) throws {
        if refusesToQuit { throw QuitError.timedOut(name) }
        quits += 1
        isRunning = false
        whileQuit?()
    }

    public func launch() throws {
        launches += 1
        isRunning = true
    }
}

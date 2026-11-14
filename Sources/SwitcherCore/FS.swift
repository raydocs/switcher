import Foundation

/// File helpers. Every write is atomic (temporary file, fsync, rename) and nothing follows symlinks.
public enum FS {
    static let fm = FileManager.default

    /// Whether anything (a file, folder or symlink) is at `url`, without following a symlink.
    public static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    public static func isFile(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// A folder only this user can read.
    public static func makePrivateDir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if isDirectory(url) { _ = chmod(url.path, 0o700) }
    }

    /// Write `data` to `url` atomically with mode 0600.
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError.current("creating \(tmp.path)") }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        try data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    close(fd)
                    throw POSIXError.current("writing \(tmp.path)")
                }
                offset += n
            }
        }
        if fsync(fd) != 0 {
            close(fd)
            throw POSIXError.current("syncing \(tmp.path)")
        }
        close(fd)
        if rename(tmp.path, url.path) != 0 { throw POSIXError.current("replacing \(url.path)") }
        ok = true
    }

    /// Rename `from` to `to` (same volume). Fails if `to` exists.
    public static func move(_ from: URL, to: URL) throws {
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if exists(to) { throw SwitcherError.message("\(to.path) is in the way") }
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) != 0 {
            throw POSIXError.current("moving \(from.path) to \(to.path)")
        }
    }

    /// `base`, or `base-2`, `base-3`, … whichever does not exist yet.
    public static func uniquePath(_ base: URL) -> URL {
        if !exists(base) { return base }
        var n = 2
        while true {
            let candidate = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent)-\(n)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    public static func readJSONObject(_ url: URL) throws -> [String: Any]? {
        guard isFile(url) else { return nil }
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwitcherError.message("\(url.lastPathComponent) is not a JSON object")
        }
        return obj
    }

    public static func readCodable<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard isFile(url), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func writeCodable<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(try enc.encode(value), to: url)
    }

    public static func removeIfExists(_ url: URL) {
        if exists(url) { try? fm.removeItem(at: url) }
    }

    public static func children(_ url: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func mtime(_ url: URL) -> Date? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }

    public static var now: TimeInterval { Date().timeIntervalSince1970 }
}

public enum SwitcherError: Error, LocalizedError, Equatable {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let m): m
        }
    }
}

extension POSIXError {
    static func current(_ what: String) -> SwitcherError {
        .message("\(what): \(String(cString: strerror(errno)))")
    }
}

/// An exclusive lock on a file, held for the lifetime of the value. One switch at a time,
/// across the app, the CLI and the background agent.
public final class FileLock {
    private let fd: Int32

    public init(_ url: URL, timeout: TimeInterval) throws {
        try FS.makePrivateDir(url.deletingLastPathComponent())
        fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError.current("opening \(url.path)") }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline {
                close(fd)
                throw SwitcherError.message("another Switcher task is still running")
            }
            usleep(100_000)
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

extension Process {
    /// SIGTERM, wait up to `grace` seconds, then SIGKILL, and wait until the process has exited.
    func terminateAndWait(grace: TimeInterval) {
        guard isRunning else { return }
        terminate()
        let deadline = Date().addingTimeInterval(grace)
        while isRunning, Date() < deadline { usleep(20_000) }
        if isRunning { kill(processIdentifier, SIGKILL) }
        waitUntilExit()
    }
}

/// Reads a pipe to EOF on a background queue so the child never blocks on a full pipe.
final class DrainedOutput: @unchecked Sendable {
    private let handle: FileHandle
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
        DispatchQueue.global().async { [self] in
            let all = handle.readDataToEndOfFile()
            lock.lock(); data = all; lock.unlock()
            done.signal()
        }
    }

    /// What was read, waiting up to `waiting` seconds for EOF (a grandchild may hold the pipe open).
    @discardableResult
    func finish(waiting: TimeInterval) -> Data {
        _ = done.wait(timeout: .now() + waiting)
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

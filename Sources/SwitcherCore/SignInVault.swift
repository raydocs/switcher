import Foundation

/// What makes up an app's sign-in on disk and in the keychain.
public struct SignInLayout {
    /// Files and folders that move whole. In a saved sign-in they keep their names.
    public var items: [URL]
    /// Keys of a JSON settings file that belong to the sign-in.
    public var jsonKeys: [JSONKeys]
    /// Keychain items that belong to the sign-in.
    public var secrets: [SecretRef]
    /// State the app keeps for the signed-in account and makes again: set aside on a switch.
    public var drop: [URL]

    public struct JSONKeys {
        public var file: URL
        /// Its name in a saved sign-in.
        public var vaultName: String
        public var keys: [String]
    }

    public struct SecretRef: Codable, Equatable {
        public var service: String
        public var account: String
        /// What a healthy value looks like. A value of another shape is refused, never moved.
        public var shape: Shape = .any
        var tag: String { "\(service)/\(account)" }

        public enum Shape: String, Codable, Equatable {
            case any
            /// A JSON object or array.
            case json
            /// What zalando/go-keyring writes: `go-keyring-base64:<base64>`, `go-keyring-encoded:<hex>`,
            /// or the JSON itself. Bare hex (what `security -w` prints for a value with non-printable
            /// bytes) is none of these.
            case goKeyring
        }

        /// Whether `value` is of the expected shape.
        func accepts(_ value: String) -> Bool {
            switch shape {
            case .any:
                return true
            case .json:
                return Self.isJSONContainer(value)
            case .goKeyring:
                let b64 = "go-keyring-base64:", enc = "go-keyring-encoded:"
                if value.hasPrefix(b64) {
                    let body = String(value.dropFirst(b64.count))
                    guard !body.isEmpty, let data = Data(base64Encoded: body) else { return false }
                    return !data.isEmpty
                }
                if value.hasPrefix(enc) {
                    let body = value.dropFirst(enc.count)
                    return !body.isEmpty && body.count % 2 == 0 && body.allSatisfy { $0.isHexDigit }
                }
                return Self.isJSONContainer(value)
            }
        }

        private static func isJSONContainer(_ value: String) -> Bool {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(value.utf8)) else { return false }
            return obj is [String: Any] || obj is [Any]
        }
    }
}

/// A sign-in set aside, ready to switch to. Same `about.json` as cc-same, so its saved sign-ins
/// can be adopted as they are.
public struct SavedLogin: Codable, Equatable, Identifiable {
    public var account: String
    public var email: String?
    /// When it was set aside (Unix seconds): when it was last in use.
    public var setAsideAt: TimeInterval

    public var id: String { account }

    /// A sign-in unused for about four weeks has probably expired on the server.
    public var probablyExpired: Bool { FS.now - setAsideAt > 28 * 86_400 }
}

/// Who is signed in.
public struct Identity: Equatable {
    public var id: String
    public var email: String?

    public init(id: String, email: String?) {
        self.id = id
        self.email = email
    }
}

/// Saved sign-ins for one app, and the journaled swap that trades them with the live one.
///
/// Every change is written to a journal before it is made. A swap that fails is undone; one cut
/// short (a crash, a power cut) is undone or finished by `recover()`. Files move (rename on the same
/// disk), they are never copied, so a sign-in whose tokens rotate is never put back twice.
public final class SignInVault {
    public let provider: ProviderID
    public let layout: SignInLayout
    let root: URL
    let trashRoot: URL
    let keychain: SecretStore

    /// Our own keychain items holding saved copies of the app's keychain items.
    static let vaultService = "Switcher saved sign-in"
    static let stageID = ".incoming"
    static let journalName = "switch.json"
    static let aboutName = "about.json"

    public init(env: Env, provider: ProviderID, layout: SignInLayout, keychain: SecretStore) {
        self.provider = provider
        self.layout = layout
        self.root = env.vault(provider)
        self.trashRoot = env.state.appendingPathComponent("trash", isDirectory: true)
        self.keychain = keychain
    }

    func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    var stage: URL { dir(Self.stageID) }
    var journalURL: URL { root.appendingPathComponent(Self.journalName) }

    func vaultKey(_ id: String, _ s: SignInLayout.SecretRef) -> String { "\(provider.rawValue)/\(id)/\(s.tag)" }

    // MARK: Saved sign-ins

    public func saved(excluding current: String? = nil) -> [SavedLogin] {
        FS.children(root)
            .filter { !$0.lastPathComponent.hasPrefix(".") && FS.isDirectory($0) && $0.lastPathComponent != current }
            .filter { isComplete($0) }
            .map { about($0) }
            .sorted { $0.setAsideAt > $1.setAsideAt }
    }

    public func isSaved(_ id: String) -> Bool {
        !id.hasPrefix(".") && !id.contains("/") && isComplete(dir(id))
    }

    /// A saved sign-in counts once its key files (or, with none, its about.json) are in place.
    func isComplete(_ d: URL) -> Bool {
        if let first = layout.jsonKeys.first { return FS.isFile(d.appendingPathComponent(first.vaultName)) }
        return FS.isFile(d.appendingPathComponent(Self.aboutName))
    }

    func about(_ d: URL) -> SavedLogin {
        if let a = FS.readCodable(SavedLogin.self, from: d.appendingPathComponent(Self.aboutName)) { return a }
        return SavedLogin(account: d.lastPathComponent, email: nil, setAsideAt: FS.mtime(d)?.timeIntervalSince1970 ?? 0)
    }

    /// The saved copy of one of the app's keychain items, for an account set aside.
    public func savedSecret(_ id: String, _ ref: SignInLayout.SecretRef) -> String? {
        guard isSaved(id) else { return nil }
        return try? keychain.get(service: Self.vaultService, account: vaultKey(id, ref))
    }

    /// Forget the sign-in saved for `id`.
    public func forget(_ id: String) throws {
        guard isSaved(id) else { return }
        try trash(dir(id))
        for s in layout.secrets { try keychain.delete(service: Self.vaultService, account: vaultKey(id, s)) }
    }

    /// Adopt a saved sign-in from elsewhere (cc-same), moving its folder in.
    public func adopt(folder: URL, id: String) throws -> Bool {
        guard !id.hasPrefix("."), !id.contains("/") else { return false }
        if isSaved(id) { return false }
        try FS.makePrivateDir(root)
        if FS.exists(dir(id)) { try trash(dir(id)) }
        try FS.move(folder, to: dir(id))
        return true
    }

    func trash(_ url: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let bin = trashRoot.appendingPathComponent(stamp, isDirectory: true)
        try FS.makePrivateDir(bin)
        try FS.move(url, to: FS.uniquePath(bin.appendingPathComponent("\(provider.rawValue)-\(url.lastPathComponent)")))
    }

    /// How long a trashed sign-in is kept before it is deleted for good.
    static let trashRetention: TimeInterval = 14 * 86_400

    /// Delete trash entries older than the retention. Only direct children of the trash folder that
    /// are real folders (what `trash()` makes) are considered; nothing outside it is touched.
    func pruneTrash(now: TimeInterval = FS.now) {
        guard FS.isDirectory(trashRoot) else { return }
        for bin in FS.children(trashRoot) where FS.isDirectory(bin) {
            guard let modified = FS.mtime(bin), now - modified.timeIntervalSince1970 > Self.trashRetention else { continue }
            FS.removeIfExists(bin)
        }
    }

    // MARK: Swap

    struct Journal: Codable {
        var from: String?
        var fromEmail: String?
        var to: String?
        /// [from, to] renames, recorded before each is made.
        var moves: [[String]] = []
        /// Settings files rewritten: the original and a copy of it (nil: there was none).
        var backups: [[String?]] = []
        /// Live keychain items stashed under the stage before being changed: whether each existed.
        var stashed: [String: Bool] = [:]
        var committed = false
    }

    final class Run {
        var j: Journal
        let url: URL
        init(_ j: Journal, url: URL) { self.j = j; self.url = url }
        func save() throws { try FS.writeCodable(j, to: url) }
        func move(_ a: URL, _ b: URL) throws {
            j.moves.append([a.path, b.path])
            try save()
            try FS.move(a, to: b)
        }
    }

    /// Set `from`'s sign-in aside and put `to`'s in its place (nobody's, for nil), all or nothing.
    /// The app must not be running.
    public func swap(from: Identity?, to: String?) throws {
        try FS.makePrivateDir(root)
        try recover()
        if FS.exists(stage) { try FS.move(stage, to: FS.uniquePath(root.appendingPathComponent(".stranded"))) }
        if let to, !isSaved(to) { throw SwitcherError.message("no sign-in is saved for \(to)") }
        // Credentials whose account can't be told would have nowhere to be filed: refuse, never drop them.
        if from == nil {
            for s in layout.secrets where try keychain.get(service: s.service, account: s.account) != nil {
                throw SwitcherError.message(L10n.t(
                    "Can't tell which account the app is signed in to, so its sign-in can't be set aside safely. Open the app once so it finishes signing in, then try again.",
                    "无法判断该应用当前登录的是哪个账号，无法安全地保存它的登录。先打开一次该应用让它完成登录，再试。"))
            }
        }
        // A live value that isn't the shape the app writes (the keychain tool prints hex for bytes it
        // can't show) would be saved wrong and put back corrupted: refuse before anything moves.
        for s in layout.secrets {
            if let value = try keychain.get(service: s.service, account: s.account), !s.accepts(value) {
                throw SwitcherError.message(L10n.t(
                    "The keychain item \(s.service)/\(s.account) isn't in the form the app writes, so its sign-in can't be set aside safely. Nothing was changed.",
                    "钥匙串项目 \(s.service)/\(s.account) 的格式不是应用写入的格式，无法安全地保存其登录。未做任何改动。"))
            }
        }
        try FS.makePrivateDir(stage)
        let run = Run(Journal(from: from?.id, fromEmail: from?.email, to: to), url: journalURL)
        try run.save()
        do {
            try perform(run)
            // Committed only once this is on disk; until then a failure is undone.
            try faultBeforeCommit?()
            run.j.committed = true
            try run.save()
        } catch {
            run.j.committed = false
            do { try undo(run.j) } catch let undoError {
                throw SwitcherError.message("\(error.localizedDescription); undoing it also failed: \(undoError.localizedDescription)")
            }
            throw error
        }
        // The switch has happened. Tidying up can fail without undoing it: the journal stays and
        // `recover()` finishes the job next time.
        do {
            try finish(run.j)
            cleanupPending = nil
        } catch {
            cleanupPending = error.localizedDescription
        }
    }

    /// Tests: fail right before the commit is written.
    var faultBeforeCommit: (() throws -> Void)?

    /// Why tidying up after the last committed switch failed, if it did (it is retried by `recover()`).
    public private(set) var cleanupPending: String?

    private func perform(_ run: Run) throws {
        // Copies of the settings files first, so they can be put back exactly.
        for (n, j) in layout.jsonKeys.enumerated() {
            if FS.isFile(j.file) {
                let copy = stage.appendingPathComponent(".before-\(n)")
                try FS.atomicWrite(try Data(contentsOf: j.file), to: copy)
                run.j.backups.append([j.file.path, copy.path])
            } else {
                run.j.backups.append([j.file.path, nil])
            }
            try run.save()
        }
        // The live keychain items, stashed under the stage.
        for s in layout.secrets {
            let value = try keychain.get(service: s.service, account: s.account)
            if let value { try keychain.set(service: Self.vaultService, account: vaultKey(Self.stageID, s), value: value) }
            run.j.stashed[s.tag] = value != nil
            try run.save()
        }
        // Set the sign-in in use aside.
        for item in layout.items where FS.exists(item) {
            try run.move(item, stage.appendingPathComponent(item.lastPathComponent))
        }
        for item in layout.drop where FS.exists(item) {
            try run.move(item, stage.appendingPathComponent(".dropped", isDirectory: true).appendingPathComponent(item.lastPathComponent))
        }
        for j in layout.jsonKeys {
            let doc = FS.isFile(j.file) ? try OrderedJSON(contentsOf: j.file) : OrderedJSON()
            var mine = OrderedJSON()
            for k in j.keys { if let v = doc[k] { mine[k] = v } }
            try FS.atomicWrite(Data(mine.text(indent: "  ").utf8), to: stage.appendingPathComponent(j.vaultName))
        }
        // Put the target's in its place.
        let target = run.j.to.map(dir)
        if let target {
            for item in layout.items {
                let parked = target.appendingPathComponent(item.lastPathComponent)
                if FS.exists(parked) { try run.move(parked, item) }
            }
        }
        for j in layout.jsonKeys {
            var adding: [OrderedJSON.Member] = []
            if let target {
                let saved = try OrderedJSON(contentsOf: target.appendingPathComponent(j.vaultName))
                adding = j.keys.compactMap { k in saved[k].map { OrderedJSON.Member(key: k, raw: $0) } }
            }
            // Only the sign-in's keys change; every other byte stays as the app wrote it.
            let original = FS.isFile(j.file) ? String(decoding: try Data(contentsOf: j.file), as: UTF8.self) : "{}"
            let text = try OrderedJSON.edit(original, removing: j.keys, adding: adding)
            try FS.atomicWrite(Data(text.utf8), to: j.file)
        }
        for s in layout.secrets {
            if let to = run.j.to, let value = try keychain.get(service: Self.vaultService, account: vaultKey(to, s)) {
                try keychain.set(service: s.service, account: s.account, value: value)
            } else {
                try keychain.delete(service: s.service, account: s.account)
            }
        }
    }

    /// Put everything back as it was before the swap began.
    private func undo(_ j: Journal) throws {
        for m in j.moves.reversed() {
            let a = URL(fileURLWithPath: m[0]), b = URL(fileURLWithPath: m[1])
            if FS.exists(b), !FS.exists(a) { try FS.move(b, to: a) }
        }
        for b in j.backups {
            guard let original = b[0].map({ URL(fileURLWithPath: $0) }) else { continue }
            if let copy = b[1].map({ URL(fileURLWithPath: $0) }), FS.isFile(copy) {
                try FS.atomicWrite(try Data(contentsOf: copy), to: original)
            } else if b[1] == nil {
                FS.removeIfExists(original)
            }
        }
        for s in layout.secrets {
            let key = vaultKey(Self.stageID, s)
            if let existed = j.stashed[s.tag] {
                if existed, let value = try keychain.get(service: Self.vaultService, account: key) {
                    try keychain.set(service: s.service, account: s.account, value: value)
                } else if !existed {
                    try keychain.delete(service: s.service, account: s.account)
                }
            }
            try keychain.delete(service: Self.vaultService, account: key)
        }
        if FS.exists(stage) { try trash(stage) }
        FS.removeIfExists(journalURL)
    }

    /// File the stage under the account set aside, and clear out what was put back. Safe to run
    /// again after an interruption.
    private func finish(_ j: Journal) throws {
        if FS.exists(stage) {
            for name in [".dropped"] + layout.jsonKeys.indices.map({ ".before-\($0)" }) {
                FS.removeIfExists(stage.appendingPathComponent(name))
            }
            if let from = j.from {
                let about = SavedLogin(account: from, email: j.fromEmail, setAsideAt: FS.now)
                try FS.writeCodable(about, to: stage.appendingPathComponent(Self.aboutName))
                for s in layout.secrets {
                    let key = vaultKey(Self.stageID, s)
                    if let value = try keychain.get(service: Self.vaultService, account: key) {
                        try keychain.set(service: Self.vaultService, account: vaultKey(from, s), value: value)
                        try keychain.delete(service: Self.vaultService, account: key)
                    }
                }
                if FS.exists(dir(from)) { try trash(dir(from)) }
                try FS.move(stage, to: dir(from))
            } else {
                for s in layout.secrets { try keychain.delete(service: Self.vaultService, account: vaultKey(Self.stageID, s)) }
                try trash(stage)
            }
        }
        if let to = j.to, to != j.from {
            // What is left is a duplicate of what is now live: never keep it to be put back twice.
            if FS.exists(dir(to)) { try FileManager.default.removeItem(at: dir(to)) }
            for s in layout.secrets { try keychain.delete(service: Self.vaultService, account: vaultKey(to, s)) }
        }
        FS.removeIfExists(journalURL)
    }

    /// Undo a swap interrupted before everything was in place, or finish one interrupted after.
    /// Only while the app is not running.
    public func recover() throws {
        guard FS.isFile(journalURL) else { return }
        guard let j = FS.readCodable(Journal.self, from: journalURL) else {
            // Never guess: leave the journal, the stage and every sign-in exactly where they are.
            throw SwitcherError.message(L10n.t(
                "An interrupted switch left a journal Switcher can't read (\(journalURL.path)). Nothing was changed; check that file before switching again.",
                "中断的切换留下了无法读取的记录（\(journalURL.path)）。未做任何改动；请先检查该文件再切换。"))
        }
        if j.committed { try finish(j) } else { try undo(j) }
    }

    /// Drop a saved copy that is out of date because the app is already signed in to it.
    public func dropStale(_ id: String) throws {
        if isSaved(id) { try forget(id) }
    }

    public var hasInterruptedSwap: Bool { FS.isFile(journalURL) }
}

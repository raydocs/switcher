import AppKit
import ServiceManagement
import Foundation
import Observation
import SwitcherCore

/// What a switch in progress is doing, for the progress view.
enum SwitchPhase: Equatable {
    case quitting(app: String, waited: Int)
    case swapping
    case opening(app: String)
}

struct SwitchJob: Equatable {
    var provider: ProviderID
    /// nil: adding an account (the app opens signed out).
    var target: String?
    var targetLabel: String?
    var phase: SwitchPhase
}

struct Banner: Equatable, Identifiable {
    enum Kind { case success, error, info }
    var id = UUID()
    var kind: Kind
    var text: String
}

/// The app's state over SwitcherCore. Every call into the core that can block (quitting an app,
/// moving files, the keychain) runs off the main thread; results come back here.
@MainActor
@Observable
final class AppModel {
    private(set) var boards: [AppBoard] = []
    private(set) var job: SwitchJob?
    private(set) var ccSame: CCSameImport.Found?
    var banner: Banner?
    /// The app section the popover shows first.
    var selected: ProviderID = .claude

    @ObservationIgnored let board: Switchboard
    @ObservationIgnored private let queue = DispatchQueue(label: "switcher.core", qos: .userInitiated)
    @ObservationIgnored private var cancel: CancelToken?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isPreview = false

    /// Fixed data for previews and screenshots: touches nothing on disk.
    init(preview boards: [AppBoard], ccSame: CCSameImport.Found? = nil, job: SwitchJob? = nil, banner: Banner? = nil) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-preview", isDirectory: true)
        let env = Env(home: home)
        self.board = Switchboard(env: env, claude: .claude(env: env, app: FakeApp(), keychain: MemorySecrets()), antigravity: .antigravity(env: env, app: FakeApp(), keychain: MemorySecrets()))
        self.boards = boards
        self.ccSame = ccSame
        self.job = job
        self.banner = banner
        self.isPreview = true
    }

    init(board: Switchboard = Switchboard()) {
        self.board = board
        queue.async { board.recoverIfIdle() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func board(_ p: ProviderID) -> AppBoard? { boards.first { $0.provider == p } }

    var isBusy: Bool { job != nil }

    /// Re-read every app. Cheap: run when the menu opens and every 15 seconds.
    func refresh() {
        if isPreview { return }
        let board = self.board
        queue.async {
            let boards = board.board()
            let found = board.ccSameImport()
            Task { @MainActor in
                // Assign only what changed, so a quiet 15-second tick redraws nothing.
                if self.boards != boards { self.boards = boards }
                if self.ccSame != found { self.ccSame = found }
                self.refreshQuotasIfDue()
            }
        }
    }

    @ObservationIgnored private var quotasReadAt: Date?
    @ObservationIgnored private var readingQuotas = false

    /// Antigravity quotas come from Google: read them at most every 5 minutes (sooner with `force`).
    func refreshQuotasIfDue(force: Bool = false) {
        if isPreview || readingQuotas { return }
        if !force, let at = quotasReadAt, Date().timeIntervalSince(at) < 300 { return }
        readingQuotas = true
        let board = self.board
        Task.detached {
            await board.refreshAntigravityUsage()
            let boards = board.board()
            await MainActor.run {
                self.readingQuotas = false
                self.quotasReadAt = Date()
                if self.boards != boards { self.boards = boards }
            }
        }
    }

    /// Switch `p` to `row`'s account.
    func switchTo(_ p: ProviderID, _ row: AccountRow) {
        guard !row.isCurrent, row.canSwitch else { return }
        start(p, target: row.slot.account, label: row.slot.label)
    }

    func next(_ p: ProviderID) {
        guard job == nil, !isPreview else { return }
        let board = self.board
        // Reading who is signed in asks the keychain: keep it off the main thread.
        queue.async {
            let slot = board.nextAccount(p)
            Task { @MainActor in
                guard let slot else {
                    self.banner = Banner(kind: .info, text: L.noOtherAccount(p.displayName))
                    return
                }
                self.start(p, target: slot.account, label: slot.label)
            }
        }
    }

    /// Restart the app signed out so the user can sign in to another account.
    func addAccount(_ p: ProviderID) { start(p, target: nil, label: nil) }

    func cancelSwitch() { cancel?.cancel() }

    // MARK: Settings

    /// Open at login, through the system's login items.
    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                banner = Banner(kind: .error, text: error.localizedDescription)
            }
        }
    }

    private func start(_ p: ProviderID, target: String?, label: String?) {
        guard job == nil, !isPreview else { return }
        let token = CancelToken()
        cancel = token
        let name = board.provider(p).app.name
        job = SwitchJob(provider: p, target: target, targetLabel: label, phase: .quitting(app: name, waited: 0))
        let board = self.board
        queue.async {
            let result: Result<SwitchResult, Error>
            do {
                let r = try board.switchTo(p, account: target, alwaysLaunch: true, cancel: token) { waited in
                    Task { @MainActor in self.job?.phase = .quitting(app: name, waited: Int(waited)) }
                }
                result = .success(r)
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in
                self.job = nil
                self.cancel = nil
                switch result {
                case .success:
                    self.banner = Banner(kind: .success, text: target == nil ? L.signInToAdd(name) : L.switched(name, label ?? ""))
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: error.localizedDescription)
                }
                self.refresh()
            }
        }
    }

    // MARK: Account list

    func setDisabled(_ p: ProviderID, _ account: String, _ disabled: Bool) {
        edit { try Roster.edit($0.env) { $0.setDisabled(p, account, disabled) } }
    }

    func move(_ p: ProviderID, _ account: String, to number: Int) {
        edit { try Roster.edit($0.env) { try $0.move(p, account, to: number) } }
    }

    func remove(_ p: ProviderID, _ account: String) {
        edit { try $0.remove(p, account: account) }
    }

    func importCCSame() {
        let board = self.board
        queue.async {
            let result = Result { try board.importCCSame() }
            Task { @MainActor in
                switch result {
                case .success(let r): self.banner = Banner(kind: .success, text: L.imported(r.logins))
                case .failure(let e): self.banner = Banner(kind: .error, text: e.localizedDescription)
                }
                self.refresh()
            }
        }
    }

    /// List edits take file locks (removing waits up to 30 s for a switch): run them on the core queue.
    private func edit(_ body: @escaping @Sendable (Switchboard) throws -> Void) {
        let board = self.board
        queue.async {
            let result = Result { try body(board) }
            Task { @MainActor in
                if case .failure(let error) = result { self.banner = Banner(kind: .error, text: error.localizedDescription) }
                self.refresh()
            }
        }
    }
}

/// The words on screen, in English and Simplified Chinese, following the system language.
enum L {
    static let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    static func t(_ en: String, _ cn: String) -> String { zh ? cn : en }

    static func noOtherAccount(_ app: String) -> String {
        t("No other \(app) account has a saved sign-in yet.", "还没有其他已保存登录的 \(app) 账号。")
    }

    static func signInToAdd(_ app: String) -> String {
        t("\(app) is open on its sign-in page. Sign in to the account to add.", "\(app) 已打开登录页，登录要添加的账号即可。")
    }

    static func switched(_ app: String, _ who: String) -> String {
        t("\(app) is now signed in to \(who).", "\(app) 已切换到 \(who)。")
    }

    static func imported(_ n: Int) -> String {
        t("Imported \(n) saved sign-in(s) from CC Same.", "已从 CC Same 导入 \(n) 个已保存登录。")
    }
}

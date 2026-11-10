import AppKit
import SwiftUI
import SwitcherCore

/// `SwitcherApp --snapshot <dir>`: draws the popover and the Settings window from fixed, made-up data
/// into PNGs, in light and dark and in English and Chinese, so the design can be judged without the
/// real apps or accounts. Nothing here reads the user's data. With `SWITCHER_SNAPSHOT_NATIVE=1` each
/// Settings page is also laid out in a real, never shown window (`…-native-<lang>.png`), to check the
/// system's own controls and the page's height.
@MainActor
enum Snapshot {
    struct Fixture {
        var name: String
        var model: AppModel
        var staged = MenuView.Staged()
        /// Set: the Settings window on this tab, instead of the popover.
        var settings: SettingsTab?
        var page = SettingsPage.Staged()
    }

    static func run(into dir: String) -> Int32 {
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let lang = L.zh ? "zh" : "en"
            for fixture in fixtures() {
                for scheme in [ColorScheme.light, .dark] {
                    let url = out.appendingPathComponent("\(fixture.name)-\(scheme == .dark ? "dark" : "light")-\(lang).png")
                    try render(fixture, scheme: scheme, to: url)
                    print(url.path)
                }
                // The same page in a real (never shown) window: the system's switch, field and scrolling.
                if let tab = fixture.settings, ProcessInfo.processInfo.environment["SWITCHER_SNAPSHOT_NATIVE"] != nil {
                    let url = out.appendingPathComponent("\(fixture.name)-native-\(lang).png")
                    try renderInWindow(SettingsPage(model: fixture.model, tab: tab, staged: fixture.page), to: url)
                    print(url.path)
                }
            }
            if ProcessInfo.processInfo.environment["SWITCHER_SNAPSHOT_NATIVE"] != nil, let last = fixtures().last {
                // The whole window's content, tabs included (as a plain tab view: there is no Settings scene here).
                let url = out.appendingPathComponent("28-settings-tabview-native-\(lang).png")
                try renderInWindow(SettingsView(model: last.model), to: url)
                print(url.path)
            }
            // `L` follows the system language, fixed at launch: draw the other one in a child run.
            if ProcessInfo.processInfo.environment["SWITCHER_SNAPSHOT_CHILD"] == nil, let exe = Bundle.main.executableURL {
                let child = Process()
                child.executableURL = exe
                child.arguments = ["--snapshot", dir, "-AppleLanguages", L.zh ? "(en)" : "(zh-Hans)"]
                child.environment = ProcessInfo.processInfo.environment.merging(["SWITCHER_SNAPSHOT_CHILD": "1"]) { $1 }
                try child.run()
                child.waitUntilExit()
                if child.terminationStatus != 0 { return child.terminationStatus }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            return 1
        }
    }

    static func render(_ fixture: Fixture, scheme: ColorScheme, to url: URL) throws {
        let dark = scheme == .dark
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Stand-ins for what the system draws: the popover's material or the window, and the desktop behind.
        let surface: AnyView
        if let tab = fixture.settings {
            surface = AnyView(SettingsWindowStandIn(model: fixture.model, tab: tab, staged: fixture.page)
                .background(dark ? Color(white: 0.2) : Color(white: 0.925)))
        } else {
            surface = AnyView(MenuView(model: fixture.model, staged: fixture.staged)
                .background(dark ? Color(white: 0.17) : Color(white: 0.94)))
        }
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let view = surface
            .environment(\.staticRender, true)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
            .compositingGroup()
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .padding(16)
            .background(dark ? Color(white: 0.07) : Color(white: 0.76))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    /// Lay the view out in an offscreen window, as the app would, and copy what it draws.
    static func renderInWindow(_ view: some View, to url: URL) throws {
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.settingsWidth, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // A few turns for SwiftUI to measure the page and settle on its height.
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        FileHandle.standardError.write(Data("native \(url.lastPathComponent): fitting \(host.fittingSize)\n".utf8))
        window.close()
    }

    // MARK: Fixtures

    static func fixtures() -> [Fixture] {
        let s = Make()
        let work = "3f1a9c52-7b1e-4c0a-9d2f-6a51e8b7c001"
        let grace = "8d2b4e17-0c3a-4f6b-b1a9-2e7c5d9f0002"
        let kat = "c47b90e2-51d8-4a3e-8f70-9b1d2c3e0003"
        let alan = "e9a05f38-6d2c-4b7a-a4e1-0f8b7a6d0004"
        let side = "1b6e3d94-a8f2-4c5d-9e03-7d4c2b1a0005"

        let claudeRows = [
            s.claude(1, work, "ada@lovelace.dev", alias: "work", current: true, usage: (42, 18, 4)),
            s.claude(2, grace, "grace@hopper.work", savedDaysAgo: 0.2, usage: (91, 64, 9)),
            s.claude(3, kat, "katherine.j@orbital.dev", savedDaysAgo: 3, usage: (8, 77, 135)),
            s.claude(4, alan, "alan@bletchley.io", canSwitch: false, usage: nil),
        ]
        let edgeRows = [
            s.claude(1, work, "ada@lovelace.dev", alias: "work", current: true, usage: (42, 18, 4)),
            s.claude(2, grace, "grace@hopper.work", savedDaysAgo: 0.2, usage: (91, 64, 9)),
            s.claude(3, kat, "katherine.j@orbital.dev", expired: true, savedDaysAgo: 41, usage: (8, 77, 135)),
            s.claude(4, side, "ada.side@lovelace.dev", alias: "side-project", sitsOut: true, savedDaysAgo: 6, usage: (0, 100, 26)),
            s.claude(5, alan, "alan@bletchley.io", canSwitch: false, usage: nil),
        ]
        let antigravityRows = [
            s.antigravity(1, "ada@lovelace.dev", current: true, quota: s.quota(
                plan: "Google AI Ultra Lite", gemini: (34, 12), claude: (78, 41), argon: 6, resetHours: 2.4, minutesAgo: 3)),
            s.antigravity(2, "studio@lovelace.dev", alias: "studio", quota: s.quota(
                plan: "Google AI Pro", gemini: (96, 58), claude: (100, 72), argon: 0, resetHours: 0.7, minutesAgo: 12,
                problem: "The quota service answered 503 (try again later).")),
        ]

        func boards(claude rows: [AccountRow] = claudeRows, claudeRunning: Bool = true, antigravityInstalled: Bool = true, interrupted: Bool = false) -> [AppBoard] {
            let theirs = antigravityInstalled ? antigravityRows : []
            return [
                AppBoard(provider: .claude, installed: true, running: claudeRunning, current: rows.first { $0.isCurrent }?.id, rows: rows, interrupted: interrupted),
                AppBoard(provider: .antigravity, installed: antigravityInstalled, running: false, current: theirs.first { $0.isCurrent }?.id, rows: theirs),
            ]
        }

        let found = CCSameImport.Found(slots: 4, logins: [grace, kat, alan], running: false, interruptedSwitch: false)
        var foundRunning = found
        foundRunning.running = true

        func model(_ boards: [AppBoard], ccSame: CCSameImport.Found? = nil, job: SwitchJob? = nil, banner: Banner? = nil,
                   selected: ProviderID = .claude) -> AppModel {
            let m = AppModel(preview: boards, ccSame: ccSame, job: job, banner: banner)
            m.selected = selected
            return m
        }

        return [
            Fixture(name: "01-claude", model: model(boards())),
            Fixture(name: "02-antigravity", model: model(boards(), selected: .antigravity)),
            Fixture(name: "03-ccsame-offer", model: model(boards(), ccSame: found)),
            Fixture(name: "04-ccsame-running", model: model(boards(), ccSame: foundRunning)),
            Fixture(name: "05-switching-asked", model: model(boards(), job: SwitchJob(
                provider: .claude, target: grace, targetLabel: "grace@hopper.work", phase: .quitting(app: "Claude", waited: 8)))),
            Fixture(name: "06-switching-opening", model: model(boards(), job: SwitchJob(
                provider: .claude, target: grace, targetLabel: "grace@hopper.work", phase: .opening(app: "Claude")))),
            Fixture(name: "07-adding", model: model(boards(), job: SwitchJob(
                provider: .claude, target: nil, targetLabel: nil, phase: .swapping))),
            Fixture(name: "08-error", model: model(boards(), banner: Banner(
                kind: .error, text: "Claude did not quit, so nothing was changed. Quit it yourself, then switch again."))),
            Fixture(name: "09-success", model: model(boards(), banner: Banner(
                kind: .success, text: L.switched("Claude", "work")))),
            Fixture(name: "10-states-hover", model: model(boards(claude: edgeRows, claudeRunning: false, interrupted: true)),
                    staged: MenuView.Staged(hover: grace)),
            Fixture(name: "11-remove-confirm", model: model(boards()), staged: MenuView.Staged(confirmRemove: kat)),
            Fixture(name: "12-add-confirm", model: model(boards()), staged: MenuView.Staged(confirmAdd: true)),
            Fixture(name: "13-not-installed", model: model(boards(antigravityInstalled: false), selected: .antigravity)),

            Fixture(name: "20-settings-general", model: model(boards()), settings: .general, page: .init(openAtLogin: true)),
            Fixture(name: "21-settings-accounts", model: model(boards(claude: edgeRows)), settings: .accounts,
                    page: .init(hover: AccountsSettings.key(.claude, grace))),
            Fixture(name: "22-settings-accounts-ccsame", model: model(boards(), ccSame: found), settings: .accounts),
            Fixture(name: "23-settings-accounts-remove", model: model(boards(antigravityInstalled: false)), settings: .accounts,
                    page: .init(confirmRemove: AccountsSettings.key(.claude, kat))),
            Fixture(name: "27-settings-about", model: model(boards()), settings: .about),
        ]
    }
}

/// The Settings window as the system would frame it: a title bar and the toolbar tabs over the page.
private struct SettingsWindowStandIn: View {
    let model: AppModel
    let tab: SettingsTab
    let staged: SettingsPage.Staged

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { color in
                        Circle().fill(color.opacity(0.85)).frame(width: 12, height: 12)
                    }
                    Spacer()
                }
                .padding(.leading, 13)
                Text(tab.title)
                    .font(.headline)
            }
            .frame(height: 30)
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { t in
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol)
                            .font(.title3)
                            .frame(height: 22)
                        Text(t.title)
                            .font(.caption)
                    }
                    .foregroundStyle(t == tab ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(minWidth: 60)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
                    .background(t == tab ? Fill.card : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.bottom, 8)
            Divider()
            SettingsPage(model: model, tab: tab, staged: staged)
        }
    }
}

/// Made-up accounts, usage and quota for the fixtures.
@MainActor
struct Make {
    func claude(_ number: Int, _ id: String, _ email: String, alias: String? = nil, current: Bool = false, canSwitch: Bool = true,
                sitsOut: Bool = false, expired: Bool = false, savedDaysAgo: Double? = nil,
                usage numbers: (five: Int?, week: Int?, minutesAgo: Double)?) -> AccountRow {
        AccountRow(
            slot: Slot(number: number, account: id, email: email, alias: alias, disabled: sitsOut),
            isCurrent: current, canSwitch: canSwitch || current,
            setAsideAt: savedDaysAgo.map { Date().addingTimeInterval(-$0 * 86400) }, probablyExpired: expired,
            usage: numbers.map { PlanUsage(fiveHour: $0.five, weekly: $0.week, sampledAt: Date().addingTimeInterval(-$0.minutesAgo * 60)) })
    }

    func antigravity(_ number: Int, _ email: String, alias: String? = nil, current: Bool = false, quota: AntigravityQuota?) -> AccountRow {
        AccountRow(
            slot: Slot(number: number, account: email, email: email, alias: alias), isCurrent: current, canSwitch: true,
            setAsideAt: current ? nil : Date().addingTimeInterval(-9 * 86400), quota: quota)
    }

    func quota(plan: String, gemini: (Int, Int), claude: (Int, Int), argon: Int, resetHours: Double, minutesAgo: Double, problem: String? = nil) -> AntigravityQuota {
        func make(_ pool: QuotaBucket.Pool, _ used: Int, _ hours: Double) -> QuotaBucket {
            QuotaBucket(pool: pool, used: used, resetsAt: Date().addingTimeInterval(hours * 3600))
        }
        return AntigravityQuota(
            plan: plan,
            buckets: [
                make(.gemini5h, gemini.0, resetHours), make(.geminiWeekly, gemini.1, 90),
                make(.claude5h, claude.0, resetHours + 1), make(.claudeWeekly, claude.1, 90),
                make(.argonWeekly, argon, 90),
            ],
            fetchedAt: Date().addingTimeInterval(-minutesAgo * 60), problem: problem)
    }
}

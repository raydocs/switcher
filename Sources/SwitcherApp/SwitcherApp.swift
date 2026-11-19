import AppKit
import SwiftUI
import SwitcherCore

/// `--snapshot <dir>` draws the popover from fixed data into PNGs and exits, without ever building
/// the live model. Anything else starts the menu bar app.
@main
enum Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("usage: SwitcherApp --snapshot <dir>\n".utf8))
                exit(2)
            }
            exit(Snapshot.run(into: args[i + 1]))
        }
        SwitcherApp.main()
    }
}

struct SwitcherApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// One tool's active quota reading for the menu bar meter.
struct MenuBarReading: Equatable {
    var label: String
    var toolName: String
    var fiveUsed: Int?
    var weekUsed: Int?
    var tightestUsed: Int
}

/// The menu bar icon: the classic glyph, dual bars (5-hour over weekly), or bars + compact percent
/// for the tightest active account (Antigravity, Claude Code, or Codex) or a pinned tool.
struct MenuBarLabel: View {
    static let settingKey = "menuBarMeter"
    let model: AppModel

    var body: some View {
        let _ = model.language
        let mode = model.quotaDisplayMode
        if model.menuBarStyle != .icon, let r = Self.reading(for: model) {
            let shown = mode.shownPercent(used: r.tightestUsed)
            let a11y = mode == .used
                ? L.t("\(r.toolName) (\(r.label)): \(shown)% used", "\(r.toolName)（\(r.label)）：已用 \(shown)%")
                : L.t("\(r.toolName) (\(r.label)): \(shown)% left", "\(r.toolName)（\(r.label)）：剩余 \(shown)%")
            Group {
                switch model.menuBarStyle {
                case .icon:
                    Image(systemName: "person.2.circle")
                case .bars:
                    Image(nsImage: MeterIcon.image(five: r.fiveUsed, week: r.weekUsed, mode: mode, tight: r.tightestUsed >= 90))
                case .barsPercent:
                    HStack(spacing: 4) {
                        Image(nsImage: MeterIcon.image(five: r.fiveUsed, week: r.weekUsed, mode: mode, tight: r.tightestUsed >= 90))
                        Text(verbatim: "\(shown)%")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                    }
                }
            }
            .accessibilityLabel("Switcher")
            .accessibilityValue(a11y)
        } else {
            Image(systemName: "person.2.circle")
                .accessibilityLabel("Switcher")
        }
    }

    /// Computes the active menu bar reading from `model`, honoring `menuBarSource`.
    static func reading(for model: AppModel) -> MenuBarReading? {
        reading(
            boards: model.boards,
            cliBoards: model.cliBoards,
            source: model.menuBarSource,
            displayDesktop: { model.displayTabLabel($0) },
            displayCLI: { model.displayCLIActiveLabel($0) }
        )
    }

    static func reading(
        boards: [AppBoard],
        cliBoards: [CLIBoard],
        source: MenuBarSource,
        displayDesktop: (Slot) -> String,
        displayCLI: (CLIRow) -> String,
        now: Date = Date()
    ) -> MenuBarReading? {
        func antigravityReading() -> MenuBarReading? {
            guard let row = boards.first(where: { $0.provider == .antigravity })?.currentRow,
                  let quota = row.quota else { return nil }
            func activeUsed(_ pools: [QuotaBucket.Pool]) -> Int? {
                pools.compactMap { pool -> Int? in
                    guard let b = quota.bucket(pool) else { return nil }
                    if let reset = b.resetsAt, reset <= now { return nil }
                    return b.used
                }.max()
            }
            let five = activeUsed([.gemini5h, .claude5h])
            let week = activeUsed([.geminiWeekly, .claudeWeekly])
            guard five != nil || week != nil else { return nil }
            return MenuBarReading(
                label: displayDesktop(row.slot),
                toolName: "Antigravity",
                fiveUsed: five,
                weekUsed: week,
                tightestUsed: max(five ?? 0, week ?? 0)
            )
        }

        func cliReading(_ kind: CLIKind) -> MenuBarReading? {
            guard let active = cliBoards.first(where: { $0.kind == kind })?.active,
                  active.signIn.isGood,
                  active.headroom.status != .unknown,
                  let windows = active.quota?.windows else { return nil }
            func used(_ label: String) -> Int? { windows.first { $0.label == label }.map { Int($0.usedPercent.rounded()) } }
            let five = used("5h")
            let week = used("week")
            guard five != nil || week != nil else { return nil }
            let tightest = active.headroom.percentLeft.map { Int((100 - $0).rounded()) } ?? max(five ?? 0, week ?? 0)
            return MenuBarReading(
                label: displayCLI(active),
                toolName: kind.displayName,
                fiveUsed: five,
                weekUsed: week,
                tightestUsed: min(100, max(0, tightest))
            )
        }

        switch source {
        case .antigravity: return antigravityReading()
        case .claudeCode: return cliReading(.claude)
        case .codex: return cliReading(.codex)
        case .auto:
            return [antigravityReading(), cliReading(.claude), cliReading(.codex)]
                .compactMap { $0 }
                .max { $0.tightestUsed < $1.tightestUsed }
        }
    }
}

@MainActor
enum MeterIcon {
    private static var last: (key: String, image: NSImage)?

    /// Draws the dual menu bar bars (`five` and `week` are canonical used-percentages 0…100).
    static func image(five: Int?, week: Int?, mode: QuotaDisplayMode = .used, tight: Bool = false) -> NSImage {
        let fiveShown = five.map { mode.shownPercent(used: $0) }
        let weekShown = week.map { mode.shownPercent(used: $0) }
        let key = "\(fiveShown ?? -1)/\(weekShown ?? -1)/\(mode.rawValue)/\(tight ? 1 : 0)"
        if let last, last.key == key { return last.image }
        // Whole points throughout, so the bars are sharp at 1x as well as 2x.
        let size = NSSize(width: tight ? 22 : 20, height: 14)
        let barWidth: CGFloat = 18
        let image = NSImage(size: size, flipped: false) { _ in
            func bar(y: CGFloat, height: CGFloat, percent: Int?) {
                let track = NSRect(x: 1, y: y, width: barWidth, height: height)
                let radius = height / 2
                NSGraphicsContext.saveGraphicsState()
                defer { NSGraphicsContext.restoreGraphicsState() }
                NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).addClip()
                NSColor.black.withAlphaComponent(0.3).setFill()
                guard let percent else {
                    // No reading: a broken track, so it is not taken for an empty one.
                    for x in stride(from: track.minX, to: track.maxX, by: 5) {
                        NSRect(x: x, y: y, width: 3, height: height).fill()
                    }
                    return
                }
                track.fill()
                guard percent > 0 else { return }
                // Cut by the track's own shape, so a small level is a sliver and not a full dot.
                let w = max(2, track.width * CGFloat(min(percent, 100)) / 100)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX - height, y: y, width: w + height, height: height),
                             xRadius: radius, yRadius: radius).fill()
            }
            bar(y: 7, height: 5, percent: fiveShown)
            bar(y: 2, height: 3, percent: weekShown)
            if tight {
                // Crisp high-contrast dot in template ink so >=90% urgency reads even without color.
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 19.5, y: 10.5, width: 2.5, height: 2.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        // Named, so VoiceOver has something to say wherever it is drawn (the settings page too).
        image.accessibilityDescription = "Switcher"
        last = (key, image)
        return image
    }
}

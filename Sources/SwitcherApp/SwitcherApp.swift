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

/// The menu bar icon: the usual glyph, or two bars (5-hour over weekly) for the active terminal
/// account closest to its limit. The bars are one small template image, drawn again only when a
/// rounded percentage changes.
struct MenuBarLabel: View {
    static let settingKey = "menuBarMeter"
    let model: AppModel
    @AppStorage(settingKey) private var showMeter = true

    var body: some View {
        if showMeter, let (row, _, _) = Self.tightest(model.cliBoards) {
            Self.icon(model.cliBoards, meter: true)
                .accessibilityLabel("Switcher")
                .accessibilityValue(L.t("\(row.label): \(Int(row.headroom.percentLeft ?? 0))% left",
                                        "\(row.label)：剩余 \(Int(row.headroom.percentLeft ?? 0))%"))
        } else {
            Image(systemName: "person.2.circle")
        }
    }

    /// The menu bar icon as it stands: the two bars when they are on and there is a reading, else the app's own.
    /// The settings page draws it from here too, so its picture of the menu bar is the real one.
    static func icon(_ boards: [CLIBoard], meter: Bool) -> Image {
        guard meter, let (_, five, week) = tightest(boards) else { return Image(systemName: "person.2.circle") }
        return Image(nsImage: MeterIcon.image(five: five, week: week))
    }

    /// The active account (Claude Code or Codex) with the least room, and its two main windows.
    static func tightest(_ boards: [CLIBoard]) -> (CLIRow, Int?, Int?)? {
        let actives = boards.compactMap(\.active).filter { $0.headroom.status != .unknown }
        guard let row = actives.min(by: { ($0.headroom.percentLeft ?? 100) < ($1.headroom.percentLeft ?? 100) }),
              let windows = row.quota?.windows else { return nil }
        func used(_ label: String) -> Int? { windows.first { $0.label == label }.map { Int($0.usedPercent.rounded()) } }
        let five = used("5h"), week = used("week")
        if five == nil, week == nil { return nil }
        return (row, five, week)
    }
}

@MainActor
enum MeterIcon {
    private static var last: (key: String, image: NSImage)?

    static func image(five: Int?, week: Int?) -> NSImage {
        let key = "\(five ?? -1)/\(week ?? -1)"
        if let last, last.key == key { return last.image }
        // Whole points throughout, so the bars are sharp at 1x as well as 2x.
        let size = NSSize(width: 20, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            func bar(y: CGFloat, height: CGFloat, percent: Int?) {
                let track = NSRect(x: 1, y: y, width: size.width - 2, height: height)
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
            bar(y: 7, height: 5, percent: five)
            bar(y: 2, height: 3, percent: week)
            return true
        }
        image.isTemplate = true
        // Named, so VoiceOver has something to say wherever it is drawn (the settings page too).
        image.accessibilityDescription = "Switcher"
        last = (key, image)
        return image
    }
}

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
            Image(systemName: "person.2.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

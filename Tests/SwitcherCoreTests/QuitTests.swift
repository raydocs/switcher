import Foundation
import Testing
@testable import SwitcherCore

@Suite(.serialized) struct QuitTests {
    /// A fake app whose main program is not running but whose helper is (Antigravity's sidecars).
    @Test func helpersLeftAfterTheAppAreStopped() throws {
        // Under /var/folders on purpose: its /private must still match what the process list reports.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fake.app", isDirectory: true)
        let helperDir = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let helper = helperDir.appendingPathComponent("Fake Helper")
        // Built here: a copied system binary is killed at launch.
        let src = root.appendingPathComponent("helper.c")
        try Data("#include <unistd.h>\nint main(void) { sleep(120); return 0; }\n".utf8).write(to: src)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = [src.path, "-o", helper.path]
        try cc.run()
        cc.waitUntilExit()
        try #require(cc.terminationStatus == 0)

        let p = Process()
        p.executableURL = helper
        p.arguments = ["120"]
        try p.run()
        defer { if p.isRunning { p.terminate() } }

        let fake = MacApp(name: "Fake", bundleID: "dev.switcher.tests.none-\(UUID().uuidString)", fallbackPath: app.path)
        // Wait for the helper to show up in the process list.
        let seenBy = Date().addingTimeInterval(5)
        while !fake.isRunning, Date() < seenBy { usleep(50_000) }
        #expect(fake.isRunning)

        let start = Date()
        try fake.quit(timeout: 20, cancel: nil, waiting: nil)
        #expect(!fake.isRunning)
        #expect(Date().timeIntervalSince(start) < 15)
        p.waitUntilExit()
        #expect(p.terminationReason == .uncaughtSignal)
    }

    /// After an update the old helpers run on from a bundle that was deleted: only their name is left.
    @Test func helpersWhoseProgramWasDeletedAreStoppedToo() throws {
        let build = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build", isDirectory: true)
        let root = build.appendingPathComponent("quit-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fake.app", isDirectory: true)
        let helperDir = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let helper = helperDir.appendingPathComponent("Fake Helper")
        let src = root.appendingPathComponent("helper.c")
        try Data("#include <unistd.h>\nint main(void) { sleep(120); return 0; }\n".utf8).write(to: src)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = [src.path, "-o", helper.path]
        try cc.run()
        cc.waitUntilExit()
        try #require(cc.terminationStatus == 0)

        let p = Process()
        p.executableURL = helper
        p.arguments = ["120"]
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        usleep(200_000)
        try FileManager.default.removeItem(at: helper)

        let fake = MacApp(name: "Fake", bundleID: "dev.switcher.tests.none-\(UUID().uuidString)", fallbackPath: app.path)
        let listed = fake.processes() ?? []
        #expect(listed.contains { $0.pid == p.processIdentifier && $0.path.hasPrefix("?") })

        try fake.quit(timeout: 20, cancel: nil, waiting: nil)
        #expect(!fake.isRunning)
        p.waitUntilExit()
        #expect(p.terminationReason == .uncaughtSignal)
    }
}

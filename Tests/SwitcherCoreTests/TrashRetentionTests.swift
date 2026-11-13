import Foundation
import Testing
@testable import SwitcherCore

@Suite struct TrashRetentionTests {
    func age(_ url: URL, days: Double) throws {
        let date = Date(timeIntervalSinceNow: -days * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func recoverIfIdlePrunesOnlyTrashEntriesOlderThanFourteenDays() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let app = FakeApp()
        let c = Provider.claude(env: box.env, app: app, keychain: MemorySecrets())
        try c.switchTo(nil)   // Ada saved in the vault
        app.isRunning = false  // switching to nobody starts the app; recovery only runs while it is closed
        let trash = box.env.state.appendingPathComponent("trash", isDirectory: true)

        let old = trash.appendingPathComponent("old-bin"), fresh = trash.appendingPathComponent("fresh-bin")
        let edge = trash.appendingPathComponent("thirteen-days-bin")
        for bin in [old, fresh, edge] { box.write(bin.appendingPathComponent("claude-x/file"), "data") }
        // A loose old file in the trash is not a bin: left alone.
        let loose = trash.appendingPathComponent("loose-file")
        box.write(loose, "keep")
        // Old things outside the trash are never touched.
        let outside = box.env.state.appendingPathComponent("outside-old", isDirectory: true)
        box.write(outside.appendingPathComponent("file"), "keep")
        let savedAda = c.vault.dir(ADA)
        for url in [old, edge, loose, outside, savedAda] { try age(url, days: url == edge ? 13 : 30) }

        c.recoverIfIdle()

        #expect(!FS.exists(old))
        #expect(FS.exists(fresh))
        #expect(FS.exists(edge))
        #expect(FS.exists(loose))
        #expect(box.read(outside.appendingPathComponent("file")) == "keep")
        #expect(c.vault.isSaved(ADA))
    }

    @Test func noTrashFolderIsFine() throws {
        let box = Sandbox()
        let c = Provider.claude(env: box.env, app: FakeApp(), keychain: MemorySecrets())
        c.recoverIfIdle()
        #expect(!FS.exists(box.env.state.appendingPathComponent("trash")))
    }
}

import Foundation
import Testing
@testable import SwitcherCore

/// claude.ai's cached account, as V8 writes it into IndexedDB: one-byte strings tagged `"` + length.
private func v8Account(_ id: String, _ email: String) -> Data {
    func str(_ s: String) -> [UInt8] { [0x22, UInt8(s.utf8.count)] + Array(s.utf8) }
    var b: [UInt8] = [0x00, 0x6F, 0xFF, 0x0F] // leveldb / V8 noise before the object
    b += str("uuid") + str(id) + str("email_address") + str(email) + str("full_name") + str("Ada")
    b += [0x7B, 0x03, 0x00]
    return Data(b)
}

private func writeDB(_ dir: URL, _ name: String, _ data: Data) {
    let db = dir.appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.leveldb", isDirectory: true)
    try! FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
    try! data.write(to: db.appendingPathComponent(name))
}

@Suite struct WebEmailTests {
    @Test func readsTheCachedAccountEmail() {
        let box = Sandbox()
        writeDB(box.env.claudeData, "000003.log", v8Account(ADA, "ada@x.com"))
        #expect(ClaudeFiles.webEmails(box.env.claudeData) == [ADA.lowercased(): "ada@x.com"])
    }

    @Test func readsLargeValuesKeptAsBlobFiles() {
        let box = Sandbox()
        let blob = box.env.claudeData.appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.blob/1/00", isDirectory: true)
        try! FileManager.default.createDirectory(at: blob, withIntermediateDirectories: true)
        try! (Data(repeating: 0x41, count: 4096) + v8Account(ADA, "ada@x.com")).write(to: blob.appendingPathComponent("52"))
        #expect(ClaudeFiles.webEmails(box.env.claudeData) == [ADA.lowercased(): "ada@x.com"])
    }

    @Test func theLogWinsOverOlderTables() {
        let box = Sandbox()
        writeDB(box.env.claudeData, "000005.ldb", v8Account(ADA, "old@x.com"))
        writeDB(box.env.claudeData, "000006.log", v8Account(ADA, "new@x.com"))
        #expect(ClaudeFiles.webEmails(box.env.claudeData)[ADA.lowercased()] == "new@x.com")
    }

    @Test func ignoresWhatIsNotAnEmail() {
        let box = Sandbox()
        var junk = v8Account(ADA, "not an email")
        junk.append(v8Account("not-a-uuid-not-a-uuid-not-a-uuid-xxx", "x@y.com"))
        writeDB(box.env.claudeData, "000003.log", junk)
        #expect(ClaudeFiles.webEmails(box.env.claudeData).isEmpty)
        #expect(ClaudeFiles.webEmails(box.root.appendingPathComponent("missing")).isEmpty)
    }

    @Test func fillsMissingEmailsForTheOpenAndSavedAccounts() throws {
        let box = Sandbox()
        box.write(box.env.claudeConfig, box.claudeConfig(account: ADA))
        writeDB(box.env.claudeData, "000003.log", v8Account(ADA, "ada@x.com"))
        let saved = box.env.vault(.claude).appendingPathComponent(GRACE, isDirectory: true)
        box.write(saved.appendingPathComponent("config.json"), "{\n  \"lastKnownAccountUuid\": \"\(GRACE)\"\n}")
        box.write(saved.appendingPathComponent("about.json"), #"{"account":"\#(GRACE)","setAsideAt":1790000000}"#)
        writeDB(saved, "000003.log", v8Account(GRACE, "grace@x.com"))
        let board = Switchboard(env: box.env, claude: .claude(env: box.env, app: FakeApp(), keychain: MemorySecrets()), antigravity: .antigravity(env: box.env, app: FakeApp(), keychain: MemorySecrets()))
        let roster = board.noteSignedIn()
        #expect(roster.slot(.claude, ADA)?.email == "ada@x.com")
        #expect(roster.slot(.claude, GRACE)?.email == "grace@x.com")
    }
}

@Suite struct SlotLabelTests {
    @Test func theEmailIsTheNameAnAliasOnlyStandsIn() {
        var slot = Slot(number: 1, account: ADA, email: nil, addedAt: 0)
        #expect(slot.label == "Account \(ADA.prefix(8))")
        slot.alias = "home"
        #expect(slot.label == "home")
        slot.email = "ada@x.com"
        #expect(slot.label == "ada@x.com")
    }
}

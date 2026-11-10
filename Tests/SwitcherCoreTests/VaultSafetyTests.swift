import Foundation
import Testing
@testable import SwitcherCore

/// Regression tests for the sign-in vault review (round 1).
@Suite struct VaultSafetyTests {
    func claude(_ box: Sandbox) -> Provider { .claude(env: box.env, app: FakeApp(), keychain: MemorySecrets()) }

    /// F1: a failure writing the commit leaves everything as it was.
    @Test func f1_failureWritingTheCommitIsUndone() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let c = claude(box)
        try c.switchTo(nil)
        box.claudeSignIn(GRACE)
        let config = box.read(box.env.claudeConfig)
        c.vault.faultBeforeCommit = { throw SwitcherError.message("disk full") }
        #expect(throws: (any Error).self) { try c.switchTo(ADA) }
        #expect(box.claudeOwner() == GRACE)
        #expect(box.read(box.env.claudeConfig) == config)
        #expect(c.vault.isSaved(ADA))
        #expect(!c.vault.hasInterruptedSwap)
    }

    /// F2: a journal that can't be read stops recovery and is kept, with everything it points at.
    @Test func f2_unreadableJournalIsKeptAndRecoveryStops() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let c = claude(box)
        try FS.makePrivateDir(c.vault.stage)
        try FS.move(box.env.claudeData.appendingPathComponent("Cookies"), to: c.vault.stage.appendingPathComponent("Cookies"))
        box.write(c.vault.journalURL, "{ garbled")
        #expect(throws: (any Error).self) { try c.vault.recover() }
        #expect(FS.exists(c.vault.journalURL))
        #expect(box.read(c.vault.stage.appendingPathComponent("Cookies")) == "cookies-\(ADA)")
        #expect(throws: (any Error).self) { try c.switchTo(nil) }
    }

    /// F3: removing an account waits for the switch lock and refuses while a switch is unfinished.
    @Test func f3_removeTakesTheSwitchLock() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let board = Switchboard(env: box.env, claude: claude(box), antigravity: .antigravity(env: box.env, app: FakeApp(), keychain: MemorySecrets()))
        try board.switchTo(.claude, account: nil)
        box.claudeSignIn(GRACE)
        let held = try FileLock(board.claude.lockURL, timeout: 1)
        #expect(throws: (any Error).self) { try board.remove(.claude, account: ADA, lockTimeout: 0.2) }
        #expect(board.claude.vault.isSaved(ADA))
        withExtendedLifetime(held) {}
    }

    @Test func f3_removeRefusesDuringAnInterruptedSwitch() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let board = Switchboard(env: box.env, claude: claude(box), antigravity: .antigravity(env: box.env, app: FakeApp(), keychain: MemorySecrets()))
        try board.switchTo(.claude, account: nil)
        box.claudeSignIn(GRACE)
        box.write(board.claude.vault.journalURL, #"{"to":"\#(ADA)","moves":[],"backups":[],"stashed":{},"committed":false}"#)
        #expect(throws: (any Error).self) { try board.remove(.claude, account: ADA, lockTimeout: 1) }
        #expect(board.claude.vault.isSaved(ADA))
    }

    /// F4: credentials whose account can't be told are never dropped.
    @Test func f4_unidentifiableAntigravityCredentialsAreKept() throws {
        let box = Sandbox()
        let keychain = MemorySecrets()
        try keychain.set(service: "gemini", account: "antigravity", value: "go-keyring-base64:" + Data(#"{"token":{"refresh_token":"r"}}"#.utf8).base64EncodedString())
        let ag = Provider.antigravity(env: box.env, app: FakeApp(), keychain: keychain)
        #expect(ag.current() == nil)
        #expect(throws: (any Error).self) { try ag.switchTo(nil) }
        #expect(try keychain.get(service: "gemini", account: "antigravity") != nil)
    }

    /// F6: the import holds cc-same's lock, so it can't run while cc-same is mid-switch.
    @Test func f6_importWaitsForCCSameLock() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let logins = box.env.ccSame.appendingPathComponent("logins")
        box.write(logins.appendingPathComponent("\(GRACE)/Cookies"), "c")
        box.write(logins.appendingPathComponent("\(GRACE)/config.json"), "{}")
        let held = try FileLock(box.env.ccSame.appendingPathComponent("lock"), timeout: 1)
        let c = claude(box)
        #expect(throws: (any Error).self) { try CCSameImport.run(box.env, vault: c.vault, currentClaude: ADA, running: { false }, lockTimeout: 0.2) }
        #expect(FS.exists(logins.appendingPathComponent(GRACE)))
        withExtendedLifetime(held) {}
    }

    /// F7: members the swap doesn't own keep their exact bytes, spacing included.
    @Test func f7_otherMembersKeepTheirBytes() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let odd = "{\n\t\"locale\"\t:\t\"en-US\" ,\n\t\"oauth:tokenCache\": \"tok\",\n\t\"lastKnownAccountUuid\": \"\(ADA)\",\n\t\"untouched\"\t:\t1.50\n}"
        box.write(box.env.claudeConfig, odd)
        let c = claude(box)
        try c.switchTo(nil)
        #expect(box.read(box.env.claudeConfig) == "{\n\t\"locale\"\t:\t\"en-US\" ,\n\t\"untouched\"\t:\t1.50\n}")
        box.claudeSignIn(GRACE)
        box.write(box.env.claudeConfig, "{\n\t\"untouched\"\t:\t1.50,\n\t\"oauth:tokenCache\": \"tok-g\",\n\t\"lastKnownAccountUuid\": \"\(GRACE)\"\n}")
        try c.switchTo(ADA)
        #expect(box.read(box.env.claudeConfig) == "{\n\t\"untouched\"\t:\t1.50,\n\t\"oauth:tokenCache\": \"tok\",\n\t\"lastKnownAccountUuid\": \"\(ADA)\"\n}")
    }
}

@Suite struct OrderedJSONEditTests {
    /// Round 2: removing a member never changes the whitespace of the ones kept.
    @Test func removalKeepsTheNeighboursIndentation() throws {
        let mixed = "{\n  \"oauth:tokenCache\": \"t\",\n\t\"keep\": 1,\n    \"lastKnownAccountUuid\": \"u\",\n \"also\": 2\n}"
        #expect(try OrderedJSON.edit(mixed, removing: ["oauth:tokenCache"], adding: []) == "{\n\t\"keep\": 1,\n    \"lastKnownAccountUuid\": \"u\",\n \"also\": 2\n}")
        #expect(try OrderedJSON.edit(mixed, removing: ["lastKnownAccountUuid"], adding: []) == "{\n  \"oauth:tokenCache\": \"t\",\n\t\"keep\": 1,\n \"also\": 2\n}")
        #expect(try OrderedJSON.edit(mixed, removing: ["oauth:tokenCache", "lastKnownAccountUuid"], adding: []) == "{\n\t\"keep\": 1,\n \"also\": 2\n}")
    }

    @Test func editsLeaveEverythingElse() throws {
        #expect(try OrderedJSON.edit("{\"a\": 1}", removing: ["a"], adding: []) == "{}")
        #expect(try OrderedJSON.edit("{}", removing: [], adding: [.init(key: "k", raw: "2")]) == "{\n  \"k\": 2\n}")
        #expect(try OrderedJSON.edit("{\n  \"a\": 1,\n  \"b\": 2\n}\n", removing: ["a"], adding: []) == "{\n  \"b\": 2\n}\n")
        #expect(try OrderedJSON.edit("{\n  \"a\": 1,\n  \"b\": 2\n}", removing: ["b"], adding: [.init(key: "c", raw: "[1]")]) == "{\n  \"a\": 1,\n  \"c\": [1]\n}")
    }
}

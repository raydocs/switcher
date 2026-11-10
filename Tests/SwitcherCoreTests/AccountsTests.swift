import Foundation
import Testing
@testable import SwitcherCore

let ORG_A = "00000000-0000-4000-8000-00000000000a"
let ORG_TEAM = "00000000-0000-4000-8000-00000000000b"

@Suite struct RosterTests {
    @Test func numbersAliasesAndNext() throws {
        var r = Roster()
        r.join(.claude, account: "a", email: "a@x.com")
        r.join(.claude, account: "b", email: nil)
        r.join(.claude, account: "c", email: "c@x.com")
        #expect(r.slots(.claude).map(\.number) == [1, 2, 3])
        r.remove(.claude, "b")
        r.join(.claude, account: "d", email: nil)
        #expect(r.slot(.claude, "d")?.number == 2) // the free number is reused

        try r.setAlias(.claude, "c", "Work")
        #expect(r.resolve(.claude, "work")?.account == "c")
        #expect(r.resolve(.claude, "1")?.account == "a")
        #expect(r.resolve(.claude, "A@X.com")?.account == "a")
        #expect(throws: (any Error).self) { try r.setAlias(.claude, "a", "123") }
        #expect(throws: (any Error).self) { try r.setAlias(.claude, "a", "work") }

        try r.move(.claude, "c", to: 1)
        #expect(r.slots(.claude).map(\.account) == ["c", "d", "a"])

        // Next goes round the list, skipping the one in use and those sitting out.
        r.setDisabled(.claude, "d", true)
        #expect(r.next(.claude, after: "c") { _ in true }?.account == "a")
        #expect(r.next(.claude, after: "a") { _ in true }?.account == "c")
        #expect(r.next(.claude, after: "a") { $0.account != "c" } == nil)
        // Antigravity's list is separate.
        #expect(r.slots(.antigravity).isEmpty)
    }
}

@Suite struct UsageTests {
    @Test func attributesSamplesByOrganization() throws {
        let box = Sandbox()
        for (acct, org) in [(ADA, ORG_A), (ADA, ORG_TEAM), (GRACE, ORG_TEAM)] {
            try FileManager.default.createDirectory(at: box.env.claudeSessions.appendingPathComponent("\(acct)/\(org)"), withIntermediateDirectories: true)
        }
        let now = Date()
        let ms = { (ago: TimeInterval) in Int((now.timeIntervalSince1970 - ago) * 1000) }
        box.write(box.env.claudeUsageHistory, """
        {"version":2,"samples":[
          {"t":\(ms(7200)),"org":"\(ORG_A)","u":{"fh":10,"sd":40}},
          {"t":\(ms(60)),"org":"\(ORG_A)","u":{"fh":12.4,"sd":41}},
          {"t":\(ms(30)),"org":"\(ORG_TEAM)","u":{"fh":99,"sd":99}}
        ]}
        """)
        let usage = ClaudeUsage.latest(box.env, roster: Roster(), now: now)
        #expect(usage[ADA]?.fiveHour == 12)
        #expect(usage[ADA]?.weekly == 41)
        // A team organization both use is not guessed.
        #expect(usage[GRACE] == nil)
    }

    @Test func oldReadingsAge() throws {
        let box = Sandbox()
        try FileManager.default.createDirectory(at: box.env.claudeSessions.appendingPathComponent("\(ADA)/\(ORG_A)"), withIntermediateDirectories: true)
        let now = Date()
        let t = Int((now.timeIntervalSince1970 - 6 * 3600) * 1000)
        box.write(box.env.claudeUsageHistory, #"{"version":2,"samples":[{"t":\#(t),"org":"\#(ORG_A)","u":{"fh":80,"sd":50}}]}"#)
        let u = ClaudeUsage.latest(box.env, roster: Roster(), now: now)[ADA]
        #expect(u?.fiveHour == 0) // that 5-hour window has started over
        #expect(u?.weekly == 50)
        #expect(u?.isStale(now: now) == true)
    }
}

@Suite struct CCSameImportTests {
    @Test func movesSavedSignInsAndKeepsTheList() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let logins = box.env.ccSame.appendingPathComponent("logins")
        box.write(logins.appendingPathComponent("\(GRACE)/Cookies"), "cookies-\(GRACE)")
        box.write(logins.appendingPathComponent("\(GRACE)/config.json"), "{\n  \"oauth:tokenCache\": \"tok-g\",\n  \"lastKnownAccountUuid\": \"\(GRACE)\"\n}")
        box.write(logins.appendingPathComponent("\(GRACE)/about.json"), #"{"account":"\#(GRACE)","email":"grace@x.com","setAsideAt":1790000000}"#)
        // A stale copy of the account in use stays where it is.
        box.write(logins.appendingPathComponent("\(ADA)/config.json"), "{}")
        box.write(box.env.ccSame.appendingPathComponent("accounts.json"), """
        {"version":1,"slots":[
          {"number":1,"account":"\(GRACE)","email":"grace@x.com","alias":"home","disabled":false,"addedAt":1,"orgs":["\(ORG_A)"]},
          {"number":2,"account":"\(ADA)","email":"ada@x.com","alias":null,"disabled":true,"addedAt":2,"orgs":[]}
        ]}
        """)
        var board = Switchboard(env: box.env, claude: .claude(env: box.env, app: FakeApp(), keychain: MemorySecrets()), antigravity: .antigravity(env: box.env, app: FakeApp(), keychain: MemorySecrets()))
        board.ccSameRunning = { false }
        let found = board.ccSameImport()
        #expect(found?.logins == [GRACE])
        #expect(found?.slots == 2)

        let result = try board.importCCSame()
        #expect(result == .init(accounts: 2, logins: 1))
        let roster = Roster.load(box.env)
        #expect(roster.slot(.claude, GRACE)?.number == 1)
        #expect(roster.slot(.claude, GRACE)?.alias == "home")
        #expect(roster.slot(.claude, GRACE)?.orgs == [ORG_A])
        #expect(roster.slot(.claude, ADA)?.number == 2)
        #expect(roster.slot(.claude, ADA)?.disabled == true)
        #expect(board.claude.vault.isSaved(GRACE))
        #expect(!FS.exists(logins.appendingPathComponent(GRACE)))
        #expect(FS.exists(logins.appendingPathComponent(ADA)))

        // And it switches like any other saved sign-in.
        try board.switchTo(.claude, account: GRACE)
        #expect(box.claudeOwner() == GRACE)
        let rows = board.board().first { $0.provider == .claude }!.rows
        #expect(rows.first { $0.isCurrent }?.slot.account == GRACE)
        #expect(rows.first { $0.slot.account == ADA }?.canSwitch == true)
    }
}

@Suite struct CCSameImportDoneTests {
    @Test func nothingLeftToOfferAfterImport() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        box.write(box.env.ccSame.appendingPathComponent("accounts.json"), #"{"version":1,"slots":[{"number":1,"account":"\#(ADA)","email":null,"alias":null,"disabled":false,"addedAt":1,"orgs":[]}]}"#)
        #expect(CCSameImport.find(box.env, currentClaude: ADA, running: { false }) == nil)
    }
}

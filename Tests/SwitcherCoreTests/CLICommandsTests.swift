import Foundation
import Testing
@testable import SwitcherCore

/// `switcher cli …` helpers, on a temporary HOME only.
@Suite struct CLICommandsTests {
    func tempHome() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cli-cmds-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func cliNamesAndAliases() {
        #expect(CLICommands.kind("claude") == .claude)
        #expect(CLICommands.kind("CC") == .claude)
        #expect(CLICommands.kind("codex") == .codex)
        #expect(CLICommands.kind("co") == .codex)
        #expect(CLICommands.kind("gemini") == nil)
        #expect(CLICommands.kind(nil) == nil)
    }

    @Test func whoIsNumberNameOrDefault() throws {
        let home = try tempHome()
        let profiles = CLIProfiles(env: CLIEnv(home: home))
        try profiles.add(.claude, name: "work")
        try profiles.add(.claude, name: "alt")
        #expect(try CLICommands.profile(profiles, .claude, "1").isDefault)
        #expect(try CLICommands.profile(profiles, .claude, "default").isDefault)
        #expect(try CLICommands.profile(profiles, .claude, "2").name == "alt")
        #expect(try CLICommands.profile(profiles, .claude, "work").name == "work")
        #expect(throws: (any Error).self) { try CLICommands.profile(profiles, .claude, "9") }
        #expect(throws: (any Error).self) { try CLICommands.profile(profiles, .codex, "work") }
    }

    @Test func execArguments() throws {
        #expect(try CLICommands.parseExec(["cc", "2"]) == .init(kind: .claude, who: "2", command: []))
        #expect(try CLICommands.parseExec(["codex", "work", "--", "/usr/bin/env", "-0"])
            == .init(kind: .codex, who: "work", command: ["/usr/bin/env", "-0"]))
        // A second `--` belongs to the command.
        #expect(try CLICommands.parseExec(["co", "default", "--", "git", "log", "--", "file"]).command == ["git", "log", "--", "file"])
        #expect(try CLICommands.parseExec(["cc", "1"]).command.isEmpty)
        #expect(throws: (any Error).self) { try CLICommands.parseExec([]) }
        #expect(throws: (any Error).self) { try CLICommands.parseExec(["gemini", "1"]) }
        #expect(throws: (any Error).self) { try CLICommands.parseExec(["claude"]) }
        #expect(throws: (any Error).self) { try CLICommands.parseExec(["claude", "1", "ls"]) }
        #expect(throws: (any Error).self) { try CLICommands.parseExec(["claude", "1", "--"]) }
    }

    @Test func execEnvironment() throws {
        let home = try tempHome()
        let profiles = CLIProfiles(env: CLIEnv(home: home))
        let work = try profiles.add(.claude, name: "work")
        let base = ["PATH": "/usr/bin", "SWITCHER_BYPASS": "1", "CLAUDE_CONFIG_DIR": "/somewhere/else"]

        let a = CLICommands.environment(base: base, profile: work)
        #expect(a["CLAUDE_CONFIG_DIR"] == work.path)
        #expect(a["SWITCHER_BYPASS"] == nil)
        #expect(a["PATH"] == "/usr/bin")

        // The default account leaves the variable unset (never ~/.claude) and keeps a shim reached
        // by the command from picking the pointer's account again.
        let b = CLICommands.environment(base: base, profile: profiles.defaultProfile(.claude))
        #expect(b["CLAUDE_CONFIG_DIR"] == nil)
        #expect(b["SWITCHER_BYPASS"] == "1")

        // Codex uses its own variable and leaves Claude's alone.
        let codex = try profiles.add(.codex, name: "alt")
        let c = CLICommands.environment(base: base, profile: codex)
        #expect(c["CODEX_HOME"] == codex.path)
        #expect(c["CLAUDE_CONFIG_DIR"] == "/somewhere/else")
    }

    @Test func rcFilesOnlyIncludeBashrcWhenItExists() throws {
        let home = try tempHome()
        let env = CLIEnv(home: home)
        #expect(CLICommands.rcFiles(env) == [home + "/.zshrc"])
        FileManager.default.createFile(atPath: home + "/.bashrc", contents: Data())
        #expect(CLICommands.rcFiles(env) == [home + "/.zshrc", home + "/.bashrc"])
    }

    @Test func listShowsActiveIdentityAndSignInWithoutTokens() throws {
        let home = try tempHome()
        let env = CLIEnv(home: home)
        let profiles = CLIProfiles(env: env)
        let work = try profiles.add(.claude, name: "work")
        try profiles.setActive(work)

        // Codex default signed in (ChatGPT), with a plan in the id token.
        let claims = #"{"email":"ada@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}"#
        let jwt = "x." + Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".y"
        try FileManager.default.createDirectory(atPath: env.defaultFolder(.codex), withIntermediateDirectories: true)
        let auth = #"{"auth_mode":"chatgpt","tokens":{"id_token":"\#(jwt)","refresh_token":"SECRET-REFRESH","access_token":"SECRET-ACCESS"}}"#
        try Data(auth.utf8).write(to: URL(fileURLWithPath: env.defaultFolder(.codex) + "/auth.json"))

        // Claude work: signed in through the plaintext fallback, good until a known date.
        let expires = 1_900_000_000_000.0
        let creds = #"{"claudeAiOauth":{"accessToken":"SECRET-TOKEN","expiresAt":\#(expires),"refreshTokenExpiresAt":\#(expires),"subscriptionType":"max"}}"#
        try Data(creds.utf8).write(to: URL(fileURLWithPath: work.path + "/.credentials.json"))
        try Data(#"{"oauthAccount":{"emailAddress":"grace@example.com"}}"#.utf8).write(to: URL(fileURLWithPath: work.path + "/.claude.json"))

        let groups = CLICommands.list(profiles, keychain: MemoryCLIKeychain())
        #expect(groups.map(\.cli) == ["claude", "codex"])
        let claude = groups[0].profiles
        #expect(claude.map(\.name) == ["default", "work"])
        #expect(claude.map(\.active) == [false, true])
        #expect(claude[1].email == "grace@example.com")
        #expect(claude[1].plan == "max")
        #expect(claude[1].signIn == "signedIn")
        #expect(claude[1].signInGoodUntil == Date(timeIntervalSince1970: expires / 1000))
        #expect(claude[1].line().contains("sign-in good until"))
        #expect(claude[0].signIn == "signedOut")
        #expect(claude[0].line().contains("not signed in → "))
        #expect(claude[0].line().contains("claude"))
        #expect(!groups[0].shimInstalled)

        let codex = groups[1].profiles
        #expect(codex.count == 1)
        #expect(codex[0].active)
        #expect(codex[0].email == "ada@example.com")
        #expect(codex[0].plan == "plus")
        #expect(codex[0].signIn == "signedIn")

        let json = try CLICommands.listJSON(groups)
        #expect(json.contains("grace@example.com"))
        #expect(json.contains("\"signInGoodUntil\""))
        #expect(!json.contains("SECRET"))
        #expect(!CLICommands.list(profiles, keychain: MemoryCLIKeychain()).flatMap { $0.profiles }.map { $0.line() }.joined().contains("SECRET"))
    }
}

import Foundation
import Testing
@testable import SwitcherCore

/// `switcher cli …` helpers, on a temporary HOME only.
@Suite struct CLICommandsTests {
    @Test func cliNamesAndAliases() {
        #expect(CLICommands.kind("claude") == .claude)
        #expect(CLICommands.kind("CC") == .claude)
        #expect(CLICommands.kind("codex") == .codex)
        #expect(CLICommands.kind("co") == .codex)
        #expect(CLICommands.kind("agy") == .agy)
        #expect(CLICommands.kind("antigravity") == .agy)
        #expect(CLICommands.kind("gemini") == nil)
        #expect(CLICommands.kind(nil) == nil)
    }

    @Test func whoIsNumberNameEmailOrDefault() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let kc = MemoryCLIKeychain()
        try profiles.add(.claude, name: "work")
        try profiles.add(.claude, name: "alt")
        #expect(try CLICommands.profile(profiles, .claude, "1", keychain: kc).isDefault)
        #expect(try CLICommands.profile(profiles, .claude, "default", keychain: kc).isDefault)
        #expect(try CLICommands.profile(profiles, .claude, "2", keychain: kc).name == "alt")
        #expect(try CLICommands.profile(profiles, .claude, "work", keychain: kc).name == "work")
        #expect(throws: (any Error).self) { try CLICommands.profile(profiles, .claude, "9", keychain: kc) }
        #expect(throws: (any Error).self) { try CLICommands.profile(profiles, .codex, "work", keychain: kc) }

        kc.items["gemini/antigravity"] = box.json(["token": ["refresh_token": "r"], "id_token_email": "agy@example.com"])
        #expect(try CLICommands.profile(profiles, .agy, "agy@example.com", keychain: kc).isDefault)
    }

    @Test func execArguments() throws {
        #expect(try CLICommands.parseExec(["cc", "2"]) == .init(kind: .claude, who: "2", command: []))
        #expect(try CLICommands.parseExec(["agy", "1"]) == .init(kind: .agy, who: "1", command: []))
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
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let work = try profiles.add(.claude, name: "work")
        let base = ["PATH": "/usr/bin", "SWITCHER_BYPASS": "1", "CLAUDE_CONFIG_DIR": "/somewhere/else", "ANTIGRAVITY_GEMINI_DIR": "/old"]

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

        let agy = try profiles.add(.agy, name: "alt")
        let d = CLICommands.environment(base: base, profile: agy)
        #expect(d["ANTIGRAVITY_GEMINI_DIR"] == agy.path)
        let e = CLICommands.environment(base: base, profile: profiles.defaultProfile(.agy))
        #expect(e["ANTIGRAVITY_GEMINI_DIR"] == nil && e["SWITCHER_BYPASS"] == "1")
    }

    @Test func rcFilesOnlyIncludeBashrcWhenItExists() throws {
        let box = CLIBox()
        let env = box.env
        #expect(CLICommands.rcFiles(env) == [box.home + "/.zshrc"])
        FileManager.default.createFile(atPath: box.home + "/.bashrc", contents: Data())
        #expect(CLICommands.rcFiles(env) == [box.home + "/.zshrc", box.home + "/.bashrc"])
    }

    @Test func listShowsActiveIdentityAndSignInWithoutTokens() throws {
        let box = CLIBox()
        let env = box.env
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

        let kc = MemoryCLIKeychain()
        kc.items["gemini/antigravity"] = box.json(["token": ["refresh_token": "SECRET-AGY"], "id_token_email": "alan@example.com"])

        let groups = CLICommands.list(profiles, keychain: kc)
        #expect(groups.map(\.cli) == ["claude", "codex", "agy"])
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

        let agy = groups[2].profiles
        #expect(agy.count == 1 && agy[0].email == "alan@example.com" && agy[0].signIn == "signedIn")

        let json = try CLICommands.listJSON(groups)
        #expect(json.contains("grace@example.com"))
        #expect(json.contains("\"signInGoodUntil\""))
        #expect(!json.contains("SECRET"))
        #expect(!CLICommands.list(profiles, keychain: kc).flatMap { $0.profiles }.map { $0.line() }.joined().contains("SECRET"))
    }
}

/// Runs the compiled `switcher` CLI in a sandboxed HOME with `SWITCHER_NO_KEYCHAIN=1`.
@Suite struct CLIBinaryIntegrationTests {
    static var switcherBinary: String? {
        let nextToBundle = Bundle(for: CLIBox.self).bundleURL.deletingLastPathComponent().appendingPathComponent("switcher").path
        if FileManager.default.isExecutableFile(atPath: nextToBundle) { return nextToBundle }
        let debug = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/switcher").path
        return FileManager.default.isExecutableFile(atPath: debug) ? debug : nil
    }

    func run(_ box: CLIBox, _ args: [String], extraPath: String? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let exe = try #require(Self.switcherBinary)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: box.home)
        p.environment = [
            "HOME": box.home,
            "PATH": (extraPath.map { $0 + ":" } ?? "") + "/usr/bin:/bin",
            "SWITCHER_NO_KEYCHAIN": "1",
            "SWITCHER_NO_FALLBACK_PATH": "1",
        ]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    @Test(.enabled(if: CLIBinaryIntegrationTests.switcherBinary != nil))
    func usageFlagsHelpAndInvalidCLIValidation() throws {
        let box = CLIBox()
        let help = try run(box, ["cli", "usage", "--help"])
        #expect(help.status == 0 && help.stdout.contains("switcher cli usage"))

        // Flag-order independent --cached / --json.
        let r1 = try run(box, ["cli", "usage", "--cached", "--json", "claude"])
        let r2 = try run(box, ["cli", "usage", "claude", "--json", "--cached"])
        #expect(r1.status == 0 && r2.status == 0)
        #expect(r1.stdout.contains("\"cli\" : \"claude\""))

        // Invalid CLI name or unknown flag fails instead of silently showing every CLI.
        let badCLI = try run(box, ["cli", "usage", "--cached", "--json", "typo"])
        #expect(badCLI.status != 0 && badCLI.stderr.contains("say which CLI: claude, codex or agy"))
        let badFlag = try run(box, ["cli", "usage", "--cached", "--bogus"])
        #expect(badFlag.status != 0 && badFlag.stderr.contains("unknown option"))
    }

    @Test(.enabled(if: CLIBinaryIntegrationTests.switcherBinary != nil))
    func addLoginRollbackAndAtomicUninstall() throws {
        let box = CLIBox()
        let add = try run(box, ["cli", "add", "agy", "work"])
        #expect(add.status == 0)
        #expect(FS.exists(URL(fileURLWithPath: box.home + "/.agy-profiles/work/antigravity-cli/cache/antigravity-keyring-unavailable")))

        // --rollback-if-unsigned deletes a newly added unsigned profile when login fails.
        box.write(box.top + "/bin/agy", "#!/bin/sh\nexit 2\n", mode: 0o755)
        let login = try run(box, ["cli", "login", "--rollback-if-unsigned", "agy", "work"], extraPath: box.top + "/bin")
        #expect(login.status != 0)
        #expect(!FS.exists(URL(fileURLWithPath: box.home + "/.agy-profiles/work")))

        // All-or-nothing uninstall: broken .bashrc prevents .zshrc or shims from being removed first.
        box.fakeBinary(box.top + "/bin/claude")
        let inst = try run(box, ["cli", "install"], extraPath: box.top + "/bin")
        #expect(inst.status == 0)
        let zshBefore = try #require(box.read(box.home + "/.zshrc"))
        box.write(box.home + "/.bashrc", CLIShim.rcBegin + "\n")
        let uninst = try run(box, ["cli", "uninstall"])
        #expect(uninst.status != 0)
        #expect(box.read(box.home + "/.zshrc") == zshBefore)
        #expect(FS.exists(URL(fileURLWithPath: box.env.shim(.claude))))
    }

    @Test(.enabled(if: CLIBinaryIntegrationTests.switcherBinary != nil))
    func agyIsolationAndReloginPromotionFailuresFailClosedInCLI() throws {
        let box = CLIBox()
        let add = try run(box, ["cli", "add", "agy", "work"])
        #expect(add.status == 0)
        let workDir = box.home + "/.agy-profiles/work"

        // Re-login where child exits 0 without writing staged token fails despite old token on disk.
        box.write(workDir + "/antigravity-cli/antigravity-oauth-token",
                  box.json(["token": ["refresh_token": "r-old"], "id_token_email": "old@example.com"]), mode: 0o600)
        box.write(box.top + "/bin/agy", "#!/bin/sh\nexit 0\n", mode: 0o755)
        let relogin = try run(box, ["cli", "login", "agy", "work"], extraPath: box.top + "/bin")
        #expect(relogin.status != 0)
        #expect(relogin.stdout.contains("Sign-in was not updated"))

        // Broken isolation (cache replaced with a symlink) blocks both `use` and `exec` without moving pointer.
        try FileManager.default.removeItem(atPath: workDir + "/antigravity-cli/cache")
        box.mkdir(box.top + "/outside")
        box.symlink(workDir + "/antigravity-cli/cache", to: box.top + "/outside")
        let useRes = try run(box, ["cli", "use", "agy", "work"])
        #expect(useRes.status != 0)
        #expect(CLIProfiles(env: box.env).active(.agy).isDefault)
        let execRes = try run(box, ["cli", "exec", "agy", "work", "--", "/usr/bin/true"])
        #expect(execRes.status != 0)
    }
}

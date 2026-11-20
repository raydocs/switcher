import Darwin
import Foundation
import Testing
@testable import SwitcherCore

@Suite struct AntigravitySandboxesTests {
    @Test func validatesNamesAndSuggestsNextFreeName() throws {
        #expect(AntigravitySandboxes.isValidName("acc2"))
        #expect(AntigravitySandboxes.isValidName("work-1.dev_a"))
        #expect(!AntigravitySandboxes.isValidName(""))
        #expect(!AntigravitySandboxes.isValidName("default"))
        #expect(!AntigravitySandboxes.isValidName("main"))
        #expect(!AntigravitySandboxes.isValidName(".hidden"))
        #expect(!AntigravitySandboxes.isValidName("-flag"))
        #expect(!AntigravitySandboxes.isValidName("has space"))
        #expect(!AntigravitySandboxes.isValidName("../escape"))
        #expect(!AntigravitySandboxes.isValidName(String(repeating: "a", count: 65)))

        let box = Sandbox()
        let proc = FakeSandboxProcessControl()
        let mgr = AntigravitySandboxes(env: box.env, processControl: proc)

        #expect(mgr.suggestedName() == "acc2")
        try mgr.create(name: "acc2")
        #expect(mgr.suggestedName() == "acc3")
        try mgr.create(name: "acc3")
        #expect(mgr.suggestedName() == "acc4")
    }

    @Test func createsPrivateSandboxWithMarkersAndAutoUpdateSuppressed() throws {
        let box = Sandbox()
        let proc = FakeSandboxProcessControl(version: "2.31.2")
        let mgr = AntigravitySandboxes(env: box.env, processControl: proc)

        let sb = try mgr.create(name: "work", alias: "Work Account", linkPolicy: .minimal)
        #expect(sb.name == "work")
        #expect(sb.alias == "Work Account")
        #expect(sb.label == "Work Account")
        #expect(sb.linkPolicy == .minimal)
        #expect(!sb.signedIn)
        #expect(!sb.running)

        // Permissions must be owner-only (0700).
        var st = stat()
        #expect(lstat(sb.path.path, &st) == 0)
        #expect((st.st_mode & 0o777) == 0o700)

        // All 3 keyring-unavailable cache markers must exist with far-future mtime.
        for rel in AntigravitySandboxes.keyringMarkerRelativePaths {
            let marker = sb.homePath.appendingPathComponent(rel)
            #expect(FS.isFile(marker))
            let mtime = FS.mtime(marker) ?? .distantPast
            #expect(mtime.timeIntervalSince1970 > 2_000_000_000)
        }

        // Sandbox auto-updates must be suppressed in both app_storage.json and User/settings.json.
        let appStorage = try FS.readJSONObject(sb.dataPath.appendingPathComponent("app_storage.json"))
        #expect(appStorage?["autoCheckForUpdates"] as? String == "false")
        let userSettings = try FS.readJSONObject(sb.dataPath.appendingPathComponent("User/settings.json"))
        #expect(userSettings?["update.mode"] as? String == "none")

        // Duplicate creation must fail cleanly.
        #expect(throws: SwitcherError.self) {
            try mgr.create(name: "work")
        }
    }

    @Test func linkPoliciesProtectSshByDefaultAndReconcileSafely() throws {
        let box = Sandbox()
        box.write(box.root.appendingPathComponent(".gitconfig"), "[user]\nname = Ada\n")
        box.write(box.root.appendingPathComponent(".ssh/id_ed25519"), "PRIVATE-KEY")
        box.write(box.root.appendingPathComponent(".config/secret.json"), "{}")
        box.write(box.root.appendingPathComponent("Library/Keychains/login.keychain-db"), "kc")

        let mgr = AntigravitySandboxes(env: box.env, processControl: FakeSandboxProcessControl())

        // Default `.minimal`: links .gitconfig & Library/Keychains, hides .ssh and .config.
        let sb = try mgr.create(name: "acc2", linkPolicy: .minimal)
        #expect(FS.exists(sb.homePath.appendingPathComponent(".gitconfig")))
        #expect(FS.exists(sb.homePath.appendingPathComponent("Library/Keychains")))
        #expect(!FS.exists(sb.homePath.appendingPathComponent(".ssh")))
        #expect(!FS.exists(sb.homePath.appendingPathComponent(".config")))

        // Upgrade to `.full`: adds .ssh and .config.
        try mgr.setLinkPolicy("acc2", .full)
        #expect(FS.exists(sb.homePath.appendingPathComponent(".ssh")))
        #expect(FS.exists(sb.homePath.appendingPathComponent(".config")))

        // Downgrade back to `.minimal`: removes .ssh/.config symlinks, keeps .gitconfig and never touches host files.
        try mgr.setLinkPolicy("acc2", .minimal)
        #expect(!FS.exists(sb.homePath.appendingPathComponent(".ssh")))
        #expect(!FS.exists(sb.homePath.appendingPathComponent(".config")))
        #expect(FS.exists(sb.homePath.appendingPathComponent(".gitconfig")))
        #expect(FS.exists(box.root.appendingPathComponent(".ssh/id_ed25519")))

        // Downgrade to `.none`: removes managed .gitconfig symlink, but leaves a user-created real file intact.
        box.write(sb.homePath.appendingPathComponent(".zshrc"), "# local sandbox file\n")
        try mgr.setLinkPolicy("acc2", .none)
        #expect(!FS.exists(sb.homePath.appendingPathComponent(".gitconfig")))
        #expect(FS.isFile(sb.homePath.appendingPathComponent(".zshrc")))
    }

    @Test func hostConfigInheritanceStripsSecretsAndNeverCopiesCredentials() throws {
        let box = Sandbox()
        // Host has both normal settings and secrets.
        box.write(box.env.gemini.appendingPathComponent("settings.json"), #"""
        {
          "theme": "dark",
          "oauth_creds": "SECRET-1",
          "refreshToken": "SECRET-2",
          "lastLoginUsername": "host@example.com",
          "nested": { "model": "gemini-3", "access_token": "SECRET-3" }
        }
        """#)
        box.write(box.env.antigravityTokenFile, #"{"token":{"access_token":"HOST-TOKEN","refresh_token":"HOST-REFRESH"},"id_token_email":"host@example.com"}"#)
        box.write(box.env.gemini.appendingPathComponent("google_accounts.json"), #"{"active":"host@example.com"}"#)
        box.write(box.env.gemini.appendingPathComponent("GEMINI.md"), "# Rules")
        box.write(box.env.antigravityData.appendingPathComponent("User/settings.json"), #"{"editor.fontSize":14,"update.mode":"default"}"#)
        box.write(box.env.antigravityAppStorage, #"{"agy.onboarding.lastLoginUsername":"host@example.com"}"#)

        let mgr = AntigravitySandboxes(env: box.env, processControl: FakeSandboxProcessControl())
        let sb = try mgr.create(name: "acc2", inheritHostConfig: true)

        // Credentials & host accounts must NEVER be copied.
        #expect(!FS.exists(sb.homePath.appendingPathComponent(".gemini/jetski-standalone-oauth-token")))
        #expect(!FS.exists(sb.homePath.appendingPathComponent(".gemini/google_accounts.json")))
        #expect(sb.email == nil)
        #expect(!sb.signedIn)

        // Filtered ~/.gemini/settings.json keeps safe keys and strips all secrets.
        let inheritedGemini = try FS.readJSONObject(sb.homePath.appendingPathComponent(".gemini/settings.json"))
        #expect(inheritedGemini?["theme"] as? String == "dark")
        #expect(inheritedGemini?["oauth_creds"] == nil)
        #expect(inheritedGemini?["refreshToken"] == nil)
        #expect(inheritedGemini?["lastLoginUsername"] == nil)
        let nested = inheritedGemini?["nested"] as? [String: Any]
        #expect(nested?["model"] as? String == "gemini-3")
        #expect(nested?["access_token"] == nil)

        // Editor settings inherited, with update.mode forced to "none".
        let inheritedUser = try FS.readJSONObject(sb.dataPath.appendingPathComponent("User/settings.json"))
        #expect((inheritedUser?["editor.fontSize"] as? NSNumber)?.intValue == 14)
        #expect(inheritedUser?["update.mode"] as? String == "none")

        // GEMINI.md linked.
        #expect(FS.exists(sb.homePath.appendingPathComponent(".gemini/GEMINI.md")))
    }

    @Test func detectsIdentityFromTokenFilesJwtAndAppStorage() throws {
        let box = Sandbox()
        let mgr = AntigravitySandboxes(env: box.env, processControl: FakeSandboxProcessControl())

        // 1. Standard wrapped jetski token with id_token_email.
        let s1 = try mgr.create(name: "acc2")
        box.write(s1.homePath.appendingPathComponent(".gemini/jetski-standalone-oauth-token"),
                  #"{"token":{"access_token":"a1","refresh_token":"r1"},"id_token_email":"two@example.com"}"#)
        let loaded1 = mgr.sandbox(named: "acc2")
        #expect(loaded1?.signedIn == true)
        #expect(loaded1?.email == "two@example.com")

        // 2. Flat oauth_creds.json with JWT id_token email claim.
        let s2 = try mgr.create(name: "acc3")
        let jwtPayload = Data(#"{"email":"three@example.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJSUzI1NiJ9.\(jwtPayload).sig"
        box.write(s2.homePath.appendingPathComponent(".gemini/oauth_creds.json"),
                  #"{"access_token":"a2","refresh_token":"r2","expiry_date":4102444800000,"id_token":"\#(jwt)"}"#)
        let loaded2 = mgr.sandbox(named: "acc3")
        #expect(loaded2?.signedIn == true)
        #expect(loaded2?.email == "three@example.com")
        #expect(AntigravityUsage.Credential(keyring: mgr.tokenPayload(for: "acc3") ?? "")?.refreshToken == "r2")

        // 3. Token without email + onboarding fallback in data/app_storage.json.
        let s3 = try mgr.create(name: "acc4")
        box.write(s3.homePath.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"),
                  #"{"token":{"access_token":"a3","refresh_token":"r3"}}"#)
        box.write(s3.dataPath.appendingPathComponent("app_storage.json"),
                  #"{"agy.onboarding.lastLoginUsername":"four@example.com","autoCheckForUpdates":"false"}"#)
        let loaded3 = mgr.sandbox(named: "acc4")
        #expect(loaded3?.signedIn == true)
        #expect(loaded3?.email == "four@example.com")

        // Resolve by number, name, alias, and email.
        try mgr.setAlias("acc3", "Side")
        #expect(mgr.resolve("1")?.name == "acc2")
        #expect(mgr.resolve("Side")?.name == "acc3")
        #expect(mgr.resolve("four@example.com")?.name == "acc4")
    }

    @Test func launchesHealsStopsAndBuildsIsolatedAgyEnvironment() throws {
        let box = Sandbox()
        let proc = FakeSandboxProcessControl(version: "2.31.0")
        let mgr = AntigravitySandboxes(env: box.env, processControl: proc)

        let sb = try mgr.create(name: "acc2")
        // Seed stale locks and cache dir, then bump installed Antigravity version.
        box.write(sb.dataPath.appendingPathComponent("SingletonLock"), "stale")
        box.write(sb.dataPath.appendingPathComponent("Code Cache/old.bin"), "old-bytecode")
        box.write(sb.dataPath.appendingPathComponent("Local Storage/keep"), "precious")
        proc.installedVersion = "2.32.0"

        let workspace = box.root.appendingPathComponent("worktree-b", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let pid = try mgr.launch("acc2", workspace: workspace.path, baseEnvironment: ["PATH": "/usr/bin"])
        #expect(pid == 40_000)
        #expect(proc.launches.count == 1)

        let record = proc.launches[0]
        #expect(record.arguments == ["--user-data-dir=\(sb.dataPath.path)", workspace.path])
        #expect(record.environment["HOME"] == sb.homePath.path)
        #expect(record.environment["SSH_CONNECTION"] == AntigravitySandboxes.sshConnectionValue)
        #expect(record.environment["SSH_CLIENT"] == AntigravitySandboxes.sshClientValue)
        #expect(record.environment["WSL_INTEROP"] == "1")
        #expect(record.environment[Proc.sandboxEnvKey] == "acc2")
        #expect(record.environment[Proc.sandboxRoleEnvKey] == "app")

        // Auto-heal cleaned stale lock and purged obsolete bytecode cache, preserving user data.
        #expect(!FS.exists(sb.dataPath.appendingPathComponent("SingletonLock")))
        #expect(!FS.exists(sb.dataPath.appendingPathComponent("Code Cache")))
        #expect(FS.exists(sb.dataPath.appendingPathComponent("Local Storage/keep")))
        #expect(mgr.latestLogURL(for: "acc2") != nil)

        // Second launch while running returns the existing PID without spawning a duplicate.
        let pidAgain = try mgr.launch("acc2")
        #expect(pidAgain == pid)
        #expect(proc.launches.count == 1)

        // Stop cleanly terminates sandbox and clears run.pid.
        let stopped = try mgr.stop("acc2")
        #expect(stopped)
        #expect(proc.stops.count == 1)
        #expect(!FS.exists(mgr.pidURL("acc2")))

        // agy CLI environment sets isolated HOME + WSL_INTEROP + cli role.
        let agyEnv = try mgr.agyEnvironment(for: "acc2", base: ["PATH": "/usr/bin"])
        #expect(agyEnv["HOME"] == sb.homePath.path)
        #expect(agyEnv["WSL_INTEROP"] == "1")
        #expect(agyEnv["SSH_CONNECTION"] == AntigravitySandboxes.sshConnectionValue)
        #expect(agyEnv[Proc.sandboxEnvKey] == "acc2")
        #expect(agyEnv[Proc.sandboxRoleEnvKey] == "cli")
    }

    @Test func switchboardRefreshesBothMainAndSandboxQuotas() async throws {
        let box = Sandbox()
        let kc = MemorySecrets()
        let proc = FakeSandboxProcessControl()

        let mainToken = "go-keyring-base64:" + Data(#"{"token":{"access_token":"tok-main","refresh_token":"r-main","expiry":"2099-01-01T00:00:00Z"},"id_token_email":"main@example.com"}"#.utf8).base64EncodedString()
        try kc.set(service: "gemini", account: "antigravity", value: mainToken)

        let sandboxes = AntigravitySandboxes(env: box.env, processControl: proc)
        let sb = try sandboxes.create(name: "acc2")
        box.write(sb.homePath.appendingPathComponent(".gemini/jetski-standalone-oauth-token"),
                  #"{"token":{"access_token":"tok-sb","refresh_token":"r-sb","expiry":"2099-01-01T00:00:00Z"},"id_token_email":"sb@example.com"}"#)

        let usage = AntigravityUsage(env: box.env) { req in
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            let url = req.url!.absoluteString
            let ok = { (body: String) in (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            if url.hasSuffix("loadCodeAssist") {
                return ok(#"{"paidTier":{"id":"g1-pro-tier"},"cloudaicompanionProject":"p-1"}"#)
            }
            let frac = auth == "Bearer tok-sb" ? "0.8" : "0.3"
            return ok("""
            {"response":{"groups":[{"displayName":"Gemini","buckets":[
              {"bucketId":"gemini-5h","remainingFraction":\(frac)},
              {"bucketId":"gemini-weekly","remainingFraction":0.5}
            ]}]}}
            """)
        }

        let board = Switchboard(
            env: box.env,
            claude: .claude(env: box.env, app: FakeApp(), keychain: kc),
            antigravity: .antigravity(env: box.env, app: FakeApp(), keychain: kc),
            sandboxes: sandboxes,
            antigravityUsage: usage
        )

        let refreshed = await board.refreshAntigravityUsage()
        #expect(refreshed["main@example.com"]?.bucket(.gemini5h)?.used == 70)
        #expect(refreshed[AntigravitySandboxes.quotaCacheKey(for: "acc2")]?.bucket(.gemini5h)?.used == 20)

        let sbBoard = board.sandboxBoard()
        #expect(sbBoard.count == 1)
        #expect(sbBoard[0].email == "sb@example.com")
        #expect(sbBoard[0].quota?.bucket(.gemini5h)?.used == 20)
    }

    @Test func parsesProcArgs2AndIdentifiesSandboxProcesses() {
        // Construct a realistic Darwin KERN_PROCARGS2 buffer:
        // [argc: Int32][exec_path\0][NUL padding][argv0\0][argv1\0][argv2\0][env0\0][env1\0]
        var buf = Data()
        var argc: Int32 = 3
        withUnsafeBytes(of: &argc) { buf.append(contentsOf: $0) }
        buf.append(Data("/Applications/Antigravity.app/Contents/MacOS/Antigravity\0\0\0\0".utf8))
        buf.append(Data("/Applications/Antigravity.app/Contents/MacOS/Antigravity\0".utf8))
        buf.append(Data("--user-data-dir=/Users/ada/.antigravity-sandboxes/acc2/data\0".utf8))
        buf.append(Data("\0".utf8)) // empty arg edge case
        buf.append(Data("HOME=/Users/ada/.antigravity-sandboxes/acc2/home\0".utf8))
        buf.append(Data("SWITCHER_AGY_SANDBOX=acc2\0".utf8))
        buf.append(Data("SWITCHER_AGY_SANDBOX_ROLE=app\0".utf8))

        let parsed = Proc.parseProcArgs2(buf)
        #expect(parsed != nil)
        #expect(parsed?.argv == [
            "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
            "--user-data-dir=/Users/ada/.antigravity-sandboxes/acc2/data",
            "",
        ])
        #expect(parsed?.env["HOME"] == "/Users/ada/.antigravity-sandboxes/acc2/home")
        #expect(parsed?.env["SWITCHER_AGY_SANDBOX"] == "acc2")
        #expect(Proc.antigravitySandboxName(argv: parsed!.argv, env: parsed!.env) == "acc2")

        // Fallback detection via --user-data-dir even without env var.
        #expect(Proc.antigravitySandboxName(argv: parsed!.argv, env: [:]) == "acc2")
        // Non-sandbox process returns nil.
        #expect(Proc.antigravitySandboxName(argv: ["/Applications/Antigravity.app/Contents/MacOS/Antigravity"], env: ["HOME": "/Users/ada"]) == nil)
    }
}

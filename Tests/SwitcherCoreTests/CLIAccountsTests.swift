import Foundation
import Testing
@testable import SwitcherCore

@Suite struct CLIIdentityTests {
    @Test func claudeDefaultReadsHomeDotClaudeJSON() {
        let box = CLIBox()
        box.write(box.home + "/.claude.json", box.json(["oauthAccount": [
            "accountUuid": "acc-1", "organizationUuid": "org-1", "emailAddress": "me@example.com", "organizationName": "Acme",
        ]]))
        let profiles = CLIProfiles(env: box.env)
        let id = profiles.identity(profiles.defaultProfile(.claude))
        #expect(id == CLIIdentity(email: "me@example.com", organization: "Acme", plan: nil, accountKey: "acc-1:org-1"))
    }

    @Test func claudeProfileReadsItsOwnFile() {
        let box = CLIBox()
        box.write(box.home + "/.claude.json", box.json(["oauthAccount": ["emailAddress": "default@example.com"]]))
        let profiles = CLIProfiles(env: box.env)
        let p = CLIProfile(kind: .claude, name: "work", path: box.env.profilesRoot(.claude) + "/work", isDefault: false)
        // Nothing in the profile yet: never the default account's identity.
        #expect(profiles.identity(p) == nil)
        box.write(p.path + "/.claude.json", box.json(["oauthAccount": ["accountUuid": "a", "emailAddress": "work@example.com"]]))
        let id = profiles.identity(p)
        #expect(id?.email == "work@example.com")
        #expect(id?.accountKey == "a:")
        // A file without an account.
        box.write(p.path + "/.claude.json", box.json(["theme": "dark"]))
        #expect(profiles.identity(p) == nil)
    }

    @Test func codexIdentityFromAnUnsignedJWT() {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let p = CLIProfile(kind: .codex, name: "alt", path: box.env.profilesRoot(.codex) + "/alt", isDefault: false)
        let jwt = fakeJWT([
            "email": "codex@example.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus", "chatgpt_account_id": "acct-from-claims"],
        ])
        box.write(p.path + "/auth.json", box.json(["auth_mode": "chatgpt", "tokens": ["id_token": jwt, "refresh_token": "r", "access_token": "a", "account_id": "acct-1"]]))
        let id = profiles.identity(p)
        #expect(id == CLIIdentity(email: "codex@example.com", organization: nil, plan: "plus", accountKey: "acct-1"))
        // Without tokens.account_id the claim is used (when refresh_token is still present).
        box.write(p.path + "/auth.json", box.json(["tokens": ["id_token": jwt, "refresh_token": "r"]]))
        #expect(profiles.identity(p)?.accountKey == "acct-from-claims")
        // Default profile reads ~/.codex/auth.json.
        box.write(box.home + "/.codex/auth.json", box.json(["tokens": ["id_token": jwt, "refresh_token": "r"]]))
        #expect(profiles.identity(profiles.defaultProfile(.codex))?.email == "codex@example.com")
        // Missing or empty refresh_token means signed out: stale id_token claims are ignored.
        box.write(p.path + "/auth.json", box.json(["tokens": ["id_token": jwt]]))
        #expect(profiles.identity(p) == nil)
        box.write(p.path + "/auth.json", box.json(["tokens": ["id_token": jwt, "refresh_token": "  "]]))
        #expect(profiles.identity(p) == nil)
    }

    @Test func codexIdentityToleratesJunk() {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let p = CLIProfile(kind: .codex, name: "alt", path: box.env.profilesRoot(.codex) + "/alt", isDefault: false)
        #expect(profiles.identity(p) == nil)
        box.write(p.path + "/auth.json", "not json")
        #expect(profiles.identity(p) == nil)
        box.write(p.path + "/auth.json", box.json(["OPENAI_API_KEY": "sk-x"]))
        #expect(profiles.identity(p) == nil)
        box.write(p.path + "/auth.json", box.json(["tokens": ["id_token": "garbage"]]))
        #expect(profiles.identity(p)?.email == nil)
    }

    @Test func jwtPayloadWithBase64URLCharactersAndNoPadding() {
        // Claims whose base64 contains `-` / `_` and need padding restored.
        let claims: [String: Any] = ["email": "a?b>c@example.com", "name": "\u{e9}\u{e9}\u{e9}~~~"]
        let jwt = fakeJWT(claims)
        let decoded = CLIProfiles.jwtClaims(jwt)
        #expect(decoded?["email"] as? String == "a?b>c@example.com")
        #expect(decoded?["name"] as? String == "\u{e9}\u{e9}\u{e9}~~~")
        #expect(CLIProfiles.jwtClaims("one-part") == nil)
    }

    @Test func decodeSecurityOutputHandlesHexUTF8AndLeavesPlainStringsAlone() {
        let json = "{\"claudeAiOauth\":{\"accessToken\":\"tok\",\"org\":\"Caf\u{00e9}\"}}\n"
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(LiveCLIKeychain.decodeSecurityOutput(hex) == json)
        #expect(LiveCLIKeychain.decodeSecurityOutput("{\"claudeAiOauth\":{}}") == "{\"claudeAiOauth\":{}}")
        #expect(LiveCLIKeychain.decodeSecurityOutput("go-keyring-base64:e30=") == "go-keyring-base64:e30=")
    }

    @Test func agyIdentitySignInAndCredentialFingerprintIsolateNamedProfiles() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let keychain = MemoryCLIKeychain()
        let def = profiles.defaultProfile(.agy)
        let named = try profiles.add(.agy, name: "work")

        let defPayload = box.json([
            "token": ["access_token": "acc-def", "refresh_token": "ref-def", "expiry": "2026-11-15T10:00:00Z"],
            "id_token_email": "Default@Example.com",
        ])
        keychain.items["gemini/antigravity"] = "go-keyring-base64:" + Data(defPayload.utf8).base64EncodedString()

        // Default reads Keychain; named profile ignores Keychain completely when its own file is absent.
        #expect(profiles.signIn(def, keychain: keychain).state == .signedIn)
        #expect(profiles.identity(def, keychain: keychain) == CLIIdentity(email: "Default@Example.com", organization: nil, plan: nil, accountKey: "default@example.com"))
        #expect(profiles.signIn(named, keychain: keychain).state == .signedOut)
        #expect(profiles.identity(named, keychain: keychain) == nil)

        // Default email falls back to ~/.gemini/jetski-standalone-oauth-token when Keychain omits id_token_email.
        let barePayload = box.json(["token": ["refresh_token": "ref-def"]])
        let hex = Data(barePayload.utf8).map { String(format: "%02x", $0) }.joined()
        keychain.items["gemini/antigravity"] = "go-keyring-encoded:" + hex
        box.write(box.home + "/.gemini/jetski-standalone-oauth-token", box.json(["id_token_email": "fallback@example.com"]))
        #expect(profiles.identity(def, keychain: keychain)?.email == "fallback@example.com")

        // Named profile reads its own file; fingerprint hashes refresh token without leaking secrets.
        let namedPayload = box.json(["token": ["access_token": "acc-work", "refresh_token": "ref-work-SECRET"]])
        box.write(named.path + "/antigravity-cli/antigravity-oauth-token", namedPayload)
        #expect(profiles.signIn(named, keychain: keychain).state == .signedIn)
        let fpNamed = try #require(profiles.credentialFingerprint(named, keychain: keychain))
        let fpDef = try #require(profiles.credentialFingerprint(def, keychain: keychain))
        #expect(fpNamed != fpDef)
        #expect(!fpNamed.contains("ref-work-SECRET"))
    }
}

@Suite struct CLISignInTests {
    let ms = 1_800_000_000_000.0

    func claudeJSON(access: String = "tok-ACCESS", expires: Double? = nil, refresh: Double? = nil, sub: String? = "max") -> String {
        var o: [String: Any] = ["accessToken": access, "refreshToken": "tok-REFRESH"]
        if let expires { o["expiresAt"] = expires }
        if let refresh { o["refreshTokenExpiresAt"] = refresh }
        if let sub { o["subscriptionType"] = sub }
        return CLIBox().json(["claudeAiOauth": o])
    }

    @Test func claudeFromTheKeychainItemNamedByTheProfilePath() {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let keychain = MemoryCLIKeychain()
        let p = CLIProfile(kind: .claude, name: "work", path: box.env.profilesRoot(.claude) + "/work", isDefault: false)
        #expect(profiles.signIn(p, keychain: keychain).state == .signedOut)
        keychain.items["Claude Code-credentials"] = claudeJSON() // the default account's item is not this profile's
        #expect(profiles.signIn(p, keychain: keychain).state == .signedOut)
        keychain.items[claudeKeychainService(configDir: p.path)] = claudeJSON(expires: ms, refresh: ms + 86_400_000)
        let s = profiles.signIn(p, keychain: keychain)
        #expect(s.state == .signedIn)
        #expect(s.accessExpiresAt == Date(timeIntervalSince1970: ms / 1000))
        #expect(s.refreshExpiresAt == Date(timeIntervalSince1970: ms / 1000 + 86_400))
        #expect(profiles.claudeSubscription(p, keychain: keychain) == "max")
    }

    @Test func claudeDefaultUsesTheBareService() {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let keychain = MemoryCLIKeychain()
        keychain.items["Claude Code-credentials"] = claudeJSON(expires: ms)
        let s = profiles.signIn(profiles.defaultProfile(.claude), keychain: keychain)
        #expect(s.state == .signedIn)
        #expect(s.refreshExpiresAt == nil)
        #expect(s.accessExpiresAt == Date(timeIntervalSince1970: ms / 1000))
    }

    @Test func claudeFallsBackToThePlaintextFile() {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let keychain = MemoryCLIKeychain()
        let p = CLIProfile(kind: .claude, name: "work", path: box.env.profilesRoot(.claude) + "/work", isDefault: false)
        box.write(p.path + "/.credentials.json", claudeJSON(expires: ms, sub: "pro"))
        #expect(profiles.signIn(p, keychain: keychain).state == .signedIn)
        #expect(profiles.claudeSubscription(p, keychain: keychain) == "pro")
        // The keychain wins when both exist.
        keychain.items[claudeKeychainService(configDir: p.path)] = claudeJSON(sub: "max")
        #expect(profiles.claudeSubscription(p, keychain: keychain) == "max")
    }

    @Test func claudeWithoutAnAccessTokenOrWithJunkIsSignedOut() {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let keychain = MemoryCLIKeychain()
        let p = CLIProfile(kind: .claude, name: "work", path: box.env.profilesRoot(.claude) + "/work", isDefault: false)
        let service = claudeKeychainService(configDir: p.path)
        keychain.items[service] = "not json"
        #expect(profiles.signIn(p, keychain: keychain).state == .signedOut)
        keychain.items[service] = box.json(["claudeAiOauth": ["refreshToken": "r"]])
        #expect(profiles.signIn(p, keychain: keychain).state == .signedOut)
        keychain.items[service] = box.json(["claudeAiOauth": ["accessToken": "   "]])
        #expect(profiles.signIn(p, keychain: keychain).state == .signedOut)
        keychain.items[service] = box.json(["somethingElse": 1])
        #expect(profiles.signIn(p, keychain: keychain).state == .signedOut)
    }

    @Test func codexChatGPTSignIn() {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let keychain = MemoryCLIKeychain()
        let p = CLIProfile(kind: .codex, name: "alt", path: box.env.profilesRoot(.codex) + "/alt", isDefault: false)
        #expect(profiles.signIn(p, keychain: keychain).state == .signedOut)
        box.write(p.path + "/auth.json", box.json([
            "auth_mode": "chatgpt", "last_refresh": "2026-11-01T10:20:30.123Z",
            "tokens": ["id_token": fakeJWT([:]), "refresh_token": "r", "access_token": "a"],
        ]))
        let s = profiles.signIn(p, keychain: keychain)
        #expect(s.state == .signedIn)
        #expect(s.lastRefresh == Date(timeIntervalSince1970: 1_793_528_430.123))
        // Without a fraction, and without the auth_mode key.
        box.write(p.path + "/auth.json", box.json(["last_refresh": "2026-11-01T10:20:30Z", "tokens": ["refresh_token": "r"]]))
        let t = profiles.signIn(p, keychain: keychain)
        #expect(t.state == .signedIn)
        #expect(t.lastRefresh == Date(timeIntervalSince1970: 1_793_528_430))
    }

    @Test func codexAPIKeyModeIsOther() {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let p = CLIProfile(kind: .codex, name: "alt", path: box.env.profilesRoot(.codex) + "/alt", isDefault: false)
        box.write(p.path + "/auth.json", box.json(["OPENAI_API_KEY": "sk-key"]))
        #expect(profiles.signIn(p, keychain: MemoryCLIKeychain()).state == .other("apikey"))
        box.write(p.path + "/auth.json", box.json(["OPENAI_API_KEY": "sk-key", "tokens": NSNull()]))
        #expect(profiles.signIn(p, keychain: MemoryCLIKeychain()).state == .other("apikey"))
        box.write(p.path + "/auth.json", box.json(["auth_mode": "apikey", "OPENAI_API_KEY": "sk-key"]))
        #expect(profiles.signIn(p, keychain: MemoryCLIKeychain()).state == .other("apikey"))
        box.write(p.path + "/auth.json", box.json(["auth_mode": "api_key", "OPENAI_API_KEY": "sk-key"]))
        #expect(profiles.signIn(p, keychain: MemoryCLIKeychain()).state == .other("api_key"))
        // ChatGPT mode that lost its refresh token is signed out.
        box.write(p.path + "/auth.json", box.json(["auth_mode": "chatgpt", "tokens": ["access_token": "a"]]))
        #expect(profiles.signIn(p, keychain: MemoryCLIKeychain()).state == .signedOut)
    }

    @Test func codexWithoutAnyCredentialIsSignedOut() {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let p = CLIProfile(kind: .codex, name: "alt", path: box.env.profilesRoot(.codex) + "/alt", isDefault: false)
        for auth: [String: Any] in [
            [:],
            ["auth_mode": ""],
            ["OPENAI_API_KEY": NSNull()],
            ["auth_mode": "apikey", "OPENAI_API_KEY": ""],
            ["auth_mode": "api_key", "OPENAI_API_KEY": "   "],
            ["auth_mode": "chatgpt", "tokens": ["access_token": "a", "refresh_token": ""]],
        ] {
            box.write(p.path + "/auth.json", box.json(auth))
            #expect(profiles.signIn(p, keychain: MemoryCLIKeychain()).state == .signedOut)
        }
    }
}

@Suite struct CLIDoctorTests {
    let secret = "tok-SECRET-VALUE-9f3a"

    struct Setup {
        let box: CLIBox
        let env: CLIEnv
        let profiles: CLIProfiles
        let keychain = MemoryCLIKeychain()
        let rc: String
    }

    func claudeJSON(refreshIn days: Double? = nil) -> String {
        var o: [String: Any] = ["accessToken": secret, "refreshToken": secret + "-r", "expiresAt": 1_800_000_000_000.0]
        if let days { o["refreshTokenExpiresAt"] = (Date().timeIntervalSince1970 + days * 86_400) * 1000 }
        return CLIBox().json(["claudeAiOauth": o])
    }

    func codexJSON() -> String {
        CLIBox().json(["auth_mode": "chatgpt", "tokens": ["id_token": fakeJWT(["email": "x@example.com"]), "refresh_token": secret, "access_token": secret + "-a"]])
    }

    func agyJSON() -> String {
        CLIBox().json(["token": ["access_token": secret + "-a", "refresh_token": secret + "-r"], "id_token_email": "agy@example.com"])
    }

    /// A clean setup: all shims installed, rc block last, default and `work` profiles signed in.
    func clean() throws -> Setup {
        let box = CLIBox()
        let env = box.env(
            realClaude: box.fakeBinary(box.top + "/real/claude"),
            realCodex: box.fakeBinary(box.top + "/real/codex"),
            realAgy: box.fakeBinary(box.top + "/real/agy"))
        try CLIShim.installShims(env: env, path: "")
        let s = Setup(box: box, env: env, profiles: CLIProfiles(env: env), rc: box.home + "/.zshrc")
        box.write(s.rc, "export A=1\n")
        try CLIShim.installRC(s.rc, env: env)
        box.mkdir(env.defaultFolder(.claude) + "/skills")
        let work = try s.profiles.add(.claude, name: "work")
        s.keychain.items["Claude Code-credentials"] = claudeJSON()
        s.keychain.items[claudeKeychainService(configDir: work.path)] = claudeJSON()
        box.write(env.defaultFolder(.codex) + "/auth.json", codexJSON())
        s.keychain.items["gemini/antigravity"] = agyJSON()
        return s
    }

    func doctor(_ s: Setup, resolve: ((String) -> [(String, String?)])? = nil, rcFiles: [String]? = nil) -> [DoctorFinding] {
        let env = s.env
        let r = resolve ?? { cmd in
            ["zsh -lc", "zsh -ic", "zsh -c"].map { ($0, env.shim(CLIKind.allCases.first { $0.command == cmd }!)) }
        }
        return CLIDoctor(profiles: s.profiles, keychain: s.keychain, rcFiles: rcFiles ?? [s.rc], resolve: r).run()
    }

    func messages(_ f: [DoctorFinding], _ level: DoctorFinding.Level? = nil) -> [String] {
        f.filter { level == nil || $0.level == level }.map(\.message)
    }

    @Test func cleanSetupHasNoProblems() throws {
        let s = try clean()
        let f = doctor(s)
        #expect(f.contains(DoctorFinding(level: .ok, message: "no problems found")), "\(f)")
        #expect(f.allSatisfy { $0.level == .note || $0.level == .ok })
    }

    @Test func missingShim() throws {
        let s = try clean()
        CLIShim.uninstallShims(env: s.env)
        let f = doctor(s)
        #expect(messages(f, .warn).contains { $0.contains("claude: no Switcher shim") })
        #expect(messages(f, .warn).contains { $0.contains("codex: no Switcher shim") })
        #expect(!f.contains { $0.level == .ok })
    }

    @Test func shellFindsAnotherBinaryFirst() throws {
        let s = try clean()
        let shim = s.env.shim(.claude)
        let f = doctor(s) { cmd in
            if cmd == "claude" {
                return [("zsh -lc", shim), ("zsh -ic", "/usr/local/bin/claude"), ("zsh -c", nil)]
            }
            let kind = CLIKind.allCases.first { $0.command == cmd }!
            return [("zsh -lc", s.env.shim(kind))]
        }
        let warns = messages(f, .warn)
        #expect(warns.contains { $0.contains("`zsh -ic` finds /usr/local/bin/claude before the shim") })
        #expect(warns.contains { $0.contains("`zsh -c` finds nothing before the shim") })
        #expect(!warns.contains { $0.contains("zsh -lc") })
        #expect(!warns.contains { $0.contains("codex:") })
        #expect(!warns.contains { $0.contains("agy:") })
    }

    @Test func rcBlockNotLastAndAbsent() throws {
        let s = try clean()
        s.box.write(s.rc, s.box.read(s.rc)! + "export PATH=/opt/x:$PATH\n")
        let absent = s.box.home + "/.bashrc"
        s.box.write(absent, "export B=1\n")
        let f = doctor(s, rcFiles: [s.rc, absent, s.box.home + "/.missing"])
        #expect(messages(f, .warn).contains { $0.hasPrefix(s.rc) && $0.contains("lines after Switcher's PATH line") })
        #expect(messages(f, .note).contains { $0.hasPrefix(absent) && $0.contains("no Switcher PATH line") })
        #expect(messages(f, .note).contains { $0.hasPrefix(s.box.home + "/.missing") })
    }

    @Test func invalidPointer() throws {
        let s = try clean()
        s.box.write(s.env.pointer(.claude), s.env.profilesRoot(.claude) + "/gone/\n")
        let f = doctor(s)
        #expect(messages(f, .warn).contains { $0.contains("Claude Code: the pointer names") && $0.contains("not a valid profile folder") })
        // A valid path whose folder was deleted gets a distinct missing-folder warning.
        s.box.write(s.env.pointer(.claude), s.env.profilesRoot(.claude) + "/missing\n")
        #expect(messages(doctor(s), .warn).contains { $0.contains("points to a missing profile folder") })
        // A good pointer, and `default`, report nothing.
        s.box.write(s.env.pointer(.claude), "default\n")
        s.box.write(s.env.pointer(.codex), "default\n")
        s.box.write(s.env.pointer(.agy), "default\n")
        #expect(!messages(doctor(s)).contains { $0.contains("the pointer") })
        #expect(doctor(s).contains { $0.level == .ok })
    }

    @Test func malformedCredentialsBrokenRCAndMissingAgyMarkerAreReported() throws {
        let s = try clean()
        let work = s.profiles.resolve(.claude, "work")!
        s.keychain.items[claudeKeychainService(configDir: work.path)] = nil
        s.box.write(work.path + "/.credentials.json", "{corrupt")
        let agyWork = try s.profiles.add(.agy, name: "work")
        s.box.write(agyWork.path + "/antigravity-cli/antigravity-oauth-token", agyJSON())
        unlink(agyWork.path + "/antigravity-cli/cache/antigravity-keyring-unavailable")
        let brokenRC = s.box.home + "/.bashrc"
        s.box.write(brokenRC, CLIShim.rcBegin + "\n")
        let f = doctor(s, rcFiles: [s.rc, brokenRC])
        let problems = messages(f, .problem)
        let warns = messages(f, .warn)
        #expect(problems.contains { $0.contains("Claude Code work:") && $0.contains("is not valid JSON") })
        #expect(problems.contains { $0.contains("incomplete or duplicated Switcher lines") })
        #expect(warns.contains { $0.contains("Antigravity CLI work: keyring-isolation marker is missing") })
    }

    @Test func skippedFoldersAreNoted() throws {
        let s = try clean()
        s.box.mkdir(s.box.top + "/elsewhere")
        s.box.symlink(s.env.profilesRoot(.claude) + "/linked", to: s.box.top + "/elsewhere")
        s.box.mkdir(s.env.profilesRoot(.claude) + "/has space")
        let notes = messages(doctor(s), .note)
        #expect(notes.contains { $0.contains("/linked is skipped") })
        #expect(notes.contains { $0.contains("/has space is skipped") })
    }

    @Test func signedOutProfile() throws {
        let s = try clean()
        let work = s.profiles.resolve(.claude, "work")!
        s.keychain.items[claudeKeychainService(configDir: work.path)] = nil
        let f = doctor(s)
        let warn = messages(f, .warn).first { $0.hasPrefix("Claude Code work: not signed in") }
        #expect(warn != nil)
        #expect(warn?.contains("CLAUDE_CONFIG_DIR='\(work.path)' claude") == true)
        #expect(!f.contains { $0.level == .ok })
    }

    @Test func signInExpiringSoonAndExpired() throws {
        let s = try clean()
        let work = s.profiles.resolve(.claude, "work")!
        s.keychain.items[claudeKeychainService(configDir: work.path)] = claudeJSON(refreshIn: 2.5)
        #expect(messages(doctor(s), .warn).contains { $0.hasPrefix("Claude Code work: the sign-in runs out in 3 day(s)") })
        s.keychain.items[claudeKeychainService(configDir: work.path)] = claudeJSON(refreshIn: 30)
        #expect(doctor(s).contains { $0.level == .ok })
        s.keychain.items[claudeKeychainService(configDir: work.path)] = claudeJSON(refreshIn: -1)
        #expect(messages(doctor(s), .problem).contains { $0.hasPrefix("Claude Code work: the sign-in ran out") })
    }

    @Test func replacedLink() throws {
        let s = try clean()
        let work = s.profiles.resolve(.claude, "work")!
        unlink(work.path + "/skills")
        s.box.mkdir(work.path + "/skills")
        let f = doctor(s)
        #expect(messages(f, .warn).contains { $0.contains("Claude Code work: skills is a real file now") })
        #expect(!f.contains { $0.level == .ok })
    }

    @Test func strayKeychainItemForTheDefaultFolderPath() throws {
        let s = try clean()
        let stray = claudeKeychainService(configDir: s.box.home + "/.claude")
        s.keychain.items[stray] = claudeJSON()
        s.keychain.items[claudeKeychainService(configDir: s.box.home + "/.claude/")] = claudeJSON()
        s.keychain.items["Claude Code-credentials-deadbeef"] = claudeJSON()
        let notes = messages(doctor(s), .note)
        let hint = notes.first { $0.contains("\"\(stray)\"") }
        #expect(hint?.contains("CLAUDE_CONFIG_DIR=\(s.box.home)/.claude") == true)
        #expect(hint?.contains("Optional(") == false)
        #expect(hint?.contains("leave that variable unset") == true)
        #expect(hint?.contains("never deletes") == true)
        #expect(notes.contains { $0.contains("\"\(claudeKeychainService(configDir: s.box.home + "/.claude/"))\"") && $0.contains("/.claude/") })
        #expect(notes.contains { $0.contains("Claude Code-credentials-deadbeef") && $0.contains("another tool's folder") })
        // Notes alone are not problems.
        #expect(doctor(s).contains { $0.level == .ok })
        // Registered profiles' own items are not reported as strays.
        let work = s.profiles.resolve(.claude, "work")!
        #expect(!notes.contains { $0.contains("\"\(claudeKeychainService(configDir: work.path))\"") })
        #expect(!notes.contains { $0.contains("\"Claude Code-credentials\"") })
    }

    @Test func stalePlaintextCredentialsNextToTheKeychainItem() throws {
        let s = try clean()
        s.box.write(s.box.home + "/.claude/.credentials.json", claudeJSON())
        #expect(messages(doctor(s), .note).contains { $0.contains(".credentials.json exists next to the keychain sign-in") })
    }

    @Test func noFindingEverContainsATokenValue() throws {
        let s = try clean()
        // Provoke as many findings as possible.
        let work = s.profiles.resolve(.claude, "work")!
        s.keychain.items[claudeKeychainService(configDir: work.path)] = claudeJSON(refreshIn: 1)
        s.keychain.items[claudeKeychainService(configDir: s.box.home + "/.claude")] = claudeJSON()
        s.keychain.items["Claude Code-credentials-deadbeef"] = claudeJSON()
        s.box.write(s.box.home + "/.claude/.credentials.json", claudeJSON())
        s.box.write(s.env.pointer(.claude), "/nowhere\n")
        unlink(work.path + "/skills")
        s.box.mkdir(work.path + "/skills")
        s.box.write(s.env.defaultFolder(.codex) + "/auth.json", codexJSON())
        CLIShim.uninstallShims(env: s.env)
        let f = doctor(s)
        #expect(f.count > 5)
        for finding in f {
            #expect(!finding.message.contains("SECRET-VALUE"), "\(finding.message)")
            #expect(!finding.message.contains(secret))
        }
    }
}

/// Real child processes (`/bin/sh` only), never the user's shell or rc files.
@Suite struct CLIDoctorProcessTests {
    // Review finding 8: output larger than a pipe is drained while waiting.
    @Test func aLargeStartupOutputDoesNotBlockTheResolver() {
        // 256 KiB is four times what a pipe holds: without draining, the shell blocks on write
        // and is killed at the deadline, so the path comes back nil. The deadline is generous so
        // a slow CI runner still finishes well inside it.
        let script = "head -c 262144 /dev/zero | tr '\\0' x; echo; command -v sh"
        let path = CLIDoctor.lastPathLine(shell: "/bin/sh", flags: ["-c"], script: script, timeout: 30)
        #expect(path?.hasSuffix("/sh") == true)
    }

    @Test func aStuckShellIsKilledAndWaitedFor() throws {
        let box = CLIBox()
        let pidFile = box.top + "/pid"
        box.mkdir(box.top)
        let script = "trap '' TERM; echo $$ > '\(pidFile)'; exec /bin/sleep 30"
        let start = Date()
        #expect(CLIDoctor.lastPathLine(shell: "/bin/sh", flags: ["-c"], script: script, timeout: 3) == nil)
        #expect(Date().timeIntervalSince(start) < 9)
        let pid = try #require(box.read(pidFile).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let alive = kill(pid, 0) == 0
        if alive { kill(pid, SIGKILL) }
        #expect(!alive)
    }
}

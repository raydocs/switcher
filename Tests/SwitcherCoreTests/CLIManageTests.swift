import Foundation
import Testing
@testable import SwitcherCore

/// Adding and removing CLI accounts, in a temporary HOME. Never the Trash (`toTrash: false`), never
/// a real CLI: the sign-in runs are fake shell scripts.
@Suite struct CLIManageTests {
    func signInCodex(_ box: CLIBox, _ p: CLIProfile, email: String, account: String) {
        let jwt = fakeJWT(["email": email])
        box.write(p.path + "/auth.json", box.json(["auth_mode": "chatgpt", "tokens": ["id_token": jwt, "refresh_token": "r", "account_id": account]]))
    }

    @Test func suggestedNamesCountFromTwoAndSortNaturally() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        #expect(profiles.suggestedName(.codex) == "account2")
        for _ in 0..<9 { try profiles.add(.codex, name: profiles.suggestedName(.codex)) }
        #expect(profiles.suggestedName(.codex) == "account11")
        // account2 … account10 in number order, after the default account.
        #expect(profiles.list(.codex).map(\.name) == ["default"] + (2...10).map { "account\($0)" })
        // A name already taken in another case, or a stray file, is skipped.
        box.write(box.env.profilesRoot(.claude) + "/account2", "not a folder")
        #expect(profiles.suggestedName(.claude) == "account3")
        // Finding #12: an orphaned Claude Keychain item for account3 is skipped too.
        let kc = MemoryCLIKeychain()
        kc.items[claudeKeychainService(configDir: box.env.profilesRoot(.claude) + "/account3")] = "{}"
        #expect(profiles.suggestedName(.claude, keychain: kc) == "account4")
    }

    @Test func accountsResolveByAUniqueEmail() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let a = try profiles.add(.codex, name: "a"), b = try profiles.add(.codex, name: "b")
        signInCodex(box, a, email: "One@Example.com", account: "acct-1")
        signInCodex(box, b, email: "two@example.com", account: "acct-2")
        #expect(profiles.resolve(.codex, "one@example.com")?.path == a.path)
        #expect(profiles.resolve(.codex, "two@example.com")?.path == b.path)
        // The same email in two folders: ambiguous, so neither.
        let c = try profiles.add(.codex, name: "c")
        signInCodex(box, c, email: "two@example.com", account: "acct-3")
        #expect(profiles.resolve(.codex, "two@example.com") == nil)
        #expect(profiles.resolve(.codex, "nobody@example.com") == nil)
    }

    @Test func duplicatesAreTheSameAccountNotTheSameEmail() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let a = try profiles.add(.codex, name: "a"), b = try profiles.add(.codex, name: "b"), c = try profiles.add(.codex, name: "c")
        signInCodex(box, a, email: "x@example.com", account: "acct-1")
        signInCodex(box, b, email: "x@example.com", account: "acct-1")
        signInCodex(box, c, email: "x@example.com", account: "acct-team")
        #expect(profiles.duplicates(of: b).map(\.path) == [a.path])
        #expect(profiles.duplicates(of: c).isEmpty)
        #expect(profiles.duplicates(of: try profiles.add(.codex, name: "d")).isEmpty)

        // Fallback to credentialFingerprint when accountKey/email is absent.
        let agy1 = try profiles.add(.agy, name: "one"), agy2 = try profiles.add(.agy, name: "two")
        box.write(agy1.path + "/antigravity-cli/antigravity-oauth-token", box.json(["token": ["refresh_token": "same-refresh"]]))
        box.write(agy2.path + "/antigravity-cli/antigravity-oauth-token", box.json(["token": ["refresh_token": "same-refresh"]]))
        #expect(profiles.duplicates(of: agy2, keychain: MemoryCLIKeychain()).map(\.path) == [agy1.path])
    }

    @Test func aCancelledAddLeavesNothingAndTheSharedItemsStay() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        box.write(box.home + "/.codex/config.toml", "model = \"x\"\n")
        box.write(box.home + "/.codex/sessions/one.jsonl", "keep")
        let p = try profiles.add(.codex, name: "new")
        #expect(box.isLink(p.path + "/sessions"))
        try profiles.discardUnsignedIn(p, keychain: MemoryCLIKeychain())
        #expect(!FS.exists(URL(fileURLWithPath: p.path)))
        #expect(box.read(box.home + "/.codex/config.toml") == "model = \"x\"\n")
        #expect(box.read(box.home + "/.codex/sessions/one.jsonl") == "keep")
    }

    @Test func aSignedInFolderIsNeverDiscarded() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let p = try profiles.add(.codex, name: "new")
        signInCodex(box, p, email: "x@example.com", account: "acct-1")
        #expect(throws: (any Error).self) { try profiles.discardUnsignedIn(p, keychain: MemoryCLIKeychain()) }
        #expect(FS.exists(URL(fileURLWithPath: p.path + "/auth.json")))
        // Nor the default account.
        try profiles.discardUnsignedIn(profiles.defaultProfile(.codex), keychain: MemoryCLIKeychain())
    }

    @Test func removeResetsThePointerAndKeepsTheDefaultFolder() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        box.write(box.home + "/.codex/sessions/one.jsonl", "keep")
        let p = try profiles.add(.codex, name: "work")
        try profiles.setActive(p)
        try profiles.remove(p, toTrash: false)
        #expect(!FS.exists(URL(fileURLWithPath: p.path)))
        #expect(profiles.active(.codex).isDefault)
        #expect(box.read(box.home + "/.codex/sessions/one.jsonl") == "keep")
        #expect(throws: (any Error).self) { try profiles.remove(profiles.defaultProfile(.codex), toTrash: false) }
        // Something outside the profiles folder is refused.
        let outside = CLIProfile(kind: .codex, name: "x", path: box.top + "/x", isDefault: false)
        box.mkdir(outside.path)
        #expect(throws: (any Error).self) { try profiles.remove(outside, toTrash: false) }
        #expect(FS.exists(URL(fileURLWithPath: outside.path)))
    }

    @Test func theLoginRunsInTheProfileWithNoTerminal() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let p = try profiles.add(.codex, name: "work")
        let fake = box.top + "/codex"
        box.write(fake, """
        #!/bin/sh
        [ -t 0 ] && echo "stdin is a terminal" && exit 3
        echo "login $*"
        printf '{"auth_mode":"chatgpt","tokens":{"refresh_token":"r","account_id":"a"}}' > "$CODEX_HOME/auth.json"

        """, mode: 0o755)
        let run = CLILoginRun(
            profile: p,
            binary: fake,
            workingDirectory: box.home,
            baseEnvironment: ["HOME": box.home, "PATH": "/usr/bin:/bin", "SWITCHER_BYPASS": "1"])
        try run.start()
        #expect(run.wait() == 0)
        let said = run.output()
        #expect(said.contains("login login"), "output: \(said)")
        #expect(profiles.signIn(p, keychain: MemoryCLIKeychain()).state == .signedIn)
    }

    @Test func cancelAndTimeoutStopAWaitingLogin() throws {
        let box = CLIBox()
        let p = try CLIProfiles(env: box.env).add(.codex, name: "work")
        let fake = box.top + "/codex"
        // Waits for the browser forever, like a real login nobody finishes.
        box.write(fake, "#!/bin/sh\nexec sleep 60\n", mode: 0o755)
        let run = CLILoginRun(
            profile: p,
            binary: fake,
            workingDirectory: box.home,
            baseEnvironment: ["HOME": box.home, "PATH": "/usr/bin:/bin"])
        try run.start()
        let started = Date()
        run.cancel(grace: 2)
        #expect(!run.isRunning)
        #expect(Date().timeIntervalSince(started) < 10)

        let run2 = CLILoginRun(
            profile: p,
            binary: fake,
            workingDirectory: box.home,
            baseEnvironment: ["HOME": box.home, "PATH": "/usr/bin:/bin"])
        try run2.start()
        #expect(!run2.wait(timeout: 0.3).exited)
        run2.cancel(grace: 1)
        #expect(!run2.isRunning)
    }

    @Test func agyLoginStagesHomeMovesTokenViaRenameAndCleansUp() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let p = try profiles.add(.agy, name: "work")
        let fake = box.top + "/agy"
        box.write(fake, """
        #!/bin/sh
        set -eu
        [ "${AGY_CLI_CDE_AUTH_ACTION-}" = "login" ] || exit 4
        [ -z "${ANTIGRAVITY_GEMINI_DIR+x}" ] || exit 5
        [ -f "$HOME/.gemini/cache/antigravity-keyring-unavailable" ] || exit 6
        printf '{"token":{"access_token":"a","refresh_token":"r-agy"},"id_token_email":"agy@example.com"}' > "$HOME/.gemini/jetski-standalone-oauth-token"

        """, mode: 0o755)
        let run = CLILoginRun(
            profile: p,
            binary: fake,
            workingDirectory: box.home,
            baseEnvironment: ["HOME": box.home, "PATH": "/usr/bin:/bin", "ANTIGRAVITY_GEMINI_DIR": "/other"])
        try run.start()
        #expect(run.wait() == 0)
        let tokenFile = p.path + "/antigravity-cli/antigravity-oauth-token"
        #expect(FS.exists(URL(fileURLWithPath: tokenFile)))
        #expect(box.mode(tokenFile) == 0o600)
        #expect(profiles.signIn(p, keychain: MemoryCLIKeychain()).state == .signedIn)
        #expect(profiles.identity(p, keychain: MemoryCLIKeychain())?.email == "agy@example.com")
        // Staging directory inside antigravity-cli was removed and real fake HOME was untouched.
        let children = try FileManager.default.contentsOfDirectory(atPath: p.path + "/antigravity-cli")
        #expect(!children.contains { $0.hasPrefix(".login-home-") })
        #expect(!FS.exists(URL(fileURLWithPath: box.home + "/.gemini/jetski-standalone-oauth-token")))

        // Failed login also removes its staging directory without creating a token file.
        let p2 = try profiles.add(.agy, name: "fail")
        let failFake = box.top + "/agy-fail"
        box.write(failFake, "#!/bin/sh\nexit 2\n", mode: 0o755)
        let failRun = CLILoginRun(profile: p2, binary: failFake, workingDirectory: box.home, baseEnvironment: ["HOME": box.home, "PATH": "/usr/bin:/bin"])
        try failRun.start()
        #expect(failRun.wait() == 2)
        let children2 = try FileManager.default.contentsOfDirectory(atPath: p2.path + "/antigravity-cli")
        #expect(!children2.contains { $0.hasPrefix(".login-home-") })
        #expect(!FS.exists(URL(fileURLWithPath: p2.path + "/antigravity-cli/antigravity-oauth-token")))
    }

    @Test func agyReloginPromotionFailureSurfacesNonZeroInsteadOfMaskingOldToken() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let p = try profiles.add(.agy, name: "work")
        let tokenFile = p.path + "/antigravity-cli/antigravity-oauth-token"
        box.write(tokenFile, box.json(["token": ["access_token": "old", "refresh_token": "r-old"], "id_token_email": "old@example.com"]), mode: 0o600)

        // Child exits 0 without writing staged jetski-standalone-oauth-token.
        let noWrite = box.top + "/agy-nowrite"
        box.write(noWrite, "#!/bin/sh\nexit 0\n", mode: 0o755)
        let run1 = CLILoginRun(profile: p, binary: noWrite, workingDirectory: box.home, baseEnvironment: ["HOME": box.home, "PATH": "/usr/bin:/bin"])
        try run1.start()
        #expect(run1.wait() == 1)
        #expect(run1.promotionError != nil)
        #expect(run1.output().contains("without writing a sign-in token"))
        #expect(profiles.identity(p, keychain: MemoryCLIKeychain())?.email == "old@example.com")
        let left1 = try FileManager.default.contentsOfDirectory(atPath: p.path + "/antigravity-cli")
        #expect(!left1.contains { $0.hasPrefix(".login-home-") })

        // Destination replaced by a directory: promotion fails, surfaces non-zero, cleans up staging.
        let pDir = try profiles.add(.agy, name: "bad-dest")
        box.mkdir(pDir.path + "/antigravity-cli/antigravity-oauth-token")
        let goodChild = box.top + "/agy-good"
        box.write(goodChild, """
        #!/bin/sh
        printf '{"token":{"refresh_token":"r-new"}}' > "$HOME/.gemini/jetski-standalone-oauth-token"
        """, mode: 0o755)
        let run2 = CLILoginRun(profile: pDir, binary: goodChild, workingDirectory: box.home, baseEnvironment: ["HOME": box.home, "PATH": "/usr/bin:/bin"])
        try run2.start()
        #expect(run2.wait() == 1)
        #expect(run2.promotionError != nil)
        let left2 = try FileManager.default.contentsOfDirectory(atPath: pDir.path + "/antigravity-cli")
        #expect(!left2.contains { $0.hasPrefix(".login-home-") })
    }
}

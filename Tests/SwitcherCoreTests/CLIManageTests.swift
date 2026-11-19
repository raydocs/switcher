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
        let run = CLILoginRun(profile: p, binary: fake, baseEnvironment: ["PATH": "/usr/bin:/bin", "SWITCHER_BYPASS": "1"])
        try run.start()
        #expect(run.wait() == 0)
        let said = run.output()
        #expect(said.contains("login login"), "output: \(said)")
        #expect(profiles.signIn(p, keychain: MemoryCLIKeychain()).state == .signedIn)
    }

    @Test func cancelStopsAWaitingLogin() throws {
        let box = CLIBox()
        let p = try CLIProfiles(env: box.env).add(.codex, name: "work")
        let fake = box.top + "/codex"
        // Waits for the browser forever, like a real login nobody finishes.
        box.write(fake, "#!/bin/sh\nexec sleep 60\n", mode: 0o755)
        let run = CLILoginRun(profile: p, binary: fake, baseEnvironment: ["PATH": "/usr/bin:/bin"])
        try run.start()
        let started = Date()
        run.cancel(grace: 2)
        #expect(!run.isRunning)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func cliMetaAliasesValidateResolveAndCleanUpOnRemove() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let work = try profiles.add(.claude, name: "work")
        let side = try profiles.add(.claude, name: "side")
        let codexWork = try profiles.add(.codex, name: "work")

        // Validation: length, control chars, digits-only, duplicates per kind (case-insensitive).
        try CLIMeta.edit(box.env) { meta in
            try meta.setAlias(kind: .claude, name: "work", "Work Main")
            #expect(throws: (any Error).self) { try meta.setAlias(kind: .claude, name: "side", "work main") }
            #expect(throws: (any Error).self) { try meta.setAlias(kind: .claude, name: "side", "12345") }
            #expect(throws: (any Error).self) { try meta.setAlias(kind: .claude, name: "side", String(repeating: "a", count: 33)) }
            #expect(throws: (any Error).self) { try meta.setAlias(kind: .claude, name: "side", "bad\nname") }
            // Different CLI kind can use the same alias.
            try meta.setAlias(kind: .codex, name: "work", "Work Main")
            try meta.setAlias(kind: .claude, name: "side", "个人")
        }

        // File is private (0600) and survives reload.
        var st = stat()
        #expect(stat(CLIMeta.url(box.env).path, &st) == 0 && (st.st_mode & 0o777) == 0o600)
        let loaded = CLIMeta.load(box.env)
        #expect(loaded.alias(for: work) == "Work Main")
        #expect(loaded.alias(for: side) == "个人")
        #expect(loaded.alias(for: codexWork) == "Work Main")

        // CLIProfiles.resolve matches aliases case-insensitively without renaming folders.
        #expect(profiles.resolve(.claude, "work main")?.path == work.path)
        #expect(profiles.resolve(.claude, "个人")?.path == side.path)
        #expect(profiles.resolve(.codex, "Work Main")?.path == codexWork.path)

        // CLICommands.list populates alias and renders it in line().
        let groups = CLICommands.list(profiles, keychain: MemoryCLIKeychain())
        let workEntry = groups.first { $0.cli == "claude" }?.profiles.first { $0.name == "work" }
        #expect(workEntry?.alias == "Work Main")
        #expect(workEntry?.line().contains("Work Main (work)") == true)

        // Clearing an alias with empty string or nil removes it.
        try CLIMeta.edit(box.env) { try $0.setAlias(kind: .claude, name: "side", "   ") }
        #expect(CLIMeta.load(box.env).alias(for: side) == nil)

        // Removing a profile clears its alias too.
        try profiles.remove(work, toTrash: false)
        #expect(CLIMeta.load(box.env).alias(for: work) == nil)
        #expect(CLIMeta.load(box.env).alias(for: codexWork) == "Work Main")
    }

    @Test func launchCommandMatchesProfileType() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env)
        let defClaude = profiles.defaultProfile(.claude)
        let workClaude = try profiles.add(.claude, name: "work")
        let defCodex = profiles.defaultProfile(.codex)
        let altCodex = try profiles.add(.codex, name: "alt")

        #expect(CLIKind.claude.launchCommand(defClaude) == "env -u CLAUDE_CONFIG_DIR SWITCHER_BYPASS=1 claude")
        #expect(CLIKind.claude.launchCommand(workClaude) == "CLAUDE_CONFIG_DIR='\(workClaude.path)' claude")
        #expect(CLIKind.codex.launchCommand(defCodex) == "env -u CODEX_HOME SWITCHER_BYPASS=1 codex")
        #expect(CLIKind.codex.launchCommand(altCodex) == "CODEX_HOME='\(altCodex.path)' codex")
    }
}

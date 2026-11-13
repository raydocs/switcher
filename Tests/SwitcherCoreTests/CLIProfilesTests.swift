import Foundation
import Testing
@testable import SwitcherCore

@Suite struct CLIKeychainServiceTests {
    @Test func noConfigDirIsTheBareService() {
        #expect(claudeKeychainService(configDir: nil) == "Claude Code-credentials")
    }

    // Measured against the real claude CLI.
    @Test(arguments: [
        ("/Users/ruirui/.claude", "e82e953b"),
        ("/private/tmp/claude-501/-Users-ruirui/cf7a2281-a5c9-4ba2-bc05-4f29e1f5477a/scratchpad/kc/real-profile", "bb154569"),
        ("/private/tmp/claude-501/-Users-ruirui/cf7a2281-a5c9-4ba2-bc05-4f29e1f5477a/scratchpad/kc/real-profile/", "8e6f52bc"),
        ("/private/tmp/claude-501/-Users-ruirui/cf7a2281-a5c9-4ba2-bc05-4f29e1f5477a/scratchpad/kc/link-profile", "d489b4e6"),
    ])
    func knownVectors(path: String, suffix: String) {
        #expect(claudeKeychainService(configDir: path) == "Claude Code-credentials-" + suffix)
    }

    @Test func sha256StandardVectors() {
        #expect(SHA256.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Two blocks.
        #expect(SHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}

@Suite struct CLIPathTests {
    @Test func validNames() {
        for n in ["work", "Work2", "a-b", "a_b", "a.b", "x", String(repeating: "a", count: 64)] {
            #expect(CLIPath.isValidName(n), "\(n)")
        }
    }

    @Test func invalidNames() {
        for n in ["", "default", ".x", "-x", "a/b", "a/", "/a", "..", "a'b", "a\"b", "a b", " a", "a\n", "é", "a$b", "a;b",
                  String(repeating: "a", count: 65)] {
            #expect(!CLIPath.isValidName(n), "\(n.debugDescription)")
        }
    }

    @Test func problemPaths() {
        let root = "/h/.claude-profiles"
        #expect(CLIPath.problem(root + "/work", root: root) == nil)
        #expect(CLIPath.problem("/elsewhere/work", root: root) != nil)
        #expect(CLIPath.problem(root, root: root) != nil)
        #expect(CLIPath.problem(root + "/", root: root) != nil)
        #expect(CLIPath.problem(root + "/work/", root: root) != nil)
        #expect(CLIPath.problem(root + "/a/b", root: root) != nil)
        #expect(CLIPath.problem(root + "/..", root: root) != nil)
        #expect(CLIPath.problem(root + "/.hidden", root: root) != nil)
        #expect(CLIPath.problem(root + "/default", root: root) != nil)
        #expect(CLIPath.problem(root + "/a b", root: root) != nil)
        #expect(CLIPath.problem(root + "/a'b", root: root) != nil)
        #expect(CLIPath.problem(root + "x/work", root: root) != nil)
    }

    @Test func envTrimsTheHomeButNothingElse() {
        #expect(CLIEnv(home: "/a/b///").home == "/a/b")
        #expect(CLIEnv(home: "/").home == "/")
    }

    @Test func loginCommandsQuoteThePath() {
        let p = CLIProfile(kind: .claude, name: "o'k", path: "/h/o'k", isDefault: false)
        #expect(CLIKind.claude.loginCommand(p).hasPrefix("CLAUDE_CONFIG_DIR='/h/o'\\''k' claude"))
        let d = CLIProfiles(env: CLIEnv(home: "/h")).defaultProfile(.codex)
        #expect(CLIKind.codex.loginCommand(d) == "env -u CODEX_HOME SWITCHER_BYPASS=1 codex login")
        let dc = CLIProfiles(env: CLIEnv(home: "/h")).defaultProfile(.claude)
        #expect(CLIKind.claude.loginCommand(dc) == "env -u CLAUDE_CONFIG_DIR SWITCHER_BYPASS=1 claude   # then type /login")
    }
}

@Suite struct CLIRegistryTests {
    func make(_ box: CLIBox, kind: CLIKind = .claude, dirs: [String] = []) -> (CLIProfiles, String) {
        let profiles = CLIProfiles(env: box.env)
        let root = box.env.profilesRoot(kind)
        for d in dirs { box.mkdir(root + "/" + d) }
        return (profiles, root)
    }

    @Test func listOrderSkipsLinksFilesAndOddNames() {
        let box = CLIBox()
        let (profiles, root) = make(box, dirs: ["b", "a", "c-1", ".hidden", "has space"])
        box.write(root + "/file", "x")
        box.mkdir(box.top + "/elsewhere")
        box.symlink(root + "/linked", to: box.top + "/elsewhere")
        let l = profiles.list(.claude)
        #expect(l.map(\.name) == ["default", "a", "b", "c-1"])
        #expect(l[0].isDefault && l[0].path == box.home + "/.claude" && l[0].envValue == nil)
        #expect(l[1].envValue == root + "/a")
        #expect(profiles.list(.codex).map(\.name) == ["default"])
    }

    @Test func resolveByNumberNameAndCase() {
        let box = CLIBox()
        let (profiles, root) = make(box, dirs: ["b", "a"])
        #expect(profiles.resolve(.claude, "1")?.isDefault == true)
        #expect(profiles.resolve(.claude, "2")?.path == root + "/a")
        #expect(profiles.resolve(.claude, "3")?.path == root + "/b")
        #expect(profiles.resolve(.claude, "4") == nil)
        #expect(profiles.resolve(.claude, "0") == nil)
        #expect(profiles.resolve(.claude, "a")?.name == "a")
        #expect(profiles.resolve(.claude, "A")?.name == "a")
        #expect(profiles.resolve(.claude, "default")?.isDefault == true)
        #expect(profiles.resolve(.claude, "DEFAULT")?.isDefault == true)
        #expect(profiles.resolve(.claude, "nope") == nil)
    }

    @Test func activeReadsThePointer() {
        let box = CLIBox()
        let (profiles, root) = make(box, dirs: ["a"])
        let pointer = box.env.pointer(.claude)
        // Missing pointer.
        #expect(profiles.active(.claude).isDefault)
        // `default`.
        box.write(pointer, "default\n")
        #expect(profiles.active(.claude).isDefault)
        // Valid, with and without the newline.
        box.write(pointer, root + "/a\n")
        #expect(profiles.active(.claude).path == root + "/a")
        #expect(profiles.active(.claude).name == "a")
        box.write(pointer, root + "/a")
        #expect(profiles.active(.claude).path == root + "/a")
        // Invalid: trailing slash, outside root, nonexistent, nested, empty.
        for bad in [root + "/a/\n", box.top + "/a\n", root + "/gone\n", root + "/a/b\n", "\n", "relative\n", root + "/.a\n"] {
            box.write(pointer, bad)
            #expect(profiles.active(.claude).isDefault, "\(bad.debugDescription)")
        }
        // A symlinked folder is not a profile.
        box.symlink(root + "/s", to: root + "/a")
        box.write(pointer, root + "/s\n")
        #expect(profiles.active(.claude).isDefault)
    }

    @Test func setActiveWritesAtomicallyAndRefusesInvalidProfiles() throws {
        let box = CLIBox()
        let (profiles, root) = make(box, dirs: ["a"])
        let a = profiles.resolve(.claude, "a")!
        try profiles.setActive(a)
        #expect(box.read(box.env.pointer(.claude)) == root + "/a\n")
        #expect(box.mode(box.env.config) == 0o700)
        #expect((try FileManager.default.contentsOfDirectory(atPath: box.env.config)).sorted() == ["active-claude"])
        try profiles.setActive(profiles.defaultProfile(.claude))
        #expect(box.read(box.env.pointer(.claude)) == "default\n")

        try profiles.setActive(a)
        box.mkdir(box.top + "/outside")
        box.symlink(root + "/s", to: root + "/a")
        let bad = [
            CLIProfile(kind: .claude, name: "x", path: box.top + "/outside", isDefault: false),
            CLIProfile(kind: .claude, name: "gone", path: root + "/gone", isDefault: false),
            CLIProfile(kind: .claude, name: "a", path: root + "/a/", isDefault: false),
            CLIProfile(kind: .claude, name: "s", path: root + "/s", isDefault: false),
            CLIProfile(kind: .claude, name: "q", path: root + "/it's", isDefault: false),
            CLIProfile(kind: .codex, name: "a", path: root + "/a", isDefault: false),
        ]
        for p in bad {
            #expect(throws: (any Error).self) { try profiles.setActive(p) }
        }
        // The pointer is untouched by the refusals.
        #expect(box.read(box.env.pointer(.claude)) == root + "/a\n")
        #expect(!FS.exists(URL(fileURLWithPath: box.env.pointer(.codex))))
    }

    @Test func nextWraps() throws {
        let box = CLIBox()
        let (profiles, _) = make(box, dirs: ["a", "b"])
        #expect(profiles.next(.claude)?.name == "a")
        try profiles.setActive(profiles.resolve(.claude, "a")!)
        #expect(profiles.next(.claude)?.name == "b")
        try profiles.setActive(profiles.resolve(.claude, "b")!)
        #expect(profiles.next(.claude)?.isDefault == true)
        // Only the default account: nothing to switch to.
        #expect(profiles.next(.codex) == nil)
    }
}

@Suite struct CLIAddAndLinksTests {
    func claudeWorld(_ box: CLIBox) -> CLIProfiles {
        let d = box.env.defaultFolder(.claude)
        box.mkdir(d + "/skills")
        box.write(d + "/CLAUDE.md", "rules")
        box.write(d + "/settings.json", "{}")
        box.write(d + "/.credentials.json", "secret")
        return CLIProfiles(env: box.env)
    }

    @Test func addMakesA0700FolderAndLinksOnlyWhatExists() throws {
        let box = CLIBox()
        let profiles = claudeWorld(box)
        let p = try profiles.add(.claude, name: "work")
        #expect(p.path == box.home + "/.claude-profiles/work" && !p.isDefault)
        #expect(box.mode(p.path) == 0o700)
        #expect(box.mode(box.env.profilesRoot(.claude)) == 0o700)
        let names = Set((try FileManager.default.contentsOfDirectory(atPath: p.path)))
        #expect(names == ["skills", "CLAUDE.md", "settings.json"])
        for n in names {
            #expect(box.isLink(p.path + "/" + n))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: p.path + "/" + n) == box.home + "/.claude/" + n)
        }
        // Sign-ins are never shared.
        #expect(!FS.exists(URL(fileURLWithPath: p.path + "/.credentials.json")))
        #expect(profiles.list(.claude).map(\.name) == ["default", "work"])
    }

    @Test func addSeedsOnlyTheAllowedClaudeKeys() throws {
        let box = CLIBox()
        let profiles = claudeWorld(box)
        box.write(box.home + "/.claude.json", box.json([
            "oauthAccount": ["emailAddress": "me@example.com"], "userID": "u-1",
            "mcpServers": ["a": ["command": "x"]], "projects": ["/p": ["trusted": true]],
            "hasCompletedOnboarding": true, "theme": "dark", "numStartups": 9, "cachedStatsigGates": [:],
        ]))
        let p = try profiles.add(.claude, name: "work")
        let seeded = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p.path + "/.claude.json"))) as! [String: Any]
        #expect(Set(seeded.keys) == Set(CLIProfiles.seededClaudeKeys))
        #expect(seeded["oauthAccount"] == nil && seeded["userID"] == nil)
        #expect((seeded["mcpServers"] as? [String: Any])?.keys.contains("a") == true)
        // The default file is untouched.
        #expect(box.read(box.home + "/.claude.json")!.contains("oauthAccount"))
        #expect(profiles.identity(p) == nil)
    }

    @Test func addWritesNoClaudeJSONWithNothingToSeed() throws {
        let box = CLIBox()
        let profiles = claudeWorld(box)
        box.write(box.home + "/.claude.json", box.json(["oauthAccount": ["emailAddress": "me@example.com"], "userID": "u"]))
        let p = try profiles.add(.claude, name: "work")
        #expect(!FS.exists(URL(fileURLWithPath: p.path + "/.claude.json")))
    }

    @Test func addForCodexLinksButNeverSeeds() throws {
        let box = CLIBox()
        let d = box.env.defaultFolder(.codex)
        box.write(d + "/config.toml", "x = 1")
        box.write(d + "/auth.json", "{}")
        box.write(box.home + "/.claude.json", box.json(["theme": "dark"]))
        let p = try CLIProfiles(env: box.env).add(.codex, name: "alt")
        #expect(p.path == box.home + "/.codex-profiles/alt")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: p.path)) == ["config.toml"])
    }

    @Test func addRefusesExistingFoldersAndBadNames() throws {
        let box = CLIBox()
        let profiles = claudeWorld(box)
        _ = try profiles.add(.claude, name: "work")
        #expect(throws: (any Error).self) { try profiles.add(.claude, name: "work") }
        box.symlink(box.home + "/.claude-profiles/lnk", to: box.top)
        #expect(throws: (any Error).self) { try profiles.add(.claude, name: "lnk") }
        for bad in ["default", ".x", "-x", "a/b", "a/", "", "a b", "a'b"] {
            #expect(throws: (any Error).self) { try profiles.add(.claude, name: bad) }
        }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: box.env.profilesRoot(.claude))) == ["work", "lnk"])
    }

    // Found on the owner's Mac: a shared config.toml naming './instruction.sol.md' made Codex
    // refuse to start in a new profile.
    @Test func codexConfigRelativeFilesAreLinked() throws {
        let box = CLIBox()
        let profiles = CLIProfiles(env: box.env())
        let home = box.home + "/.codex"
        box.write(home + "/config.toml", """
        model_instructions_file = './instruction.md'
        experimental_instructions_file = "notes/extra.md"
        auth_file = './auth.json'
        other_file = '/abs/path.md'
        up_file = '../outside.md'
        gone_file = './missing.md'
        name = './not-a-file-key-but-relative.md'
        """)
        box.write(home + "/instruction.md", "x")
        box.write(home + "/notes/extra.md", "x")
        box.write(home + "/auth.json", "{}")
        box.write(home + "/not-a-file-key-but-relative.md", "x")
        let p = try profiles.add(.codex, name: "work")
        #expect(box.isLink(p.path + "/instruction.md"))
        #expect(box.isLink(p.path + "/notes"))
        #expect(box.isLink(p.path + "/not-a-file-key-but-relative.md"))
        #expect(!FS.exists(URL(fileURLWithPath: p.path + "/auth.json")))
        #expect(!FS.exists(URL(fileURLWithPath: p.path + "/missing.md")))
        #expect(profiles.checkLinks(p).allSatisfy { $0.state == .ok || $0.state == .nothingToShare })
    }

    @Test func checkLinksStates() throws {
        let box = CLIBox()
        let profiles = claudeWorld(box)
        let p = try profiles.add(.claude, name: "work")
        func state(_ item: String) -> CLIProfiles.LinkState { profiles.checkLinks(p).first { $0.item == item }!.state }
        #expect(state("skills") == .ok)
        #expect(state("hooks") == .nothingToShare)
        #expect(profiles.checkLinks(p).count == CLIProfiles.sharedItems(.claude).count)
        // The default folder grows an item.
        box.mkdir(box.home + "/.claude/hooks")
        #expect(state("hooks") == .missing)
        // A link to somewhere else.
        unlink(p.path + "/skills")
        box.symlink(p.path + "/skills", to: box.top + "/other")
        #expect(state("skills") == .wrongTarget(box.top + "/other"))
        // A real file in a link's place.
        unlink(p.path + "/settings.json")
        box.write(p.path + "/settings.json", "{\"mine\":1}")
        #expect(state("settings.json") == .replaced)
        // The default account has nothing to link.
        #expect(profiles.checkLinks(profiles.defaultProfile(.claude)).isEmpty)
    }

    // Review finding 5: a profile folder swapped for a symlink never lets links or files land outside.
    @Test func writesRefuseAProfileFolderSwappedForASymlink() throws {
        let box = CLIBox()
        let profiles = claudeWorld(box)
        box.write(box.home + "/.claude.json", "{\"mcpServers\":{\"a\":{}},\"theme\":\"dark\"}")
        let p = try profiles.add(.claude, name: "work")
        let outside = box.top + "/outside"
        box.mkdir(outside)
        try FileManager.default.removeItem(atPath: p.path)
        box.symlink(p.path, to: outside)
        #expect(throws: (any Error).self) { try profiles.applyLinks(p) }
        #expect(throws: (any Error).self) { try profiles.seedClaudeJSON(p) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
        #expect(profiles.checkLinks(p).isEmpty)
    }

    @Test func writesRefuseASymlinkedProfilesRoot() throws {
        let box = CLIBox()
        let profiles = claudeWorld(box)
        let outside = box.top + "/outside"
        box.mkdir(outside + "/work")
        box.symlink(box.env.profilesRoot(.claude), to: outside)
        #expect(throws: (any Error).self) { try profiles.add(.claude, name: "new") }
        let p = CLIProfile(kind: .claude, name: "work", path: box.env.profilesRoot(.claude) + "/work", isDefault: false)
        #expect(throws: (any Error).self) { try profiles.applyLinks(p) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside) == ["work"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside + "/work").isEmpty)
    }

    @Test func applyLinksIsIdempotentAndNeverOverwrites() throws {
        let box = CLIBox()
        let profiles = claudeWorld(box)
        let p = try profiles.add(.claude, name: "work")
        box.mkdir(box.home + "/.claude/hooks")
        box.write(box.home + "/.claude/keybindings.json", "{}")
        unlink(p.path + "/settings.json")
        box.write(p.path + "/settings.json", "{\"mine\":1}")
        unlink(p.path + "/skills")
        box.symlink(p.path + "/skills", to: box.top + "/other")
        box.write(p.path + "/keybindings.json", "mine")

        #expect(try profiles.applyLinks(p) == ["hooks"])
        #expect(try profiles.applyLinks(p).isEmpty)
        #expect(box.read(p.path + "/settings.json") == "{\"mine\":1}")
        #expect(box.read(p.path + "/keybindings.json") == "mine")
        #expect(!box.isLink(p.path + "/keybindings.json"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: p.path + "/skills") == box.top + "/other")
        #expect(box.isLink(p.path + "/hooks"))
        #expect(try profiles.applyLinks(profiles.defaultProfile(.claude)).isEmpty)
    }

    @Test func mcpDifference() throws {
        let box = CLIBox()
        let profiles = claudeWorld(box)
        box.write(box.home + "/.claude.json", box.json(["mcpServers": ["a": [:], "b": [:]]]))
        let p = try profiles.add(.claude, name: "work")
        box.write(p.path + "/.claude.json", box.json(["mcpServers": ["b": [:], "c": [:]]]))
        let d = profiles.mcpDifference(p)
        #expect(d.missing == ["a"] && d.extra == ["c"])
        #expect(profiles.mcpDifference(profiles.defaultProfile(.claude)).missing.isEmpty)
        let codex = CLIProfile(kind: .codex, name: "x", path: box.top + "/x", isDefault: false)
        #expect(profiles.mcpDifference(codex).missing.isEmpty)
        // No file at all on the profile side.
        let q = try profiles.add(.claude, name: "bare")
        try? FileManager.default.removeItem(atPath: q.path + "/.claude.json")
        #expect(profiles.mcpDifference(q).missing == ["a", "b"])
    }
}

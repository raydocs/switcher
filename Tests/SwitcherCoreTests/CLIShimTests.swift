import Foundation
import Testing
@testable import SwitcherCore

/// Runs the generated shim for real with /bin/sh against a fake binary.
@Suite struct CLIShimBehaviourTests {
    struct Run {
        var status: Int32
        var lines: [String]
        var stderr: String
        func value(_ name: String) -> String? { lines.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) } }
        var args: [String] { lines.filter { $0.hasPrefix("arg=[") }.map { String($0.dropFirst(5).dropLast()) } }
    }

    struct World {
        let box: CLIBox
        let env: CLIEnv
        let profiles: CLIProfiles
        var root: String { env.profilesRoot(.claude) }
        func pointer(_ text: String?, _ kind: CLIKind = .claude) {
            if let text { box.write(env.pointer(kind), text) } else { try? FileManager.default.removeItem(atPath: env.pointer(kind)) }
        }
        func run(_ kind: CLIKind = .claude, extra: [String: String] = [:], args: [String] = []) throws -> Run {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [env.shim(kind)] + args
            p.environment = ["PATH": "/usr/bin:/bin"].merging(extra) { $1 }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return Run(status: p.terminationStatus, lines: String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                       stderr: String(decoding: e, as: UTF8.self))
        }
    }

    func world(homeName: String = "home") throws -> World {
        let box = CLIBox(homeName: homeName)
        let claude = box.fakeBinary(box.top + "/bin/claude-real")
        let codex = box.fakeBinary(box.top + "/bin/codex-real")
        let env = box.env(realClaude: claude, realCodex: codex)
        try CLIShim.installShims(env: env)
        box.mkdir(env.profilesRoot(.claude) + "/a")
        box.mkdir(env.profilesRoot(.codex) + "/a")
        return World(box: box, env: env, profiles: CLIProfiles(env: env))
    }

    @Test func installWritesExecutableShims() throws {
        let w = try world()
        for kind in CLIKind.allCases {
            #expect(w.box.mode(w.env.shim(kind)) == 0o755)
            #expect(CLIShim.isShim(w.env.shim(kind)))
        }
        #expect(CLIShim.realBinary(ofShim: w.env.shim(.claude)) == w.box.top + "/bin/claude-real")
    }

    @Test func noPointerLeavesTheVariableUnset() throws {
        let w = try world()
        let r = try w.run()
        #expect(r.status == 0)
        #expect(r.value("CLAUDE_CONFIG_DIR") == "<unset>")
        #expect(r.value("CODEX_HOME") == "<unset>")
    }

    @Test func defaultPointerLeavesItUnset() throws {
        let w = try world()
        w.pointer("default\n")
        #expect(try w.run().value("CLAUDE_CONFIG_DIR") == "<unset>")
    }

    @Test func validProfileIsSetToTheExactString() throws {
        let w = try world()
        w.pointer(w.root + "/a\n")
        #expect(try w.run().value("CLAUDE_CONFIG_DIR") == w.root + "/a")
        // No trailing newline in the pointer file works too.
        w.pointer(w.root + "/a")
        #expect(try w.run().value("CLAUDE_CONFIG_DIR") == w.root + "/a")
        // The shims are independent per CLI.
        w.pointer(w.env.profilesRoot(.codex) + "/a\n", .codex)
        let codex = try w.run(.codex)
        #expect(codex.value("CODEX_HOME") == w.env.profilesRoot(.codex) + "/a")
        #expect(codex.value("CLAUDE_CONFIG_DIR") == "<unset>")
        // The shim matches what the app computes.
        #expect(w.profiles.active(.claude).envValue == w.root + "/a")
    }

    @Test func invalidPointersLeaveItUnset() throws {
        let w = try world()
        w.box.mkdir(w.box.top + "/outside")
        w.box.symlink(w.root + "/linked", to: w.root + "/a")
        w.box.mkdir(w.root + "/a/b")
        w.box.mkdir(w.root + "/.hid")
        w.box.write(w.root + "/afile", "x")
        for bad in [w.root + "/a/\n", w.box.top + "/outside\n", w.root + "/gone\n", w.root + "/linked\n", w.root + "/a/b\n",
                    w.root + "/.hid\n", w.root + "/afile\n", w.root + "/\n", w.root + "\n", "relative\n", "garbage with spaces\n"] {
            w.pointer(bad)
            let r = try w.run()
            #expect(r.status == 0)
            #expect(r.value("CLAUDE_CONFIG_DIR") == "<unset>", "\(bad.debugDescription)")
            // The app reads the same pointer the same way.
            #expect(w.profiles.active(.claude).isDefault, "\(bad.debugDescription)")
        }
    }

    @Test func aVariableAlreadySetPassesThroughUnchanged() throws {
        let w = try world()
        w.pointer(w.root + "/a\n")
        #expect(try w.run(extra: ["CLAUDE_CONFIG_DIR": "/somewhere/else"]).value("CLAUDE_CONFIG_DIR") == "/somewhere/else")
        // Set but empty is still set.
        let r = try w.run(extra: ["CLAUDE_CONFIG_DIR": ""])
        #expect(r.value("CLAUDE_CONFIG_DIR") == "")
        // The other CLI's variable does not stop this one from being chosen.
        #expect(try w.run(extra: ["CODEX_HOME": "/x"]).value("CLAUDE_CONFIG_DIR") == w.root + "/a")
    }

    @Test func bypassLeavesItUnset() throws {
        let w = try world()
        w.pointer(w.root + "/a\n")
        #expect(try w.run(extra: ["SWITCHER_BYPASS": "1"]).value("CLAUDE_CONFIG_DIR") == "<unset>")
        #expect(try w.run(extra: ["SWITCHER_BYPASS": "0"]).value("CLAUDE_CONFIG_DIR") == w.root + "/a")
    }

    @Test func argumentsArriveIntact() throws {
        let w = try world()
        let args = ["plain", "two words", "it's", "say \"hi\"", "$HOME", "`x`", "a;b", "*", "-p", "", "  lead"]
        let r = try w.run(args: args)
        #expect(r.status == 0)
        #expect(r.args == args)
    }

    @Test func aHomeWithASpaceAndAQuoteWorks() throws {
        let w = try world(homeName: "my ho'me")
        w.pointer(w.root + "/a\n")
        let r = try w.run(args: ["x y"])
        #expect(r.status == 0)
        #expect(r.value("CLAUDE_CONFIG_DIR") == w.root + "/a")
        #expect(r.value("CLAUDE_CONFIG_DIR")!.contains("my ho'me"))
        #expect(r.args == ["x y"])
        #expect(w.profiles.active(.claude).envValue == w.root + "/a")
        #expect(CLIShim.realBinary(ofShim: w.env.shim(.claude)) == w.box.top + "/bin/claude-real")
    }

    @Test func aRealBinaryWithAQuoteRoundTrips() throws {
        let box = CLIBox()
        let real = box.fakeBinary(box.top + "/b'in dir/claude")
        let env = box.env(realClaude: real)
        try CLIShim.installShims(env: env)
        #expect(CLIShim.realBinary(ofShim: env.shim(.claude)) == real)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [env.shim(.claude), "ok"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0 && text.contains("arg=[ok]"))
    }

    @Test func aShimWhoseRealBinaryIsItselfExits127() throws {
        let box = CLIBox()
        let env = box.env(realClaude: box.home + "/.local/share/switcher/bin/claude")
        try CLIShim.installShims(env: env)
        let w = World(box: box, env: env, profiles: CLIProfiles(env: env))
        let r = try w.run()
        #expect(r.status == 127)
        #expect(r.stderr.contains("points at itself"))
        #expect(r.lines.allSatisfy { !$0.hasPrefix("CLAUDE_CONFIG_DIR") })
    }
}

@Suite struct CLIShimFindingTests {
    @Test func findRealBinarySkipsShimsAndTheShimDir() throws {
        let box = CLIBox()
        let env = box.env
        // A shim in the shim dir (first on PATH), a foreign shim elsewhere, then the real one.
        let shimDir = env.shimDir
        let foreign = box.top + "/foreign"
        let realDir = box.top + "/real"
        box.write(shimDir + "/claude", "#!/bin/sh\n\(CLIShim.marker) claude\n", mode: 0o755)
        box.write(foreign + "/claude", "#!/bin/sh\n\(CLIShim.marker) claude\nexec x\n", mode: 0o755)
        box.fakeBinary(realDir + "/claude")
        let path = [shimDir, foreign, realDir].joined(separator: ":")
        #expect(CLIShim.findRealBinary(.claude, env: env, path: path) == realDir + "/claude")
        // A trailing slash on a PATH entry still finds it.
        #expect(CLIShim.findRealBinary(.claude, env: env, path: realDir + "/") == realDir + "/claude")
        // Not executable: skipped.
        box.write(box.top + "/noexec/claude", "#!/bin/sh\n", mode: 0o644)
        #expect(CLIShim.findRealBinary(.claude, env: env, path: box.top + "/noexec") == nil)
        // Claude's own launcher wins over PATH.
        box.fakeBinary(box.home + "/.local/bin/claude")
        #expect(CLIShim.findRealBinary(.claude, env: env, path: realDir) == box.home + "/.local/bin/claude")
        // A given binary is used as is.
        #expect(CLIShim.findRealBinary(.claude, env: box.env(realClaude: "/given/claude"), path: realDir) == "/given/claude")
    }

    @Test func codexIsFoundOnPathAndNotConfusedWithClaude() {
        let box = CLIBox()
        box.fakeBinary(box.top + "/real/codex")
        #expect(CLIShim.findRealBinary(.codex, env: box.env, path: box.top + "/real") == box.top + "/real/codex")
        #expect(CLIShim.findRealBinary(.claude, env: box.env, path: box.top + "/real") == nil)
    }

    @Test func installShimsFindsBinariesOnThePathAndSkipsMissingOnes() throws {
        let box = CLIBox()
        box.fakeBinary(box.top + "/real/claude")
        let env = box.env
        let made = try CLIShim.installShims(env: env, path: env.shimDir + ":" + box.top + "/real")
        #expect(made[.claude] == box.top + "/real/claude")
        #expect(CLIShim.realBinary(ofShim: env.shim(.claude)) == box.top + "/real/claude")
        // Installing again (now the shim is first on PATH) still finds the real binary.
        let again = try CLIShim.installShims(env: env, path: env.shimDir + ":" + box.top + "/real")
        #expect(again[.claude] == box.top + "/real/claude")
    }

    @Test func realBinaryOfShimRejectsOtherFiles() {
        let box = CLIBox()
        box.write(box.top + "/plain", "real='/x'\n")
        #expect(CLIShim.realBinary(ofShim: box.top + "/plain") == nil)
        #expect(CLIShim.realBinary(ofShim: box.top + "/missing") == nil)
        #expect(!CLIShim.isShim(box.top + "/plain"))
        #expect(!CLIShim.isShim(box.top + "/missing"))
    }

    @Test func uninstallRemovesOnlyShims() throws {
        let box = CLIBox()
        let env = box.env(realClaude: box.fakeBinary(box.top + "/r/claude"), realCodex: box.fakeBinary(box.top + "/r/codex"))
        try CLIShim.installShims(env: env)
        box.write(env.shim(.codex), "#!/bin/sh\necho mine\n", mode: 0o755)
        CLIShim.uninstallShims(env: env)
        #expect(!FS.exists(URL(fileURLWithPath: env.shim(.claude))))
        #expect(FS.exists(URL(fileURLWithPath: env.shim(.codex))))
    }
}

@Suite struct CLIShimRCTests {
    func rc(_ box: CLIBox, _ text: String?, mode: Int = 0o644) -> String {
        let path = box.home + "/.zshrc"
        if let text { box.write(path, text, mode: mode) }
        return path
    }

    @Test func appendsTheBlockAtTheEnd() throws {
        let box = CLIBox()
        let path = rc(box, "export A=1\nalias x=y\n")
        try CLIShim.installRC(path, env: box.env)
        let text = box.read(path)!
        #expect(text.hasPrefix("export A=1\nalias x=y\n"))
        #expect(text.hasSuffix(CLIShim.block(box.env)))
        #expect(CLIShim.rcState(text) == .last)
        #expect(text.contains("export PATH='\(box.env.shimDir)':\"$PATH\""))
    }

    @Test func missingOrNewlineLessFilesWork() throws {
        let box = CLIBox()
        let missing = rc(box, nil)
        try CLIShim.installRC(missing, env: box.env)
        #expect(box.read(missing) == CLIShim.block(box.env))
        #expect(!FS.exists(URL(fileURLWithPath: missing + ".before-switcher")))
        let bare = box.home + "/.bashrc"
        box.write(bare, "no newline")
        try CLIShim.installRC(bare, env: box.env)
        #expect(box.read(bare)!.hasPrefix("no newline\n"))
        #expect(CLIShim.rcState(box.read(bare)!) == .last)
    }

    @Test func idempotent() throws {
        let box = CLIBox()
        let path = rc(box, "export A=1\n")
        try CLIShim.installRC(path, env: box.env)
        let once = box.read(path)!
        try CLIShim.installRC(path, env: box.env)
        try CLIShim.installRC(path, env: box.env)
        #expect(box.read(path) == once)
        #expect(once.components(separatedBy: CLIShim.rcBegin).count == 2)
    }

    @Test func movesABlockThatIsNotLastToTheEnd() throws {
        let box = CLIBox()
        let path = rc(box, "before\n" + CLIShim.block(box.env) + "after\nexport PATH=/x:$PATH\n")
        #expect(CLIShim.rcState(box.read(path)!) == .notLast)
        try CLIShim.installRC(path, env: box.env)
        let text = box.read(path)!
        #expect(CLIShim.rcState(text) == .last)
        #expect(text.hasPrefix("before\nafter\nexport PATH=/x:$PATH\n"))
        #expect(text.components(separatedBy: CLIShim.rcBegin).count == 2)
    }

    @Test func keepsModeAndWritesTheBackupOnce() throws {
        let box = CLIBox()
        let original = "export SECRET_THING=1\n"
        let path = rc(box, original, mode: 0o600)
        try CLIShim.installRC(path, env: box.env)
        #expect(box.mode(path) == 0o600)
        #expect(box.read(path + ".before-switcher") == original)
        // The user edits the file; the backup keeps the state from before Switcher's first touch.
        box.write(path, "edited\n", mode: 0o600)
        try CLIShim.installRC(path, env: box.env)
        #expect(box.read(path + ".before-switcher") == original)
        #expect(box.mode(path) == 0o600)
        try CLIShim.uninstallRC(path)
        #expect(box.mode(path) == 0o600)
    }

    @Test func writesThroughASymlinkedRC() throws {
        let box = CLIBox()
        let target = box.top + "/dotfiles/zshrc"
        box.write(target, "export A=1\n")
        let link = box.home + "/.zshrc"
        box.symlink(link, to: target)
        try CLIShim.installRC(link, env: box.env)
        #expect(box.isLink(link))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == target)
        #expect(CLIShim.rcState(box.read(target)!) == .last)
        try CLIShim.uninstallRC(link)
        #expect(box.isLink(link))
        #expect(box.read(target) == "export A=1\n")
    }

    @Test func uninstallRemovesOnlyTheBlock() throws {
        let box = CLIBox()
        let before = "export A=1\n\n# my stuff\nalias l=ls\n"
        let path = rc(box, before)
        try CLIShim.installRC(path, env: box.env)
        try CLIShim.uninstallRC(path)
        #expect(box.read(path) == before)
        #expect(CLIShim.rcState(box.read(path)!) == .absent)
        // With lines after the block.
        box.write(path, "a\n" + CLIShim.block(box.env) + "b\n")
        try CLIShim.uninstallRC(path)
        #expect(box.read(path) == "a\nb\n")
        // Without a block, or a file: nothing happens.
        try CLIShim.uninstallRC(path)
        #expect(box.read(path) == "a\nb\n")
        try CLIShim.uninstallRC(box.home + "/nope")
        #expect(!FS.exists(URL(fileURLWithPath: box.home + "/nope")))
    }

    @Test func rcStates() {
        let b = CLIShim.block(CLIEnv(home: "/h"))
        #expect(CLIShim.rcState("") == .absent)
        #expect(CLIShim.rcState("export A=1\n") == .absent)
        #expect(CLIShim.rcState(b) == .last)
        #expect(CLIShim.rcState("x\n" + b + "\n\n") == .last)
        #expect(CLIShim.rcState("x\n" + b + "y\n") == .notLast)
    }

    // Review finding 1: only "does not exist" is an empty file.
    @Test func anUnreadableOrNonUTF8RCIsNeverOverwritten() throws {
        let box = CLIBox()
        let path = box.home + "/.zshrc"
        let bytes = Data([0x65, 0x78, 0xff, 0xfe, 0x0a])
        try bytes.write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) { try CLIShim.installRC(path, env: box.env) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(!FS.exists(URL(fileURLWithPath: path + ".before-switcher")))
        #expect(throws: (any Error).self) { try CLIShim.uninstallRC(path) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        // A path that is a folder cannot be read either.
        let dir = box.home + "/.bashrc"
        box.mkdir(dir)
        #expect(throws: (any Error).self) { try CLIShim.installRC(dir, env: box.env) }
    }

    // Review finding 2: unbalanced marker lines change nothing.
    @Test func anIncompleteBlockIsRefusedAndNothingChanges() throws {
        let box = CLIBox()
        let path = rc(box, nil)
        let b = CLIShim.block(box.env)
        let noEnd = "keep 1\n" + CLIShim.rcBegin + "\nexport PATH=/x:$PATH\nkeep 2\n"
        let noBegin = "keep 1\n" + CLIShim.rcEnd + "\nkeep 2\n"
        let twoBegins = "keep 1\n" + CLIShim.rcBegin + "\n" + b + "keep 2\n"
        let swapped = "a\n" + CLIShim.rcEnd + "\nb\n" + CLIShim.rcBegin + "\nc\n"
        for text in [noEnd, noBegin, twoBegins, swapped] {
            box.write(path, text)
            try? FileManager.default.removeItem(atPath: path + ".before-switcher")
            #expect(throws: (any Error).self) { try CLIShim.installRC(path, env: box.env) }
            #expect(box.read(path) == text)
            #expect(throws: (any Error).self) { try CLIShim.uninstallRC(path) }
            #expect(box.read(path) == text)
            #expect(!FS.exists(URL(fileURLWithPath: path + ".before-switcher")))
        }
        let error = try #require({ () -> String? in
            box.write(path, noEnd)
            do { try CLIShim.installRC(path, env: box.env) } catch { return "\(error)" }
            return nil
        }())
        #expect(error.contains("by hand"))
    }

    // Review finding 3: the backup is private, exclusive and never follows a symlink.
    @Test func theBackupIsPrivateAndExclusive() throws {
        let box = CLIBox()
        let path = rc(box, "export KEY=secret\n", mode: 0o644)
        try CLIShim.installRC(path, env: box.env)
        #expect(box.mode(path + ".before-switcher") == 0o600)
        #expect(box.read(path + ".before-switcher") == "export KEY=secret\n")

        let box2 = CLIBox()
        let path2 = rc(box2, "export KEY=secret\n")
        let outside = box2.top + "/outside"
        box2.symlink(path2 + ".before-switcher", to: outside)
        #expect(throws: (any Error).self) { try CLIShim.installRC(path2, env: box2.env) }
        #expect(!FS.exists(URL(fileURLWithPath: outside)))
        #expect(box2.read(path2) == "export KEY=secret\n")
    }
}

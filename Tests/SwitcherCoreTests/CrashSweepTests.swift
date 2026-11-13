import Foundation
import Testing
@testable import SwitcherCore

/// A swap is cut short at every journaled step in turn; `recover()` must leave exactly the state
/// from before the swap or exactly the finished one, never a mix.
@Suite struct CrashSweepTests {
    /// One file, one folder, one dropped file, one JSON key set and one keychain secret.
    struct Fixture {
        let box = Sandbox()
        let secrets = MemorySecrets()
        let vault: SignInVault
        let ref = SignInLayout.SecretRef(service: "test-service", account: "test-account")
        var data: URL { box.env.claudeData }
        var config: URL { box.env.claudeConfig }

        init() throws {
            let d = box.env.claudeData
            let layout = SignInLayout(
                items: [d.appendingPathComponent("Cookies"), d.appendingPathComponent("Local Storage")],
                jsonKeys: [.init(file: box.env.claudeConfig, vaultName: "config.json", keys: ["token", "owner"])],
                secrets: [SignInLayout.SecretRef(service: "test-service", account: "test-account")],
                drop: [d.appendingPathComponent("bridge-state.json")])
            vault = SignInVault(env: box.env, provider: .claude, layout: layout, keychain: secrets)
            // Ada's sign-in is live, then set aside; Grace signs in. The swap under test trades Grace for Ada.
            signIn(ADA)
            try vault.swap(from: Identity(id: ADA, email: "ada@example.com"), to: nil)
            signIn(GRACE)
        }

        func signIn(_ who: String) {
            box.write(data.appendingPathComponent("Cookies"), "cookies-\(who)")
            box.write(data.appendingPathComponent("Local Storage/leveldb/000003.log"), "ls-\(who)")
            box.write(data.appendingPathComponent("bridge-state.json"), "bridge-\(who)")
            box.write(config, "{\n\t\"locale\": \"en-US\",\n\t\"token\": \"tok-\(who)\",\n\t\"owner\": \"\(who)\",\n\t\"theme\": [1, 2]\n}")
            try! secrets.set(service: ref.service, account: ref.account, value: "secret-\(who)")
        }

        func swap() throws { try vault.swap(from: Identity(id: GRACE, email: "grace@example.com"), to: ADA) }

        /// Every file and folder under the sandbox (the trash apart) and every keychain item.
        func snapshot() -> [String: String] {
            var out: [String: String] = [:]
            let paths = (try? FileManager.default.subpathsOfDirectory(atPath: box.root.path)) ?? []
            for rel in paths {
                if rel.contains("/trash") { continue }
                let url = box.root.appendingPathComponent(rel)
                if FS.isDirectory(url) { out[rel] = "<dir>"; continue }
                var text = box.read(url) ?? "<unreadable>"
                if url.lastPathComponent == SignInVault.aboutName, var about = FS.readCodable(SavedLogin.self, from: url) {
                    about.setAsideAt = 0 // the time it was set aside differs from run to run
                    text = "\(about)"
                }
                out[rel] = text
            }
            for (k, v) in secrets.items { out["keychain:" + k.replacingOccurrences(of: "\u{0}", with: "/")] = v }
            return out
        }

        /// A sign-in moves, it is never copied: no marked file's content may exist twice, trash included.
        func duplicates() -> [String] {
            var seen: [String: Int] = [:]
            let walk = FileManager.default.enumerator(at: box.root, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let url as URL in walk where FS.isFile(url) {
                if let text = box.read(url), text.hasPrefix("cookies-") || text.hasPrefix("ls-") || text.hasPrefix("bridge-") {
                    seen[text, default: 0] += 1
                }
            }
            return seen.filter { $0.value > 1 }.map(\.key)
        }
    }

    /// The state a finished, un-faulted swap leaves.
    func finishedState() throws -> [String: String] {
        let f = try Fixture()
        try f.swap()
        return f.snapshot()
    }

    func sweep(simulateCrash: Bool) throws -> Int {
        let target = try finishedState()
        var covered = 0
        for n in 0..<500 {
            let f = try Fixture()
            let original = f.snapshot()
            f.vault.faultAfterStep = n
            f.vault.faultSimulatesCrash = simulateCrash
            do { try f.swap() } catch {}
            if !f.vault.faultFired {
                #expect(covered > 0, "the fault never fired")
                #expect(f.snapshot() == target)
                return covered
            }
            covered += 1
            // The next start: the fault is gone, `recover()` finishes or undoes.
            f.vault.faultAfterStep = nil
            try f.vault.recover()
            let after = f.snapshot()
            #expect(!f.vault.hasInterruptedSwap, "crash point \(n): journal left behind")
            #expect(after == original || after == target, "crash point \(n): a mix of before and after:\n\(diff(after, original, target))")
            #expect(f.duplicates().isEmpty, "crash point \(n): duplicated \(f.duplicates())")
            // Whichever way it went, the next swap works from there.
            if after == original {
                try f.swap()
                #expect(f.snapshot() == target, "crash point \(n): swap after undo")
            }
        }
        Issue.record("the swap never finished within 500 steps")
        return covered
    }

    func diff(_ a: [String: String], _ original: [String: String], _ target: [String: String]) -> String {
        var lines: [String] = []
        for k in Set(a.keys).union(original.keys).union(target.keys).sorted() where a[k] != original[k] {
            lines.append("  \(k): got \(a[k] ?? "-"); before \(original[k] ?? "-"); after \(target[k] ?? "-")")
        }
        return lines.joined(separator: "\n")
    }

    @Test func crashAtEveryStepIsFinishedOrUndone() throws {
        let covered = try sweep(simulateCrash: true)
        #expect(covered >= 20, "only \(covered) crash points")
        print("crash points covered: \(covered)")
    }

    @Test func failureAtEveryStepLeavesTheOriginalOrTheFinishedSwap() throws {
        let covered = try sweep(simulateCrash: false)
        #expect(covered >= 20, "only \(covered) failure points")
    }
}

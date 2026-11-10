import Foundation
import Testing
@testable import SwitcherCore

let ADA = "5a1d3c07-8f2e-4b6a-9c1d-2e3f4a5b6c7d"
let GRACE = "9e31ea7e-1c2d-4e5f-8a9b-0c1d2e3f4a5b"

/// A home folder in a temporary directory: never the real one.
final class Sandbox {
    let root: URL
    let env: Env

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        env = Env(home: root)
        try! FileManager.default.createDirectory(at: env.claudeData, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: env.antigravityData, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: env.gemini, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ url: URL, _ text: String) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    // Claude

    func claudeConfig(account: String?) -> String {
        var lines = ["\t\"locale\": \"en-US\""]
        if let account {
            lines.append("\t\"oauth:tokenCache\": \"tok-\(account)\"")
            lines.append("\t\"lastKnownAccountUuid\": \"\(account)\"")
        }
        lines.append("\t\"userThemeMode\": {\n\t\t\"a\": [1, 2]\n\t}")
        return "{\n" + lines.joined(separator: ",\n") + "\n}"
    }

    /// Claude signed in to `account`: every piece of its sign-in marked with its owner.
    func claudeSignIn(_ account: String) {
        let d = env.claudeData
        write(d.appendingPathComponent("Cookies"), "cookies-\(account)")
        write(d.appendingPathComponent("Local Storage/leveldb/000003.log"), "ls-\(account)")
        write(d.appendingPathComponent("IndexedDB/x"), "idb-\(account)")
        write(d.appendingPathComponent("bridge-state.json"), "{}")
        write(env.claudeConfig, claudeConfig(account: account))
    }

    func claudeOwner() -> String? { read(env.claudeData.appendingPathComponent("Cookies")).map { String($0.dropFirst("cookies-".count)) } }
}

@Suite struct ClaudeSwitching {
    @Test func addThenSwitchBackTradesWholeSignIns() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let app = FakeApp(name: "Claude", running: true)
        let claude = Provider.claude(env: box.env, app: app, keychain: MemorySecrets())

        // Add an account: Ada's sign-in is set aside and Claude opens signed out.
        let r = try claude.switchTo(nil)
        #expect(r.from?.id == ADA)
        #expect(r.launched)
        #expect(app.quits == 1 && app.launches == 1)
        #expect(box.claudeOwner() == nil)
        #expect(!FS.exists(box.env.claudeData.appendingPathComponent("Local Storage")))
        #expect(!FS.exists(box.env.claudeData.appendingPathComponent("bridge-state.json")))
        // Everything else in config.json is left exactly as Claude wrote it.
        #expect(box.read(box.env.claudeConfig) == box.claudeConfig(account: nil))
        #expect(claude.current() == nil)
        #expect(claude.saved().map(\.account) == [ADA])

        // The user signs in to Grace in Claude, then switches back to Ada.
        box.claudeSignIn(GRACE)
        #expect(claude.current()?.id == GRACE)
        try claude.switchTo(ADA)
        #expect(box.claudeOwner() == ADA)
        #expect(box.read(box.env.claudeData.appendingPathComponent("Local Storage/leveldb/000003.log")) == "ls-\(ADA)")
        // The same members; the sign-in's keys come back at the end.
        let restored = try OrderedJSON(contentsOf: box.env.claudeConfig)
        let expected = try OrderedJSON(text: box.claudeConfig(account: ADA))
        #expect(Dictionary(uniqueKeysWithValues: restored.members.map { ($0.key, $0.raw) }) == Dictionary(uniqueKeysWithValues: expected.members.map { ($0.key, $0.raw) }))
        #expect(box.read(box.env.claudeConfig)?.hasPrefix("{\n\t\"locale\"") == true)
        #expect(claude.current()?.id == ADA)
        #expect(claude.saved().map(\.account) == [GRACE])
        // Ada's saved copy is gone: a sign-in is never put back twice.
        #expect(!FS.exists(box.env.vault(.claude).appendingPathComponent(ADA)))
        let graceDir = box.env.vault(.claude).appendingPathComponent(GRACE)
        #expect(box.read(graceDir.appendingPathComponent("Cookies")) == "cookies-\(GRACE)")
        #expect(!FS.exists(box.env.vault(.claude).appendingPathComponent(SignInVault.journalName)))
    }

    @Test func aFailedSwapLeavesEverythingAsItWas() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let claude = Provider.claude(env: box.env, app: FakeApp(running: true), keychain: MemorySecrets())
        try claude.switchTo(nil)
        box.claudeSignIn(GRACE)
        // Ada's saved keys are damaged.
        box.write(box.env.vault(.claude).appendingPathComponent("\(ADA)/config.json"), "{ not json")
        let before = box.read(box.env.claudeConfig)
        #expect(throws: (any Error).self) { try claude.switchTo(ADA) }
        #expect(box.claudeOwner() == GRACE)
        #expect(box.read(box.env.claudeConfig) == before)
        #expect(box.read(box.env.claudeData.appendingPathComponent("IndexedDB/x")) == "idb-\(GRACE)")
        #expect(box.read(box.env.vault(.claude).appendingPathComponent("\(ADA)/Cookies")) == "cookies-\(ADA)")
        #expect(!FS.exists(box.env.vault(.claude).appendingPathComponent(SignInVault.journalName)))
    }

    @Test func anInterruptedSwapIsUndoneNextTime() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let claude = Provider.claude(env: box.env, app: FakeApp(), keychain: MemorySecrets())
        // A swap that died right after setting the cookies aside.
        let vault = claude.vault
        try FS.makePrivateDir(vault.stage)
        let cookies = box.env.claudeData.appendingPathComponent("Cookies")
        let run = SignInVault.Run(.init(from: ADA, to: nil), url: vault.journalURL)
        try run.move(cookies, vault.stage.appendingPathComponent("Cookies"))
        #expect(box.claudeOwner() == nil)
        claude.recoverIfIdle()
        #expect(box.claudeOwner() == ADA)
        #expect(!vault.hasInterruptedSwap)
    }

    @Test func refusingToQuitChangesNothing() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let app = FakeApp(running: true)
        app.refusesToQuit = true
        let claude = Provider.claude(env: box.env, app: app, keychain: MemorySecrets())
        #expect(throws: QuitError.self) { try claude.switchTo(nil) }
        #expect(box.claudeOwner() == ADA)
        #expect(app.launches == 0)
    }

    @Test func switchingToTheCurrentAccountDropsItsStaleCopy() throws {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let claude = Provider.claude(env: box.env, app: FakeApp(), keychain: MemorySecrets())
        try claude.switchTo(nil)
        box.claudeSignIn(ADA) // signed in to Ada again by hand
        try claude.switchTo(ADA)
        #expect(box.claudeOwner() == ADA)
        #expect(!claude.vault.isSaved(ADA))
    }

    @Test func unknownTargetIsRefused() {
        let box = Sandbox()
        box.claudeSignIn(ADA)
        let claude = Provider.claude(env: box.env, app: FakeApp(running: true), keychain: MemorySecrets())
        #expect(throws: SwitchRefused.nothingSaved) { try claude.switchTo(GRACE) }
    }
}

@Suite struct AntigravitySwitching {
    func token(_ email: String) -> String {
        let json = #"{"token":{"access_token":"a-\#(email)","refresh_token":"r-\#(email)"},"auth_method":"consumer","id_token_email":"\#(email)"}"#
        return "go-keyring-base64:" + Data(json.utf8).base64EncodedString()
    }

    func signIn(_ box: Sandbox, _ keychain: MemorySecrets, _ email: String) throws {
        try keychain.set(service: "gemini", account: "antigravity", value: token(email))
        box.write(box.env.antigravityTokenFile, "file-\(email)")
        box.write(box.env.antigravityAppStorage, "{\n  \"ide-install-wizard-shown\": \"true\",\n  \"jetski.onboarding.lastLoginUsername\": \"\(email)\"\n}")
    }

    @Test func tradesKeychainItemTokenFileAndOnboardingKeys() throws {
        let box = Sandbox()
        let keychain = MemorySecrets()
        try signIn(box, keychain, "ada@example.com")
        let app = FakeApp(name: "Antigravity", running: true)
        let ag = Provider.antigravity(env: box.env, app: app, keychain: keychain)
        #expect(ag.current() == Identity(id: "ada@example.com", email: "ada@example.com"))

        try ag.switchTo(nil)
        #expect(try keychain.get(service: "gemini", account: "antigravity") == nil)
        #expect(!FS.exists(box.env.antigravityTokenFile))
        #expect(box.read(box.env.antigravityAppStorage) == "{\n  \"ide-install-wizard-shown\": \"true\"\n}")
        #expect(ag.current() == nil)

        try signIn(box, keychain, "grace@example.com")
        try ag.switchTo("ada@example.com")
        #expect(try keychain.get(service: "gemini", account: "antigravity") == token("ada@example.com"))
        #expect(box.read(box.env.antigravityTokenFile) == "file-ada@example.com")
        #expect(box.read(box.env.antigravityAppStorage)?.contains("ada@example.com") == true)
        #expect(ag.saved().map(\.account) == ["grace@example.com"])
        #expect(ag.saved().first?.email == "grace@example.com")
        // Only Grace's copy is left in our own keychain items.
        let ours = keychain.items.keys.filter { $0.hasPrefix(SignInVault.vaultService) }
        #expect(ours.count == 1)
        #expect(ours.first?.contains("grace@example.com") == true)
    }

    /// Antigravity 2.3x: no email in the keychain item, no token file, `agy.onboarding.*` keys.
    func signInNew(_ box: Sandbox, _ keychain: MemorySecrets, _ email: String) throws {
        let json = #"{"token":{"access_token":"a-\#(email)","refresh_token":"r-\#(email)"},"auth_method":"consumer"}"#
        try keychain.set(service: "gemini", account: "antigravity", value: "go-keyring-base64:" + Data(json.utf8).base64EncodedString())
        box.write(box.env.antigravityAppStorage, "{\n  \"agy.homeGreeting.next\": \"1\",\n  \"agy.onboarding.lastLoginUsername\": \"\(email)\",\n  \"agy.onboarding.lastLoginIsGcpTos\": \"false\"\n}")
    }

    @Test func knowsANewStyleSignInAndTradesIt() throws {
        let box = Sandbox()
        let keychain = MemorySecrets()
        try signIn(box, keychain, "ada@example.com")
        let ag = Provider.antigravity(env: box.env, app: FakeApp(), keychain: keychain)
        try ag.switchTo(nil)
        try signInNew(box, keychain, "Grace@example.com")
        #expect(ag.current() == Identity(id: "grace@example.com", email: "Grace@example.com"))

        try ag.switchTo("ada@example.com")
        #expect(ag.current()?.id == "ada@example.com")
        let storage = box.read(box.env.antigravityAppStorage) ?? ""
        #expect(!storage.contains("Grace@example.com"))
        #expect(storage.contains("agy.homeGreeting.next"))
        #expect(ag.saved().map(\.account) == ["grace@example.com"])

        try ag.switchTo("grace@example.com")
        #expect(ag.current()?.id == "grace@example.com")
        #expect(!FS.exists(box.env.antigravityTokenFile))
    }

    @Test func aRememberedLoginWithoutATokenIsSignedOut() throws {
        let box = Sandbox()
        box.write(box.env.antigravityAppStorage, "{\n  \"agy.onboarding.lastLoginUsername\": \"grace@example.com\"\n}")
        #expect(AntigravityFiles.identity(box.env, keychain: MemorySecrets()) == nil)
    }

    @Test func aKeychainFailureIsUndone() throws {
        final class Flaky: SecretStore {
            let inner = MemorySecrets()
            var failOnLiveWrite = false
            func get(service: String, account: String) throws -> String? { try inner.get(service: service, account: account) }
            func set(service: String, account: String, value: String) throws {
                if failOnLiveWrite, service == "gemini" { throw SwitcherError.message("keychain locked") }
                try inner.set(service: service, account: account, value: value)
            }
            func delete(service: String, account: String) throws { try inner.delete(service: service, account: account) }
        }
        let box = Sandbox()
        let keychain = Flaky()
        try signIn(box, keychain.inner, "ada@example.com")
        let ag = Provider.antigravity(env: box.env, app: FakeApp(), keychain: keychain)
        try ag.switchTo(nil)
        try signIn(box, keychain.inner, "grace@example.com")
        keychain.failOnLiveWrite = true
        #expect(throws: (any Error).self) { try ag.switchTo("ada@example.com") }
        #expect(ag.current()?.id == "grace@example.com")
        #expect(box.read(box.env.antigravityTokenFile) == "file-grace@example.com")
        #expect(ag.vault.isSaved("ada@example.com"))
        keychain.failOnLiveWrite = false
        try ag.switchTo("ada@example.com")
        #expect(ag.current()?.id == "ada@example.com")
    }
}

@Suite struct OrderedJSONTests {
    @Test func keepsOrderAndRawValues() throws {
        let text = "{\n\t\"b\": {\"x\": [1, {\"y\": \"}\"}]},\n\t\"a\": \"q\\\"uote\",\n\t\"n\": 1.50\n}"
        var doc = try OrderedJSON(text: text)
        #expect(doc.keys == ["b", "a", "n"])
        #expect(doc.text(indent: "\t") == text)
        #expect(doc.string("a") == "q\"uote")
        doc["a"] = nil
        doc["z"] = "true"
        #expect(doc.text(indent: "\t") == "{\n\t\"b\": {\"x\": [1, {\"y\": \"}\"}]},\n\t\"n\": 1.50,\n\t\"z\": true\n}")
        #expect(throws: (any Error).self) { try OrderedJSON(text: "{\"a\": 1} extra") }
    }
}

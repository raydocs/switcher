import Foundation
import Testing
@testable import SwitcherCore

/// A keychain value of the wrong shape (the `security` tool prints hex for bytes it can't show)
/// is refused before anything moves.
@Suite struct KeychainShapeTests {
    let json = #"{"token":{"access_token":"a","refresh_token":"r"},"id_token_email":"ada@example.com"}"#

    func setUp(_ box: Sandbox, keychain: MemorySecrets, value: String) throws -> Provider {
        try keychain.set(service: "gemini", account: "antigravity", value: value)
        box.write(box.env.antigravityTokenFile, #"{"id_token_email":"ada@example.com"}"#)
        box.write(box.env.antigravityAppStorage, "{\n  \"jetski.onboarding.lastLoginUsername\": \"ada@example.com\"\n}")
        return Provider.antigravity(env: box.env, app: FakeApp(), keychain: keychain)
    }

    @Test func bareHexForAGoKeyringItemIsRefusedAndNothingMoves() throws {
        let box = Sandbox()
        let keychain = MemorySecrets()
        let hex = Data("go-keyring-base64:\u{1}".utf8).map { String(format: "%02x", $0) }.joined()
        let ag = try setUp(box, keychain: keychain, value: hex)
        let tokenFile = box.read(box.env.antigravityTokenFile)
        let storage = box.read(box.env.antigravityAppStorage)

        #expect(throws: (any Error).self) { try ag.switchTo(nil) }

        #expect(try keychain.get(service: "gemini", account: "antigravity") == hex)
        #expect(box.read(box.env.antigravityTokenFile) == tokenFile)
        #expect(box.read(box.env.antigravityAppStorage) == storage)
        #expect(!ag.vault.hasInterruptedSwap)
        #expect(!FS.exists(ag.vault.stage))
        #expect(ag.saved().isEmpty)
        #expect(keychain.items.keys.allSatisfy { !$0.hasPrefix(SignInVault.vaultService) })
    }

    @Test func aWellFormedGoKeyringValueIsSetAside() throws {
        let box = Sandbox()
        let keychain = MemorySecrets()
        let value = "go-keyring-base64:" + Data(json.utf8).base64EncodedString()
        let ag = try setUp(box, keychain: keychain, value: value)
        try ag.switchTo(nil)
        #expect(try keychain.get(service: "gemini", account: "antigravity") == nil)
        #expect(ag.saved().map(\.account) == ["ada@example.com"])
    }

    @Test func shapes() {
        func ref(_ s: SignInLayout.SecretRef.Shape) -> SignInLayout.SecretRef { .init(service: "s", account: "a", shape: s) }
        let b64 = "go-keyring-base64:" + Data(json.utf8).base64EncodedString()
        #expect(ref(.goKeyring).accepts(b64))
        #expect(ref(.goKeyring).accepts("go-keyring-encoded:7b7d"))
        #expect(ref(.goKeyring).accepts(json))
        #expect(!ref(.goKeyring).accepts("7b7d7b7d"))
        #expect(!ref(.goKeyring).accepts("go-keyring-base64:"))
        #expect(!ref(.goKeyring).accepts("go-keyring-base64:!!!"))
        #expect(!ref(.goKeyring).accepts("go-keyring-encoded:zz"))
        #expect(ref(.json).accepts(json))
        #expect(!ref(.json).accepts("abc123"))
        #expect(ref(.any).accepts("abc123"))
        #expect(Provider.antigravityKeychain.shape == .goKeyring)
    }
}

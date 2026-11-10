import Foundation

/// Generic passwords in the login keychain.
public protocol SecretStore: AnyObject {
    func get(service: String, account: String) throws -> String?
    func set(service: String, account: String, value: String) throws
    func delete(service: String, account: String) throws
}

/// The login keychain through `/usr/bin/security`, the same way Antigravity's Go language server
/// (zalando/go-keyring) reaches it. Items it creates trust that tool, so reading and replacing them
/// this way asks nothing, and the items Switcher writes stay readable by Antigravity.
/// Secrets travel on stdin (hex-encoded), never on a command line.
public final class KeychainCLI: SecretStore {
    public init() {}

    private static let notFound: Int32 = 44

    public func get(service: String, account: String) throws -> String? {
        let (status, out, err) = try run(["find-generic-password", "-s", service, "-a", account, "-w"], stdin: nil)
        if status == Self.notFound { return nil }
        guard status == 0 else { throw SwitcherError.message("reading keychain item \(service): \(err)") }
        var value = out
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    public func set(service: String, account: String, value: String) throws {
        try check(service)
        try check(account)
        let hex = value.utf8.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -X \"\(hex)\"\n"
        let (status, _, err) = try run(["-i"], stdin: command)
        guard status == 0, !err.contains("rror") else {
            throw SwitcherError.message("writing keychain item \(service): \(err)")
        }
        // `security -i` can exit 0 after a failed command: read it back.
        guard try get(service: service, account: account) == value else {
            throw SwitcherError.message("writing keychain item \(service) did not take effect")
        }
    }

    public func delete(service: String, account: String) throws {
        let (status, _, err) = try run(["delete-generic-password", "-s", service, "-a", account], stdin: nil)
        if status == 0 || status == Self.notFound { return }
        throw SwitcherError.message("deleting keychain item \(service): \(err)")
    }

    private func check(_ s: String) throws {
        if s.contains("\"") || s.contains("\\") || s.contains("\n") {
            throw SwitcherError.message("unexpected character in keychain name")
        }
    }

    private func run(_ args: [String], stdin: String?) throws -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        try p.run()
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try inp.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// An in-memory keychain for tests.
public final class MemorySecrets: SecretStore {
    public var items: [String: String] = [:]

    public init() {}

    private func key(_ s: String, _ a: String) -> String { "\(s)\u{0}\(a)" }

    public func get(service: String, account: String) throws -> String? { items[key(service, account)] }
    public func set(service: String, account: String, value: String) throws { items[key(service, account)] = value }
    public func delete(service: String, account: String) throws { items[key(service, account)] = nil }
}

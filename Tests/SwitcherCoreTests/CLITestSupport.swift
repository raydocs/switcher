import Foundation
@testable import SwitcherCore

/// A temporary world for the CLI-profile tests: a fake HOME and a scratch folder. Nothing here
/// touches the real HOME, keychain, rc files or real `claude` / `codex`.
final class CLIBox {
    let top: String
    let home: String

    init(homeName: String = "home") {
        top = NSTemporaryDirectory() + "switcher-cli-\(UUID().uuidString)"
        home = top + "/" + homeName
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: top) }

    var env: CLIEnv { CLIEnv(home: home) }

    func env(realClaude: String? = nil, realCodex: String? = nil) -> CLIEnv {
        var real: [CLIKind: String] = [:]
        if let realClaude { real[.claude] = realClaude }
        if let realCodex { real[.codex] = realCodex }
        return CLIEnv(home: home, realBinaries: real)
    }

    func mkdir(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String, mode: Int? = nil) {
        mkdir((path as NSString).deletingLastPathComponent)
        try? text.write(toFile: path, atomically: false, encoding: .utf8)
        if let mode { chmod(path, mode_t(mode)) }
    }

    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    func symlink(_ path: String, to target: String) {
        mkdir((path as NSString).deletingLastPathComponent)
        try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }

    func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    func isLink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// A fake CLI that prints what the shim gave it.
    @discardableResult
    func fakeBinary(_ path: String) -> String {
        write(path, """
        #!/bin/sh
        echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>}"
        echo "CODEX_HOME=${CODEX_HOME-<unset>}"
        for a in "$@"; do echo "arg=[$a]"; done

        """, mode: 0o755)
        return path
    }

    func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
}

/// An unsigned JWT (`header.payload.sig`, base64url without padding).
func fakeJWT(_ claims: [String: Any]) -> String {
    func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let header = b64url(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
    let payload = b64url((try? JSONSerialization.data(withJSONObject: claims)) ?? Data())
    return "\(header).\(payload).sig"
}

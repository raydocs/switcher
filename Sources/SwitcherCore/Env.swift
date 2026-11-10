import Foundation

/// Every path Switcher reads or writes. Tests build one over a temporary folder, so nothing ever
/// touches the real apps' data from a test.
public struct Env: Sendable {
    public var home: URL
    /// Switcher's own state: `~/Library/Application Support/Switcher`.
    public var state: URL
    /// Claude Desktop's data folder: `~/Library/Application Support/Claude`.
    public var claudeData: URL
    /// Claude Code's `~/.claude.json` (holds the CLI's `oauthAccount`, a source of emails).
    public var claudeJSON: URL
    /// Antigravity's data folder: `~/Library/Application Support/Antigravity`.
    public var antigravityData: URL
    /// `~/.gemini`, where Antigravity keeps its fallback token file.
    public var gemini: URL
    /// cc-same's state folder, for importing its saved sign-ins.
    public var ccSame: URL

    public init(home: URL, state: URL? = nil) {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.home = home
        self.state = state ?? support.appendingPathComponent("Switcher", isDirectory: true)
        self.claudeData = support.appendingPathComponent("Claude", isDirectory: true)
        self.claudeJSON = home.appendingPathComponent(".claude.json")
        self.antigravityData = support.appendingPathComponent("Antigravity", isDirectory: true)
        self.gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        self.ccSame = support.appendingPathComponent("cc-same", isDirectory: true)
    }

    /// The signed-in user's real folders.
    public static var live: Env {
        Env(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public var claudeConfig: URL { claudeData.appendingPathComponent("config.json") }
    public var claudeSessions: URL { claudeData.appendingPathComponent("claude-code-sessions", isDirectory: true) }
    public var claudeCoworkSessions: URL { claudeData.appendingPathComponent("local-agent-mode-sessions", isDirectory: true) }
    public var claudeUsageHistory: URL { claudeData.appendingPathComponent("plan-usage-history.json") }
    public var antigravityAppStorage: URL { antigravityData.appendingPathComponent("app_storage.json") }
    public var antigravityTokenFile: URL { gemini.appendingPathComponent("jetski-standalone-oauth-token") }

    public func vault(_ provider: ProviderID) -> URL {
        state.appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent("logins", isDirectory: true)
    }
}

public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude
    case antigravity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        }
    }
}

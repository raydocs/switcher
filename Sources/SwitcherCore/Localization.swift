import Foundation

/// Display language preference for Switcher.
public enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case en
    case zhHans = "zh-Hans"

    public var id: String { rawValue }
}

/// English or Simplified Chinese, following the user's override or the system language.
public enum L10n {
    public static let settingKey = "appLanguage"

    /// Optional in-process override (for tests and snapshot captures).
    private static let lock = NSLock()
    private static var _override: AppLanguage?
    public static var override: AppLanguage? {
        get { lock.withLock { _override } }
        set { lock.withLock { _override = newValue } }
    }

    public static var language: AppLanguage {
        if let forced = override { return forced }
        if let raw = UserDefaults.standard.string(forKey: settingKey),
           let saved = AppLanguage(rawValue: raw) {
            return saved
        }
        return .system
    }

    public static var zh: Bool {
        switch language {
        case .zhHans: true
        case .en: false
        case .system: Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }

    public static func t(_ en: String, _ cn: String) -> String { zh ? cn : en }
}

/// Privacy helpers for screenshots, screen sharing and diagnostic output.
public enum Privacy {
    /// Masks an email address as `a•••@l•••.dev` while leaving non-email text untouched.
    public static func maskEmail(_ value: String) -> String {
        guard let at = value.firstIndex(of: "@") else { return value }
        let local = value[..<at]
        let domain = value[value.index(after: at)...]
        guard !local.isEmpty, !domain.isEmpty else { return value }

        let maskedLocal = "\(local.first!)•••"
        if let lastDot = domain.lastIndex(of: "."), lastDot > domain.startIndex {
            let host = domain[..<lastDot]
            let tld = domain[lastDot...]
            let maskedHost = "\(host.first!)•••"
            return "\(maskedLocal)@\(maskedHost)\(tld)"
        }
        return "\(maskedLocal)@\(domain.first!)•••"
    }

    public static func displayEmail(_ email: String?, masked: Bool) -> String? {
        guard let email else { return nil }
        return masked ? maskEmail(email) : email
    }

    /// Redacts the user's home directory path (to `~`) and any email addresses in diagnostic output.
    public static func redactDiagnostic(_ text: String, home: String) -> String {
        var out = text
        let trimmedHome = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        if !trimmedHome.isEmpty, trimmedHome != "/" {
            out = out.replacingOccurrences(of: trimmedHome, with: "~")
        }
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) else {
            return out
        }
        let ns = out as NSString
        let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let email = ns.substring(with: match.range)
            if let range = Range(match.range, in: out) {
                out.replaceSubrange(range, with: maskEmail(email))
            }
        }
        return out
    }
}

/// Whether quota meters and numbers show percentage used or percentage remaining.
public enum QuotaDisplayMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case used
    case remaining

    public static let settingKey = "quotaDisplayMode"

    public var id: String { rawValue }

    /// The number displayed beside a meter (`used` in 0...100).
    public func shownPercent(used: Int) -> Int {
        let clamped = min(100, max(0, used))
        switch self {
        case .used: return clamped
        case .remaining: return 100 - clamped
        }
    }

    /// The bar fill fraction (`0.0...1.0`) for a given `used` percentage.
    public func barFraction(used: Int) -> Double {
        Double(shownPercent(used: used)) / 100.0
    }

    /// Position (`0...100`) of the even-pace marker along the meter bar.
    public func pacePosition(usedPace: Int?) -> Int? {
        guard let usedPace else { return nil }
        let clamped = min(100, max(0, usedPace))
        switch self {
        case .used: return clamped
        case .remaining: return 100 - clamped
        }
    }
}

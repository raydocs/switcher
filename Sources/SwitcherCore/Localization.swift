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
}

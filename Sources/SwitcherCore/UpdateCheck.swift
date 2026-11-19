import Foundation

/// Lightweight semantic version parser and GitHub Releases checker (manual trigger only, zero dependencies).
public struct SemVer: Equatable, Comparable, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: String?

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var pre: String?
        if let dash = s.firstIndex(of: "-") {
            pre = String(s[s.index(after: dash)...])
            s = String(s[..<dash])
        }
        let parts = s.split(separator: ".").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        guard let maj = Int(parts[0]), maj >= 0 else { return nil }
        let min = parts.count > 1 ? Int(parts[1]) : 0
        let pat = parts.count > 2 ? Int(parts[2]) : 0
        guard let min, min >= 0, let pat, pat >= 0 else { return nil }
        self.major = maj
        self.minor = min
        self.patch = pat
        self.prerelease = pre
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (_?, nil): return true
        case (nil, _?): return false
        case (let a?, let b?): return a < b
        }
    }
}

public struct ReleaseInfo: Equatable, Sendable {
    public var tagName: String
    public var name: String
    public var htmlURL: URL
    public var publishedAt: Date?

    public init(tagName: String, name: String, htmlURL: URL, publishedAt: Date? = nil) {
        self.tagName = tagName
        self.name = name
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: String, latest: String)
    case updateAvailable(current: String, release: ReleaseInfo)
    case noReleases
    case failed(String)
}

public enum UpdateChecker {
    public static let defaultRepo = "raydocs/switcher"

    public static func latestReleaseURL(repo: String = defaultRepo) -> URL {
        URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    /// Compares `currentVersion` against the latest GitHub Release for `repo`.
    /// Uses an ephemeral request with no cookies or cache; called only on explicit user click.
    public static func check(
        currentVersion: String,
        repo: String = defaultRepo,
        http: HTTPGetter = URLSessionHTTPGetter()
    ) async -> UpdateCheckResult {
        let url = latestReleaseURL(repo: repo)
        let headers = [
            "Accept": "application/vnd.github+json",
            "User-Agent": "Switcher/\(currentVersion)",
        ]
        do {
            let (status, data) = try await http.get(url, headers: headers)
            if status == 404 { return .noReleases }
            guard status == 200 else {
                return .failed(L10n.t("GitHub answered HTTP \(status).", "GitHub 返回状态码 \(status)。"))
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, !tag.isEmpty,
                  let link = obj["html_url"] as? String, let htmlURL = URL(string: link) else {
                return .failed(L10n.t("Unexpected response from GitHub.", "无法解析 GitHub 返回数据。"))
            }
            let title = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag
            let published = (obj["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let release = ReleaseInfo(tagName: tag, name: title, htmlURL: htmlURL, publishedAt: published)
            return compare(currentVersion: currentVersion, release: release)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public static func compare(currentVersion: String, release: ReleaseInfo) -> UpdateCheckResult {
        guard let latest = SemVer(release.tagName) else {
            return .upToDate(current: currentVersion, latest: release.tagName)
        }
        guard let current = SemVer(currentVersion) else {
            // Non-semver local builds (e.g. "dev") show the latest published release as available.
            return .updateAvailable(current: currentVersion, release: release)
        }
        if current < latest {
            return .updateAvailable(current: currentVersion, release: release)
        }
        return .upToDate(current: currentVersion, latest: release.tagName)
    }
}

import Foundation

/// One Antigravity quota pool, as Google's Cloud Code service reports it.
public struct QuotaBucket: Codable, Equatable, Sendable, Identifiable {
    public enum Pool: String, Codable, CaseIterable, Sendable {
        case gemini5h, geminiWeekly, argonWeekly, claude5h, claudeWeekly
    }

    public var pool: Pool
    /// Percent used, 0–100.
    public var used: Int
    public var resetsAt: Date?

    public var id: Pool { pool }

    public init(pool: Pool, used: Int, resetsAt: Date? = nil) {
        self.pool = pool
        self.used = used
        self.resetsAt = resetsAt
    }
}

public struct AntigravityQuota: Codable, Equatable, Sendable {
    /// "Google AI Pro", "Google AI Ultra", …
    public var plan: String?
    public var buckets: [QuotaBucket]
    public var fetchedAt: Date
    /// Why the last read failed, when it did (the numbers above are then the previous ones).
    public var problem: String?

    public init(plan: String?, buckets: [QuotaBucket], fetchedAt: Date, problem: String? = nil) {
        self.plan = plan
        self.buckets = buckets
        self.fetchedAt = fetchedAt
        self.problem = problem
    }

    public func bucket(_ pool: QuotaBucket.Pool) -> QuotaBucket? { buckets.first { $0.pool == pool } }
}

/// Reads each Antigravity account's quota the way the Antigravity app does (`loadCodeAssist`, then
/// `retrieveUserQuotaSummary`), with that account's own Google sign-in.
///
/// The tokens come from the keychain items Switcher already keeps: the live one Antigravity uses and
/// the copies of accounts set aside. An expired access token is renewed with the refresh token, in
/// memory only. Google does not rotate refresh tokens on renewal, so reading never disturbs a saved
/// sign-in. Tokens go only to Google; results are cached in `<state>/antigravity-usage.json`.
/// Approach after openusage (robinebers/openusage).
public final class AntigravityUsage: @unchecked Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// The Google OAuth "installed application" client Antigravity ships with. Google does not treat an
    /// installed app's secret as confidential, and the refresh grant needs it.
    static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecret = "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"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    // The daily endpoint can leave Gemini pools out of a successful answer: production first.
    static let bases = ["https://cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.googleapis.com"]
    static let userAgent: String = {
        #if arch(arm64)
        "antigravity/2.30.0 (aidev_client; os_type=darwin; arch=arm64)"
        #else
        "antigravity/2.30.0 (aidev_client; os_type=darwin; arch=amd64)"
        #endif
    }()

    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    let env: Env
    let send: Send
    private let lock = NSLock()
    /// Renewed access tokens by account, in memory only.
    private var accessTokens: [String: (token: String, expires: Date)] = [:]
    private var projects: [String: String] = [:]

    public init(env: Env, send: Send? = nil) {
        self.env = env
        self.send = send ?? { request in
            // No disk cache, no cookies, no redirects: a token goes to the Google address it was meant for, and nowhere is it kept.
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }

    // MARK: Cache

    var cacheURL: URL { env.state.appendingPathComponent("antigravity-usage.json") }

    public func cached() -> [String: AntigravityQuota] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([String: AntigravityQuota].self, from: data)) ?? [:]
    }

    func store(_ id: String, _ quota: AntigravityQuota) {
        lock.lock()
        defer { lock.unlock() }
        var all = cached()
        all[id] = quota
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(all) { try? FS.atomicWrite(data, to: cacheURL) }
    }

    // MARK: Reading

    /// A keychain value as go-keyring stores it: `go-keyring-base64:<JSON>`.
    struct Credential {
        var accessToken: String?
        var refreshToken: String?
        var expiry: Date?

        init?(keyring value: String) {
            var body = value
            let prefix = "go-keyring-base64:"
            if body.hasPrefix(prefix) {
                guard let data = Data(base64Encoded: String(body.dropFirst(prefix.count))) else { return nil }
                body = String(decoding: data, as: UTF8.self)
            }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let token = obj["token"] as? [String: Any] else { return nil }
            accessToken = token["access_token"] as? String
            refreshToken = token["refresh_token"] as? String
            if let e = token["expiry"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                expiry = f.date(from: e) ?? ISO8601DateFormatter().date(from: e)
            }
            if refreshToken == nil && accessToken == nil { return nil }
        }
    }

    /// Read `account`'s quota with its keychain value, cache it, and return it. A failure keeps the
    /// previous numbers and says why.
    public func refresh(account id: String, keyring value: String, now: Date = Date()) async -> AntigravityQuota {
        let previous = cached()[id]
        do {
            guard let credential = Credential(keyring: value) else { throw SwitcherError.message(L10n.t("Its saved sign-in can't be read.", "无法读取它保存的登录。")) }
            var token = try await accessToken(id, credential, now: now, forceRenew: false)
            var result = try? await read(id, token: token)
            if result == nil {
                // Refused: renew once and try again.
                token = try await accessToken(id, credential, now: now, forceRenew: true)
                result = try await read(id, token: token)
            }
            let quota = AntigravityQuota(plan: result!.plan ?? previous?.plan, buckets: result!.buckets, fetchedAt: now, problem: nil)
            store(id, quota)
            return quota
        } catch {
            var quota = previous ?? AntigravityQuota(plan: nil, buckets: [], fetchedAt: now, problem: nil)
            quota.problem = error.localizedDescription
            store(id, quota)
            return quota
        }
    }

    func accessToken(_ id: String, _ c: Credential, now: Date, forceRenew: Bool) async throws -> String {
        if !forceRenew {
            let renewed = lock.withLock { accessTokens[id] }
            if let renewed, renewed.expires > now.addingTimeInterval(60) { return renewed.token }
            if let t = c.accessToken, let e = c.expiry, e > now.addingTimeInterval(60) { return t }
        }
        guard let refresh = c.refreshToken else { throw SwitcherError.message(L10n.t("Sign in to it again in Antigravity.", "请在 Antigravity 里重新登录它。")) }
        var req = URLRequest(url: Self.tokenURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["client_id": Self.clientID, "client_secret": Self.clientSecret, "refresh_token": refresh, "grant_type": "refresh_token"]
        req.httpBody = Data(form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").utf8)
        let (data, response) = try await send(req)
        guard (200..<300).contains(response.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String else {
            if response.statusCode == 400 || response.statusCode == 401 {
                throw SwitcherError.message(L10n.t("Google no longer accepts this sign-in. Sign in to it again in Antigravity.", "Google 已不接受这个登录，请在 Antigravity 里重新登录。"))
            }
            throw SwitcherError.message(L10n.t("Google didn't answer (\(response.statusCode)).", "Google 没有响应（\(response.statusCode)）。"))
        }
        let expires = now.addingTimeInterval((obj["expires_in"] as? Double) ?? 3600)
        lock.withLock { accessTokens[id] = (token, expires) }
        return token
    }

    struct Read {
        var plan: String?
        var buckets: [QuotaBucket]
    }

    struct Refused: Error {}

    func read(_ id: String, token: String) async throws -> Read {
        var plan: String?
        var project = lock.withLock { projects[id] }
        if let body = try await post(Self.loadCodeAssistPath, token: token, body: Data(#"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8)) {
            plan = Self.parsePlan(body)
            if let p = Self.parseProject(body) {
                project = p
                lock.withLock { projects[id] = p }
            }
        }
        let payload = try JSONSerialization.data(withJSONObject: project.map { ["project": $0] } ?? [:])
        guard let body = try await post(Self.quotaPath, token: token, body: payload, wantComplete: true) else {
            throw SwitcherError.message(L10n.t("Antigravity's quota is unavailable right now.", "暂时读不到 Antigravity 额度。"))
        }
        return Read(plan: plan, buckets: Self.parseBuckets(body))
    }

    static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    static let quotaPath = "/v1internal:retrieveUserQuotaSummary"

    /// POST to each base in turn; the first good answer (for the quota, the first with every pool).
    /// A 401 means the token was refused.
    func post(_ path: String, token: String, body: Data, wantComplete: Bool = false) async throws -> Data? {
        var good: Data?
        for base in Self.bases {
            var req = URLRequest(url: URL(string: base + path)!, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.httpBody = body
            for (k, v) in ["Accept": "application/json", "Content-Type": "application/json", "Authorization": "Bearer \(token)", "User-Agent": Self.userAgent] {
                req.setValue(v, forHTTPHeaderField: k)
            }
            guard let (data, response) = try? await send(req) else { continue }
            if response.statusCode == 401 { throw Refused() }
            guard (200..<300).contains(response.statusCode) else { continue }
            if good == nil { good = data }
            if !wantComplete || Self.parseBuckets(data).filter({ $0.pool != .argonWeekly }).count == 4 { return data }
        }
        return good
    }

    // MARK: Parsing

    static let bucketPools: [String: QuotaBucket.Pool] = [
        "gemini-5h": .gemini5h, "gemini-weekly": .geminiWeekly, "3p-5h": .claude5h, "3p-weekly": .claudeWeekly,
    ]
    static let argonGroup = "Gemini 4 Argon"

    static func parseBuckets(_ data: Data) -> [QuotaBucket] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let groups = ((obj["response"] as? [String: Any])?["groups"] ?? obj["groups"]) as? [[String: Any]] ?? []
        var out: [QuotaBucket.Pool: QuotaBucket] = [:]
        for g in groups {
            let isArgon = g["displayName"] as? String == argonGroup
            for b in g["buckets"] as? [[String: Any]] ?? [] {
                guard let fraction = (b["remainingFraction"] as? NSNumber)?.doubleValue, fraction.isFinite else { continue }
                let pool: QuotaBucket.Pool
                if isArgon {
                    guard b["window"] as? String == "weekly", b["disabled"] as? Bool != true else { continue }
                    pool = .argonWeekly
                } else {
                    guard let id = b["bucketId"] as? String, let p = bucketPools[id] else { continue }
                    pool = p
                }
                if out[pool] != nil { continue }
                let used = Int(((1 - max(0, min(1, fraction))) * 100).rounded())
                out[pool] = QuotaBucket(pool: pool, used: used, resetsAt: (b["resetTime"] as? String).flatMap(parseDate))
            }
        }
        return QuotaBucket.Pool.allCases.compactMap { out[$0] }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func parseProject(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = obj["cloudaicompanionProject"] as? String, !p.isEmpty else { return nil }
        return p
    }

    static let paidTiers = ["g1-pro-tier": "Google AI Pro", "g1-ultra-tier": "Google AI Ultra", "g1-ultra-lite-tier": "Google AI Ultra Lite"]

    static func parsePlan(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let paid = obj["paidTier"] as? [String: Any], current = obj["currentTier"] as? [String: Any]
        if let id = paid?["id"] as? String, let plan = paidTiers[id] { return plan }
        guard let raw = ((paid?["name"] ?? current?["name"]) as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        for tier in ["Ultra Lite", "Ultra", "Pro"] where raw.lowercased().contains(tier.lowercased()) { return "Google AI \(tier)" }
        return raw
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// English or Simplified Chinese, following the system language.
public enum L10n {
    public static let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    public static func t(_ en: String, _ cn: String) -> String { zh ? cn : en }
}

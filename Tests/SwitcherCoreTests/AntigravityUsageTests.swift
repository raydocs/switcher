import Foundation
import Testing
@testable import SwitcherCore

@Suite struct AntigravityUsageTests {
    static let summary = #"""
    {"response":{"groups":[
      {"displayName":"Gemini","buckets":[
        {"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2026-11-10T03:00:00Z"},
        {"bucketId":"gemini-weekly","remainingFraction":0.4}]},
      {"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"argon-w","window":"weekly","remainingFraction":0.9}]},
      {"displayName":"Third party","buckets":[
        {"bucketId":"3p-5h","remainingFraction":1},
        {"bucketId":"3p-weekly","remainingFraction":0.005},
        {"bucketId":"mystery","remainingFraction":0.1}]}
    ]}}
    """#

    @Test func parsesEveryPool() {
        let b = AntigravityUsage.parseBuckets(Data(Self.summary.utf8))
        #expect(b.map(\.pool) == [.gemini5h, .geminiWeekly, .argonWeekly, .claude5h, .claudeWeekly])
        #expect(b.map(\.used) == [25, 60, 10, 0, 100])
        #expect(b.first?.resetsAt != nil)
        #expect(AntigravityUsage.parsePlan(Data(#"{"paidTier":{"id":"g1-ultra-tier"},"cloudaicompanionProject":"p-1"}"#.utf8)) == "Google AI Ultra")
        #expect(AntigravityUsage.parseProject(Data(#"{"cloudaicompanionProject":"p-1"}"#.utf8)) == "p-1")
    }

    final class Calls: @unchecked Sendable {
        var log: [String] = []
        let lock = NSLock()
        func add(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
    }

    @Test func renewsAnExpiredTokenInMemoryAndCaches() async throws {
        let box = Sandbox()
        let calls = Calls()
        let summary = Self.summary
        let usage = AntigravityUsage(env: box.env) { req in
            let url = req.url!.absoluteString
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            calls.add("\(url.components(separatedBy: "/").last!) \(auth)")
            let ok = { (body: String) in (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            if url.hasSuffix("/token") {
                #expect(String(decoding: req.httpBody!, as: UTF8.self).contains("refresh_token=r-1"))
                return ok(#"{"access_token":"fresh","expires_in":3599}"#)
            }
            #expect(auth == "Bearer fresh")
            if url.hasSuffix("loadCodeAssist") { return ok(#"{"paidTier":{"id":"g1-pro-tier"},"cloudaicompanionProject":"proj"}"#) }
            #expect(String(decoding: req.httpBody!, as: UTF8.self).contains("proj"))
            return ok(summary)
        }
        let payload = #"{"token":{"access_token":"old","refresh_token":"r-1","expiry":"2020-01-01T00:00:00.000000Z"},"id_token_email":"ada@example.com"}"#
        let value = "go-keyring-base64:" + Data(payload.utf8).base64EncodedString()
        let q = await usage.refresh(account: "ada@example.com", keyring: value)
        #expect(q.problem == nil)
        #expect(q.plan == "Google AI Pro")
        #expect(q.bucket(.geminiWeekly)?.used == 60)
        #expect(calls.log.first?.hasPrefix("token") == true)
        #expect(usage.cached()["ada@example.com"]?.buckets == q.buckets)
        #expect(usage.cached()["ada@example.com"]?.plan == q.plan)
        // The cache holds numbers only, never a token.
        let cache = String(decoding: try Data(contentsOf: usage.cacheURL), as: UTF8.self)
        #expect(!cache.contains("fresh") && !cache.contains("r-1"))
    }

    @Test func aRefusedSignInKeepsTheLastNumbers() async {
        let box = Sandbox()
        let usage = AntigravityUsage(env: box.env) { req in
            (Data(#"{"error":"invalid_grant"}"#.utf8), HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        let old = AntigravityQuota(plan: "Google AI Pro", buckets: [QuotaBucket(pool: .gemini5h, used: 5)], fetchedAt: Date(timeIntervalSince1970: 1), problem: nil)
        usage.store("a", old)
        let value = #"{"token":{"refresh_token":"r"}}"#
        let q = await usage.refresh(account: "a", keyring: value)
        #expect(q.buckets == old.buckets)
        #expect(q.problem != nil)
    }
}

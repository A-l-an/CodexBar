import Foundation
import Testing
@testable import CodexBarCore

/// Synthetic values only. No defaults, account stores, or user history are consulted.
enum RemoteCostFixture {
    static let now = Date(timeIntervalSince1970: 1_789_473_600)

    static func summary(
        days: Int = 7,
        tokens: Int? = 120,
        cost: Double? = 0.004,
        zone: String = "Etc/UTC",
        complete: Bool = true) -> CodexCostSummary
    {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: cost,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            historyDays: days,
            historyCoverageIsEstablished: complete,
            costProvenance: .listPriceEstimate,
            daily: [],
            updatedAt: self.now)
        return CodexCostSummary(snapshot: snapshot, calendar: CostUsageBucketTimeZone.calendar(identifier: zone))
    }

    static func json(_ summaries: [CodexCostSummary]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try #require(String(data: encoder.encode(summaries), encoding: .utf8))
    }

    static func object() throws -> [String: Any] {
        let objects = try #require(
            JSONSerialization.jsonObject(with: Data(self.json([self.summary()]).utf8)) as? [[String: Any]])
        return try #require(objects.first)
    }

    static func jsonObject(_ object: [String: Any]) throws -> String {
        try #require(String(data: JSONSerialization.data(withJSONObject: [object]), encoding: .utf8))
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-ssh-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

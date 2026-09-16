import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct RemoteCodexCostScannerTests {
    @Test
    func `native summary sees a recent turn appended in an old date directory`() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.cleanup() }
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z"))
        let old = now.addingTimeInterval(-20 * 86400)
        let file = try fixture.writeSession(timestamp: old, partition: "2026/08/26", input: 50, cached: 0, output: 5)
        let warm = try await fixture.load(now: now, days: 7, force: true)
        #expect(warm.last30DaysTokens == 0)
        let append = try fixture.events(timestamp: now, input: 100, cached: 20, output: 10)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(append.utf8))
        try handle.close()

        let native = try await fixture.load(now: now.addingTimeInterval(1), days: 7, force: false)
        let summary = CodexCostSummary(snapshot: native, calendar: fixture.calendar)
        try summary.validate(historyDays: 7)
        #expect(summary.sessionTokens == 110)
        #expect(summary.last30DaysTokens == 110)
        #expect(try #require(summary.last30DaysCostUSD) > 0)
        #expect(summary.last30DaysCostUSD == native.last30DaysCostUSD)
        #expect(summary.coverage == native.summary(forLastDays: 7, calendar: fixture.calendar).coverage)
        #expect(summary.updatedAt == native.updatedAt)
    }

    @Test
    func `custom home and changed local pricing match the native snapshot without another cache root`() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.cleanup() }
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z"))
        try fixture.writeSession(timestamp: now, partition: "2026/09/15", input: 100, cached: 20, output: 10)
        try fixture.pricing(multiplier: 1, now: now)
        let first = try await fixture.load(now: now, days: 7, force: true)
        let firstCost = try #require(first.last30DaysCostUSD)
        #expect(abs(firstCost - 0.000366) < 1e-9)
        try fixture.pricing(multiplier: 2, now: now.addingTimeInterval(1))
        let updated = try await fixture.load(now: now.addingTimeInterval(2), days: 7, force: true)
        let summary = CodexCostSummary(snapshot: updated, calendar: fixture.calendar)
        #expect(summary.sessionTokens == 110)
        #expect(summary.last30DaysTokens == 110)
        #expect(try abs(#require(summary.last30DaysCostUSD) - firstCost * 2) < 1e-9)
        #expect(summary.last30DaysCostUSD == updated.last30DaysCostUSD)
        #expect(summary.provenance == updated.summary(forLastDays: 7, calendar: fixture.calendar).provenance)
        let json = try RemoteCostFixture.json([summary])
        #expect(!json.contains(fixture.root.path))
        #expect(!json.contains("daily"))
        #expect(ModelsDevCache.cacheFileURL(cacheRoot: fixture.cache).path.hasPrefix(fixture.root.path))
    }

    @Test
    func `source timezone changes Today while retaining the same separate history window`() async throws {
        let utc = try ScannerFixture(zone: "Etc/UTC")
        let shanghai = try ScannerFixture(zone: "Asia/Shanghai")
        defer { utc.cleanup(); shanghai.cleanup() }
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-15T01:00:00Z"))
        let event = now.addingTimeInterval(-5400)
        for fixture in [utc, shanghai] {
            try fixture.writeSession(timestamp: event, partition: "2026/09/14", input: 100, cached: 20, output: 10)
        }
        let utcSnapshot = try await utc.load(now: now, days: 7, force: true)
        let shanghaiSnapshot = try await shanghai.load(now: now, days: 7, force: true)
        let utcSummary = CodexCostSummary(snapshot: utcSnapshot, calendar: utc.calendar)
        let shanghaiSummary = CodexCostSummary(snapshot: shanghaiSnapshot, calendar: shanghai.calendar)
        #expect(utcSummary.sessionTokens == 0)
        #expect(shanghaiSummary.sessionTokens == 110)
        #expect(utcSummary.last30DaysTokens == 110)
        #expect(shanghaiSummary.last30DaysTokens == 110)
        #expect(utcSummary.bucketTimeZone == "Etc/UTC")
        #expect(shanghaiSummary.bucketTimeZone == "Asia/Shanghai")
        #expect(utcSummary.updatedAt == shanghaiSummary.updatedAt)
    }

    @Test
    func `empty window provenance follows the native window summary`() throws {
        let summary = RemoteCostFixture.summary(tokens: nil, cost: nil, complete: false)
        #expect(summary.provenance == .unknown)
        #expect(summary.sessionTokens == nil)
        #expect(summary.sessionCostUSD == nil)
        try summary.validate(historyDays: 7)
    }
}

private struct ScannerFixture {
    let root: URL
    let home: URL
    let cache: URL
    let calendar: Calendar

    init(zone: String = "Etc/UTC") throws {
        self.root = try RemoteCostFixture.directory()
        self.home = self.root.appendingPathComponent("custom-codex-home")
        self.cache = self.root.appendingPathComponent("native-cache")
        self.calendar = CostUsageBucketTimeZone.calendar(identifier: zone)
        try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.cache, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: self.root) }

    func load(now: Date, days: Int, force: Bool) async throws -> CostUsageTokenSnapshot {
        var options = CostUsageScanner.Options(
            cacheRoot: self.cache,
            codexTraceDatabaseURL: self.home.appendingPathComponent("missing-traces.sqlite"),
            calendar: self.calendar)
        options.refreshMinIntervalSeconds = 0
        return try await CostUsageFetcher(scannerOptions: options).loadTokenSnapshot(
            provider: .codex,
            environment: ["HOME": self.root.path, "CODEX_HOME": self.home.path],
            now: now,
            forceRefresh: force,
            codexHomePath: self.home.path,
            historyDays: days,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false)
    }

    @discardableResult
    func writeSession(timestamp: Date, partition: String, input: Int, cached: Int, output: Int) throws -> URL {
        let directory = self.home.appendingPathComponent("sessions/\(partition)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-synthetic.jsonl")
        try self.events(timestamp: timestamp, input: input, cached: cached, output: output)
            .write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Same turn_context + token_count shape as the existing CostUsageFetcherTests native-session fixtures.
    func events(timestamp: Date, input: Int, cached: Int, output: Int) throws -> String {
        let iso = ISO8601DateFormatter().string(from: timestamp)
        let objects: [[String: Any]] = [
            ["type": "turn_context", "timestamp": iso, "payload": ["model": "gpt-5.4"]],
            ["type": "event_msg", "timestamp": iso, "payload": [
                "type": "token_count", "info": [
                    "model": "gpt-5.4", "last_token_usage": [
                        "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                    ],
                ],
            ]],
        ]
        return try objects
            .map { try #require(String(data: JSONSerialization.data(withJSONObject: $0), encoding: .utf8)) }
            .joined(separator: "\n") + "\n"
    }

    func pricing(multiplier: Double, now: Date) throws {
        let json = """
        {"openai":{"id":"openai","models":{"gpt-5.4":{"id":"gpt-5.4","cost":{
        "input":\(3 * multiplier),"output":\(12 * multiplier),"cache_read":\(0.3 * multiplier)
        }}}}}
        """
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
        try #require(ModelsDevCache.save(catalog: catalog, fetchedAt: now, cacheRoot: self.cache))
    }
}

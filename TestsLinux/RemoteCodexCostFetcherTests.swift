import Foundation
import Testing
@testable import CodexBarCore

struct RemoteCodexCostFetcherTests {
    @Test(arguments: ["Research-Server", "Alice@Host.Example", "alice@Host.Example", "127.0.0.1", "_alias", "local"])
    func `safe targets preserve their exact spelling`(_ target: String) async throws {
        let json = try RemoteCostFixture.json([RemoteCostFixture.summary()])
        let fetcher = RemoteCodexCostFetcher(environment: [:]) { binary, arguments, environment, timeout, limit in
            #expect(binary == "/usr/bin/ssh")
            #expect(arguments[arguments.count - 2] == target)
            #expect(environment.isEmpty)
            #expect(timeout == 60)
            #expect(limit == 16384)
            return SubprocessResult(stdout: json, stderr: "")
        }
        _ = try await fetcher.fetch(target: target, historyDays: 7, forceRefresh: false)
    }

    @Test(arguments: [
        "", "-host", " host", "host ", "host\n", "host\r", "host\u{0000}", "host\t", "主机", "a,b", "a b",
        "a@b@c", "@host", "user@", "user@-host", "ssh://host", "host:22", "[::1]", "host;id", "host'id",
        "host\"id", "host`id`", "host$(id)", "host/id", String(repeating: "a", count: 256),
    ])
    func `unsafe targets are rejected before the runner`(_ target: String) async {
        let fetcher = RemoteCodexCostFetcher(environment: [:]) { _, _, _, _, _ in
            Issue.record("runner must not launch for an invalid target")
            return SubprocessResult(stdout: "", stderr: "")
        }
        await #expect(throws: RemoteCodexCostError.invalidTarget) {
            try await fetcher.fetch(target: target, historyDays: 7, forceRefresh: false)
        }
    }

    @Test
    func `target boundary and SSH policy are fixed`() throws {
        try RemoteCodexCostFetcher.validateTarget(String(repeating: "a", count: 255))
        let arguments = RemoteCodexCostFetcher.arguments(target: "Alice@Host", historyDays: 365, forceRefresh: true)
        for option in [
            "BatchMode=yes", "ConnectTimeout=5", "StrictHostKeyChecking=yes", "ClearAllForwardings=yes",
            "ControlMaster=no", "ControlPath=none", "ControlPersist=no", "ForkAfterAuthentication=no",
            "PermitLocalCommand=no",
        ] {
            let index = try #require(arguments.firstIndex(of: option))
            #expect(arguments[index - 1] == "-o")
        }
        #expect(Array(arguments.prefix(4)) == ["-n", "-T", "-a", "-x"])
        let command = try #require(arguments.last)
        #expect(command.hasPrefix("sh -lc 'if command -v codexbar"))
        #expect(command.hasSuffix("; fi'"))
        #expect(!command.contains("Alice"))
        #expect(!command.contains("--remote"))
        #expect(command.components(separatedBy: "--days 365 --refresh").count == 3)
        #expect(command.contains("else exec /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"))
        #expect(!command.contains("||"))
    }

    @Test(arguments: ["not JSON", "banner\n[]", "[]", "{}", "[{},{}]", "null"])
    func `unframed and incompatible responses fail closed`(_ stdout: String) async {
        let fetcher = self.fetcher(stdout: stdout)
        await #expect(throws: RemoteCodexCostError.invalidSummary) {
            try await fetcher.fetch(target: "server", historyDays: 7, forceRefresh: false)
        }
    }

    @Test
    func `numeric metadata and required fields are validated`() async throws {
        let valid = try RemoteCostFixture.object()
        let mutations: [(String, Any)] = [
            ("provider", "claude"), ("currencyCode", "EUR"), ("historyDays", 30), ("historyDays", 0),
            ("bucketTimeZone", "not/a/time-zone"), ("updatedAt", "yesterday"),
            ("provenance", "invented"), ("sessionTokens", -1), ("last30DaysTokens", -1),
            ("sessionTokens", UInt64.max), ("sessionCostUSD", -0.5), ("last30DaysCostUSD", -1),
            ("coverage", ["priced": -1, "unpriced": 0, "unmetered": 0, "estimated": 0]),
            ("coverage", ["priced": Int.max, "unpriced": 1, "unmetered": 0, "estimated": 0]),
            ("coverage", ["priced": 0, "unpriced": Int.max, "unmetered": 1, "estimated": 0]),
            ("coverage", ["priced": 0, "unpriced": 0, "unmetered": Int.max, "estimated": 1]),
        ]
        for (key, value) in mutations {
            var object = valid
            object[key] = value
            try await self.expectInvalid(RemoteCostFixture.jsonObject(object))
        }
        for key in [
            "provider", "updatedAt", "bucketTimeZone", "currencyCode", "historyDays",
            "historyCoverageIsEstablished", "provenance", "coverage",
        ] {
            var object = valid
            object.removeValue(forKey: key)
            try await self.expectInvalid(RemoteCostFixture.jsonObject(object))
        }
        for value in ["NaN", "Infinity", "1e999", "9223372036854775808"] {
            let json = try RemoteCostFixture.jsonObject(valid)
            let key = value == "9223372036854775808" ? "sessionTokens" : "sessionCostUSD"
            let pattern = "\"\(key)\":\\s*[-0-9.eE+]+"
            let invalid = json.replacingOccurrences(
                of: pattern,
                with: "\"\(key)\":\(value)",
                options: .regularExpression)
            #expect(invalid != json)
            await self.expectInvalid(invalid)
        }
        try await self.expectInvalid(RemoteCostFixture.json([RemoteCostFixture.summary(), RemoteCostFixture.summary()]))
    }

    @Test
    func `unknown fields and stderr are never forwarded`() async throws {
        var object = try RemoteCostFixture.object()
        object["prompt"] = "PRIVATE_PROMPT_CANARY"
        object["daily"] = [["project": "/PRIVATE_PATH_CANARY"]]
        object["host"] = "untrusted-host"
        let summary = try await self.fetcher(
            stdout: RemoteCostFixture.jsonObject(object), stderr: "PRIVATE_STDERR_CANARY")
            .fetch(target: "client-label", historyDays: 7, forceRefresh: false)
        let encoded = try RemoteCostFixture.json([summary])
        #expect(!encoded.contains("PRIVATE"))
        #expect(!encoded.contains("untrusted-host"))
        #expect(!encoded.contains("daily"))
        #expect(summary.updatedAt == RemoteCostFixture.now)
    }

    @Test
    func `missing numbers partial history and largest valid integer remain valid`() async throws {
        var object = try RemoteCostFixture.object()
        object.removeValue(forKey: "sessionCostUSD")
        object.removeValue(forKey: "last30DaysCostUSD")
        object["sessionTokens"] = Int.max
        object["coverage"] = ["priced": Int.max, "unpriced": 0, "unmetered": 0, "estimated": 0]
        object["historyCoverageIsEstablished"] = false
        let summary = try await self.fetcher(stdout: RemoteCostFixture.jsonObject(object))
            .fetch(target: "server", historyDays: 7, forceRefresh: false)
        #expect(summary.sessionCostUSD == nil)
        #expect(summary.last30DaysCostUSD == nil)
        #expect(summary.sessionTokens == Int.max)
        #expect(summary.coverage.total == Int.max)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `runner failures are sanitized and cancellation propagates`() async {
        let cases: [(SubprocessRunnerError, RemoteCodexCostError)] = [
            (.nonZeroExit(code: 255, stderr: "PRIVATE_STDERR_CANARY"), .unavailable),
            (.launchFailed("/PRIVATE_PATH_CANARY"), .unavailable),
            (.binaryNotFound("PRIVATE_BINARY_CANARY"), .unavailable),
            (.timedOut("PRIVATE_LABEL_CANARY"), .timedOut),
            (.outputTooLarge("PRIVATE_OUTPUT_CANARY"), .outputTooLarge),
        ]
        for (failure, expected) in cases {
            let fetcher = RemoteCodexCostFetcher(environment: [:]) { _, _, _, _, _ in throw failure }
            await #expect(throws: expected) {
                try await fetcher.fetch(target: "server", historyDays: 7, forceRefresh: false)
            }
            #expect(!expected.localizedDescription.contains("PRIVATE"))
        }
        let cancelled = RemoteCodexCostFetcher(environment: [:]) { _, _, _, _, _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await cancelled.fetch(target: "server", historyDays: 7, forceRefresh: false)
        }
    }

    @Test
    func `injected oversized stdout and stderr are rejected`() async throws {
        let json = try RemoteCostFixture.json([RemoteCostFixture.summary()])
        for pair in [(String(repeating: "x", count: 16385), ""), (json, String(repeating: "x", count: 16385))] {
            await #expect(throws: RemoteCodexCostError.outputTooLarge) {
                try await self.fetcher(stdout: pair.0, stderr: pair.1)
                    .fetch(target: "server", historyDays: 7, forceRefresh: false)
            }
        }
    }

    @Test
    func `each call obtains its own target result without cached fallback`() async throws {
        actor Replies {
            var targets: [String] = []
            func next(_ target: String) throws -> String {
                self.targets.append(target)
                if self.targets.count == 2 { throw SubprocessRunnerError.nonZeroExit(code: 255, stderr: "private") }
                return try RemoteCostFixture.json([RemoteCostFixture.summary(tokens: self.targets.count)])
            }
        }
        let replies = Replies()
        let fetcher = RemoteCodexCostFetcher(environment: [:]) { _, arguments, _, _, _ in
            let target = arguments[arguments.count - 2]
            return try await SubprocessResult(stdout: replies.next(target), stderr: "")
        }
        #expect(try await fetcher.fetch(target: "A", historyDays: 7, forceRefresh: false).sessionTokens == 1)
        await #expect(throws: RemoteCodexCostError.unavailable) {
            try await fetcher.fetch(target: "A", historyDays: 7, forceRefresh: false)
        }
        #expect(try await fetcher.fetch(target: "B", historyDays: 7, forceRefresh: false).sessionTokens == 3)
        #expect(await replies.targets == ["A", "A", "B"])
    }

    private func fetcher(stdout: String, stderr: String = "") -> RemoteCodexCostFetcher {
        RemoteCodexCostFetcher(environment: [:]) { _, _, _, _, _ in
            SubprocessResult(stdout: stdout, stderr: stderr)
        }
    }

    private func expectInvalid(_ stdout: String) async {
        await #expect(throws: RemoteCodexCostError.invalidSummary) {
            try await self.fetcher(stdout: stdout).fetch(target: "server", historyDays: 7, forceRefresh: false)
        }
    }
}

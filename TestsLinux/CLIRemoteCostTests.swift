import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIRemoteCostTests {
    @Test
    func `legacy commands do not select the new mode`() throws {
        for arguments in [[], ["--provider", "both"], ["--provider", "claude", "--json", "--breakdown"]] {
            let values = try self.values(arguments)
            let request = try CLIRemoteCostRequest.parse(
                values: values, selection: .both, output: .from(values: values))
            #expect(request == nil)
        }
    }

    @Test
    func `summary mode uses resolved output preferences`() throws {
        for arguments in [["--json"], ["--json-only"], ["--format", "json"], ["--json", "--pretty"]] {
            let request = try self.request(["--summary-only"] + arguments)
            #expect(request.target == nil)
        }
        #expect(throws: (any Error).self) { try self.request(["--summary-only"]) }
        #expect(throws: (any Error).self) { try self.request(["--summary-only", "--pretty"]) }
    }

    @Test
    func `conflicting flags repeated targets and non Codex selections fail before execution`() throws {
        let arguments = [
            ["--remote", "one", "--remote", "two"], ["--remote", "one", "--remote", "one"],
            ["--remote", "one,two"], ["--remote", "one", "--summary-only", "--json"],
            ["--remote", "one", "--breakdown"], ["--remote", "one", "--group-by", "none"],
            ["--summary-only", "--json", "--group-by", "project"], ["--summary-only", "--json", "--breakdown"],
        ]
        for argument in arguments {
            #expect(throws: (any Error).self) { try self.request(argument) }
        }
        for selection in [ProviderSelection.both, .all, .single(.cursor), .single(.claude), .custom([])] {
            for argument in [["--remote", "one"], ["--summary-only", "--json"]] {
                #expect(throws: (any Error).self) { try self.request(argument, selection: selection) }
            }
        }
    }

    @Test
    func `history normalization and refresh agree for both sources`() async throws {
        for (raw, expected) in [("1", 1), ("7", 7), ("30", 30), ("365", 365), ("0", 1), ("999", 365)] {
            let request = try self.request([
                "--remote", "Alice@Host", "--days", raw, "--refresh", "--provider-native-only",
            ])
            var calls: [String] = []
            let result = try await CLIRemoteCostCommand.execute(
                request: request,
                loadLocal: { days, refresh in
                    #expect(days == expected)
                    #expect(refresh)
                    calls.append("local")
                    return RemoteCostFixture.summary(days: days)
                },
                loadRemote: { target, days, refresh in
                    #expect(target == "Alice@Host")
                    #expect(days == expected)
                    #expect(refresh)
                    calls.append("remote")
                    return RemoteCostFixture.summary(days: days)
                })
            #expect(!result.failed)
            #expect(calls == ["local", "remote"])
        }
        #expect(try self.request(["--remote", "one"]).historyDays == 30)
        let malformed = ParsedValues(positional: [], options: ["days": ["invalid"]], flags: [])
        #expect(CodexBarCLI.decodeCostHistoryDays(from: malformed) == 30)
    }

    @Test
    func `summary allowlist preserves partial unknown values and never invokes SSH`() async throws {
        let request = try self.request(["--summary-only", "--json", "--days", "7"])
        let result = try await CLIRemoteCostCommand.execute(
            request: request,
            loadLocal: { _, _ in RemoteCostFixture.summary(tokens: nil, cost: nil, complete: false) },
            loadRemote: { _, _, _ in
                Issue.record("summary-only must not invoke SSH")
                throw CancellationError()
            })
        #expect(!result.failed)
        let json = CLIRemoteCostCommand.renderJSON(result, summaryOnly: true, pretty: true)
        let objects = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(objects.count == 1)
        let object = try #require(objects.first)
        #expect(Set(object.keys) == [
            "provider", "updatedAt", "bucketTimeZone", "currencyCode", "historyDays",
            "historyCoverageIsEstablished", "provenance", "coverage",
        ])
        #expect(object["historyCoverageIsEstablished"] as? Bool == false)
        let full = try RemoteCostFixture.object()
        #expect(Set(full.keys) == Set(object.keys).union([
            "sessionTokens", "sessionCostUSD", "last30DaysTokens", "last30DaysCostUSD",
        ]))
        let coverage = try #require(full["coverage"] as? [String: Any])
        #expect(Set(coverage.keys) == ["priced", "unpriced", "unmetered", "estimated"])
        let text = CLIRemoteCostCommand.renderText(result)
        #expect(text.contains("Partial history coverage"))
        #expect(text.contains("unknown"))
        #expect(!text.contains("$0"))
    }

    @Test
    func `summary failure emits one empty JSON document and a sanitized failure`() async throws {
        let result = try await CLIRemoteCostCommand.execute(
            request: self.request(["--summary-only", "--json"]),
            loadLocal: { _, _ in throw TestError.privatePath },
            loadRemote: { _, _, _ in
                Issue.record("unexpected remote execution")
                throw TestError.privatePath
            })
        #expect(result.failed)
        #expect(CLIRemoteCostCommand.renderJSON(result, summaryOnly: true, pretty: false) == "[]")
        #expect(!String(describing: result.reports).contains("PRIVATE_CANARY"))
    }

    @Test
    func `all four success failure combinations retain independent ordered reports`() async throws {
        for localOK in [true, false] {
            for remoteOK in [true, false] {
                var calls: [String] = []
                let local = RemoteCostFixture.summary(zone: "Asia/Shanghai")
                let remote = RemoteCostFixture.summary(zone: "America/New_York")
                let result = try await CLIRemoteCostCommand.execute(
                    request: self.request(["--remote", "local", "--days", "7"]),
                    loadLocal: { _, _ in
                        calls.append("local")
                        if !localOK { throw TestError.privatePath }
                        return local
                    },
                    loadRemote: { _, _, _ in
                        calls.append("remote")
                        if !remoteOK { throw TestError.privatePath }
                        return remote
                    })
                #expect(calls == ["local", "remote"])
                #expect(result.failed == !(localOK && remoteOK))
                #expect(result.reports.map(\.host) == ["local", "local"])
                #expect(result.reports.map(\.source) == [.local, .ssh])
                #expect(result.reports[0].summary == (localOK ? local : nil))
                #expect(result.reports[1].summary == (remoteOK ? remote : nil))
                let json = CLIRemoteCostCommand.renderJSON(result, summaryOnly: false, pretty: false)
                let objects = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
                #expect(objects.count == 2)
                for object in objects {
                    #expect(Set(object.keys) == ["host", "source", object["summary"] == nil ? "error" : "summary"])
                }
                #expect(!json.contains("PRIVATE_CANARY"))
                let text = CLIRemoteCostCommand.renderText(result)
                #expect(text.contains("This machine"))
                #expect(text.contains("local (SSH)"))
                #expect(!text.contains("Combined"))
                #expect(!text.contains("aggregate"))
                if localOK { #expect(text.contains("Day boundaries: Asia/Shanghai")) }
                if remoteOK { #expect(text.contains("Day boundaries: America/New_York")) }
            }
        }
    }

    @Test
    func `cancellation stops the source sequence instead of becoming a report`() async throws {
        let request = try self.request(["--remote", "one"])
        await #expect(throws: CancellationError.self) {
            try await CLIRemoteCostCommand.execute(
                request: request,
                loadLocal: { _, _ in throw CancellationError() },
                loadRemote: { _, _, _ in
                    Issue.record("remote must not start after local cancellation")
                    throw TestError.privatePath
                })
        }
        await #expect(throws: CancellationError.self) {
            try await CLIRemoteCostCommand.execute(
                request: request,
                loadLocal: { days, _ in RemoteCostFixture.summary(days: days) },
                loadRemote: { _, _, _ in throw CancellationError() })
        }
    }

    private func values(_ arguments: [String]) throws -> ParsedValues {
        try CommandParser(signature: CodexBarCLI._costSignatureForTesting()).parse(arguments: arguments)
    }

    private func request(_ arguments: [String], selection: ProviderSelection = .single(.codex)) throws
        -> CLIRemoteCostRequest
    {
        let values = try self.values(arguments)
        return try #require(try CLIRemoteCostRequest.parse(
            values: values,
            selection: selection,
            output: .from(values: values)))
    }

    private enum TestError: LocalizedError {
        case privatePath
        var errorDescription: String? {
            "/PRIVATE_CANARY/account/session.jsonl"
        }
    }
}

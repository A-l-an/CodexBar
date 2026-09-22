import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct CodexSSHCostWindowTests {
    @Test(arguments: [UsageProvider.codex, .claude])
    func `only Codex offers an SSH report even without a local snapshot`(provider: UsageProvider) {
        let settings = testSettingsStore(
            suiteName: "CodexSSHCostWindowTests-menu",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])
        store.accountInfoCache[provider.instanceID] = UsageStore.AccountInfoCacheEntry(
            account: AccountInfo(email: nil, plan: nil),
            configRevision: settings.configRevision,
            expiresAt: .distantFuture)
        let menu = MenuDescriptor.build(
            provider: provider,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            versionText: "")
        let actions = menu.sections.flatMap(\.entries).compactMap { entry -> MenuDescriptor.MenuAction? in
            guard case let .action(_, action) = entry else { return nil }
            return action
        }
        #expect(actions.contains(.openCodexSSHCostReport) == (provider == .codex))
        #expect(MenuDescriptor.MenuAction.openCodexSSHCostReport.systemImageName == "network")
        #expect(!settings.costUsageEnabled)
    }

    @Test
    func `opening a report and rejecting an invalid host do not read either source`() async throws {
        let calls = Calls()
        let summary = try Self.summary()
        let query = CodexSSHCostQuery(
            local: { _ in await calls.record("local"); return summary },
            remote: { _ in await calls.record("remote"); return summary })
        #expect(!query.isRunning)
        #expect(query.reports.isEmpty)
        #expect(await calls.values.isEmpty)

        query.setHost("-oProxyCommand=bad")
        #expect(!query.canRefresh)
        query.refresh(calendar: Self.calendar)
        await query.waitUntilIdle()
        #expect(await calls.values.isEmpty)
        #expect(query.message == RemoteCodexCostError.invalidHost.localizedDescription)
    }

    @Test(arguments: [false, true], [false, true])
    func `each source keeps its own success or safe failure`(localFails: Bool, remoteFails: Bool) async throws {
        let calls = Calls()
        let local = try Self.summary(cost: 1.25)
        let remote = try Self.summary(cost: 2.5, updatedAt: "2026-05-01T08:00:00Z", timeZone: "Asia/Shanghai")
        let query = CodexSSHCostQuery(
            local: { _ in
                await calls.record("local")
                if localFails { throw FixtureError.privatePath }
                return local
            },
            remote: { host in
                await calls.record(host)
                if remoteFails { throw FixtureError.privatePath }
                return remote
            })
        query.setHost("  research-server  ")
        query.refresh(calendar: Self.calendar)
        await query.waitUntilIdle()

        #expect(await calls.values == ["local", "research-server"])
        #expect(query.reports.count == 2)
        #expect(query.reports[0].source == "local")
        #expect(query.reports[1].host == "research-server")
        #expect(query.reports[0].summary == (localFails ? nil : local))
        #expect(query.reports[1].summary == (remoteFails ? nil : remote))
        #expect(query.reports[0].error == (localFails ? "Local Codex cost history is unavailable." : nil))
        #expect(query.reports[1].error == (remoteFails ? RemoteCodexCostError.unavailable.localizedDescription : nil))
        #expect(!query.isRunning)
        query.setHost("other-server")
        #expect(query.reports.isEmpty)
    }

    @Test(arguments: [false, true])
    func `cancel drains the current task and discards even an uncancellable late result`(
        clearResults: Bool) async throws
    {
        let summary = try Self.summary()
        let gate = Gate()
        let calls = Calls()
        let query = CodexSSHCostQuery(
            local: { _ in summary },
            remote: { _ in
                await calls.record("remote")
                return await gate.load()
            })
        query.setHost("first-server")
        query.refresh(calendar: Self.calendar)
        await gate.waitUntilStarted()
        #expect(query.reports.first?.summary == summary)
        query.setHost("ignored-while-running")
        #expect(query.host == "first-server")

        query.cancel(clearResults: clearResults)
        #expect(query.isRunning)
        #expect(!query.canRefresh)
        query.refresh(calendar: Self.calendar)
        #expect(await calls.values == ["remote"])
        await gate.release(summary)
        await query.waitUntilIdle()
        #expect(!query.isRunning)
        #expect(query.reports.count == (clearResults ? 0 : 1))
        #expect(query.message == (clearResults ? nil : "Cancelled"))
        query.setHost("next-server")
        #expect(query.canRefresh)
        #expect(query.reports.isEmpty)
    }

    @Test
    func `cancelling local history never starts SSH`() async throws {
        let summary = try Self.summary()
        let calls = Calls()
        let gate = Gate()
        let query = CodexSSHCostQuery(
            local: { _ in await gate.load() },
            remote: { _ in await calls.record("remote"); return summary })
        query.setHost("test-server")
        query.refresh(calendar: Self.calendar)
        await gate.waitUntilStarted()
        query.cancel(clearResults: true)
        await gate.release(summary)
        await query.waitUntilIdle()
        #expect(query.reports.isEmpty)
        #expect(await calls.values.isEmpty)
    }

    @Test
    func `presentation distinguishes missing zero small positive and partial costs`() throws {
        #expect(CodexSSHCostView.amountText(nil) == "Unknown")
        #expect(CodexSSHCostView.amountText(0) == "$0.00")
        #expect(CodexSSHCostView.amountText(0.00075) == "<$0.01")
        #expect(CodexSSHCostView.amountText(1.25) == "$1.25")
        let summary = try Self.summary(cost: nil, complete: false, unpriced: 2, incomplete: 3)
        let hints = CodexSSHCostView.coverageHints(summary)
        #expect(hints.contains("Partial history; scan is incomplete."))
        #expect(hints.contains("Some usage has no known price."))
        #expect(hints.contains("Today: 3 incomplete requests excluded."))
        #expect(hints.contains("Last 30 days: 3 incomplete requests excluded."))
        #expect(CodexSSHCostView.hostTitle("private-user@private-host", hidden: true) == "SSH host")
        #expect(CodexSSHCostView.hostTitle("research-server", hidden: false) == "research-server")
    }

    private enum FixtureError: Error {
        case privatePath
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    static func summary(
        cost: Double? = 1.25,
        updatedAt: String = "2026-05-01T07:00:00Z",
        timeZone: String = "GMT",
        complete: Bool = true,
        unpriced: Int = 0,
        incomplete: Int = 0) throws -> CodexCostSummary
    {
        let window: [String: Any] = [
            "totalTokens": 1000,
            "costUSD": cost.map { $0 as Any } ?? NSNull(),
            "incompleteRequestCount": incomplete,
            "coverage": ["priced": 1, "unpriced": unpriced, "unmetered": 0, "estimated": 0],
            "provenance": "listPriceEstimate",
        ]
        let object: [String: Any] = [
            "schemaVersion": 1, "provider": "codex", "updatedAt": updatedAt,
            "bucketTimeZone": timeZone, "currencyCode": "USD", "historyDays": 30,
            "historyCoverageIsEstablished": complete, "today": window, "history": window,
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexCostSummary.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private actor Calls {
        var values: [String] = []

        func record(_ value: String) {
            self.values.append(value)
        }
    }

    private actor Gate {
        private var result: CheckedContinuation<CodexCostSummary, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func load() async -> CodexCostSummary {
            await withCheckedContinuation { continuation in
                self.result = continuation
                self.started?.resume()
                self.started = nil
            }
        }

        func waitUntilStarted() async {
            guard self.result == nil else { return }
            await withCheckedContinuation { self.started = $0 }
        }

        func release(_ summary: CodexCostSummary) {
            self.result?.resume(returning: summary)
            self.result = nil
        }
    }
}

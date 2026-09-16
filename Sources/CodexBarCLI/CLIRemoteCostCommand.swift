import CodexBarCore
import Commander
import Foundation

struct CLIRemoteCostRequest: Sendable {
    let target: String?
    let historyDays: Int
    let forceRefresh: Bool

    static func parse(
        values: ParsedValues,
        selection: ProviderSelection,
        output: CLIOutputPreferences) throws -> Self?
    {
        let targets = values.options["remote"]
        let summaryOnly = values.flags.contains("summaryOnly")
        guard targets != nil || summaryOnly else { return nil }
        // Provider-specific by design: this transport serves only native Codex cost summaries.
        guard selection.asList == [.codex] else {
            throw ArgumentError("--remote and --summary-only require --provider codex.")
        }
        guard values.options["groupBy"] == nil, !values.flags.contains("breakdown") else {
            throw ArgumentError("--remote and --summary-only do not support --group-by or --breakdown.")
        }
        guard !(targets != nil && summaryOnly) else {
            throw ArgumentError("--remote and --summary-only cannot be used together.")
        }
        if summaryOnly, output.format != .json {
            throw ArgumentError("--summary-only requires JSON output (--format json, --json, or --json-only).")
        }
        if let targets {
            guard targets.count == 1, let target = targets.first else {
                throw ArgumentError("Specify --remote exactly once with one SSH target.")
            }
            try RemoteCodexCostFetcher.validateTarget(target)
        }
        return Self(
            target: targets?.first,
            historyDays: CodexBarCLI.decodeCostHistoryDays(from: values),
            forceRefresh: values.flags.contains("refresh"))
    }

    private struct ArgumentError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? {
            self.message
        }
    }
}

struct CodexHostCostReport: Encodable, Sendable {
    enum Source: String, Encodable, Sendable { case local, ssh }
    enum Outcome { case success(CodexCostSummary), failure(String) }

    let host: String
    let source: Source
    let summary: CodexCostSummary?
    let error: String?

    init(host: String, source: Source, outcome: Outcome) {
        self.host = host
        self.source = source
        switch outcome {
        case let .success(summary):
            self.summary = summary
            self.error = nil
        case let .failure(error):
            self.summary = nil
            self.error = error
        }
    }
}

struct CLIRemoteCostResult: Sendable {
    let reports: [CodexHostCostReport]
    var failed: Bool {
        self.reports.contains { $0.error != nil }
    }
}

enum CLIRemoteCostCommand {
    static let localFailure = "Could not read local native Codex costs. Check the local Codex history."
    typealias LocalLoader = (Int, Bool) async throws -> CodexCostSummary
    typealias RemoteLoader = (String, Int, Bool) async throws -> CodexCostSummary

    static func execute(
        request: CLIRemoteCostRequest,
        loadLocal: LocalLoader,
        loadRemote: RemoteLoader) async throws -> CLIRemoteCostResult
    {
        try Task.checkCancellation()
        var reports: [CodexHostCostReport] = []
        do {
            let summary = try await loadLocal(request.historyDays, request.forceRefresh)
            try Task.checkCancellation()
            try summary.validate(historyDays: request.historyDays)
            reports.append(CodexHostCostReport(host: "local", source: .local, outcome: .success(summary)))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            reports.append(CodexHostCostReport(host: "local", source: .local, outcome: .failure(self.localFailure)))
        }
        if let target = request.target {
            try Task.checkCancellation()
            do {
                let summary = try await loadRemote(target, request.historyDays, request.forceRefresh)
                try Task.checkCancellation()
                try summary.validate(historyDays: request.historyDays)
                reports.append(CodexHostCostReport(host: target, source: .ssh, outcome: .success(summary)))
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw CancellationError() }
                let safeError = (error as? RemoteCodexCostError) ?? .unavailable
                reports.append(CodexHostCostReport(
                    host: target, source: .ssh, outcome: .failure(safeError.localizedDescription)))
            }
        }
        return CLIRemoteCostResult(reports: reports)
    }

    /// Translate terminal signals to task cancellation so the runner can terminate its own process group.
    static func withTermination(
        operation: @escaping @Sendable () async throws -> CLIRemoteCostResult) async throws -> CLIRemoteCostResult
    {
        let task = Task { try await operation() }
        let monitor = CLITerminationSignalMonitor { _ in task.cancel() }
        defer { monitor.cancel() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func renderJSON(_ result: CLIRemoteCostResult, summaryOnly: Bool, pretty: Bool) -> String {
        if summaryOnly {
            return CodexBarCLI.encodeJSON(result.reports.compactMap(\.summary), pretty: pretty) ?? "[]"
        }
        return CodexBarCLI.encodeJSON(result.reports, pretty: pretty) ?? "[]"
    }

    static func renderText(_ result: CLIRemoteCostResult) -> String {
        var sections = ["Codex API-equivalent estimates (not billed)"]
        for report in result.reports {
            let label = report.source == .local ? "This machine" : "\(report.host) (SSH)"
            guard let summary = report.summary else {
                sections.append("\(label)\nError: \(report.error ?? self.localFailure)")
                continue
            }
            func line(_ label: String, tokens: Int?, cost: Double?) -> String {
                let amount = cost.map { UsageFormatter.currencyString($0, currencyCode: summary.currencyCode) }
                    ?? "unknown"
                let count = tokens.map { UsageFormatter.tokenCountString($0) } ?? "unknown"
                return "\(label): \(amount) · \(count) tokens"
            }
            var lines = [
                label,
                line("Today", tokens: summary.sessionTokens, cost: summary.sessionCostUSD),
                line(
                    "Last \(summary.historyDays) days",
                    tokens: summary.last30DaysTokens,
                    cost: summary.last30DaysCostUSD),
                "Day boundaries: \(summary.bucketTimeZone)",
                "Updated: \(summary.updatedAt.formatted(.iso8601))",
            ]
            if !summary.historyCoverageIsEstablished { lines.append("Partial history coverage.") }
            if summary.coverage.unpriced > 0 { lines.append("Some usage has unknown pricing.") }
            if summary.coverage.unmetered > 0 { lines.append("Some usage is unmetered.") }
            sections.append(lines.joined(separator: "\n"))
        }
        sections.append("Reports are separate. Overlapping histories are not added together.\n"
            + "Native Codex history only; pi/OMP mirrors are excluded.")
        return sections.joined(separator: "\n\n")
    }
}

extension CodexBarCLI {
    static func runRemoteCostIfRequested(
        values: ParsedValues,
        selection: ProviderSelection,
        output: CLIOutputPreferences) async
    {
        do {
            guard let request = try CLIRemoteCostRequest.parse(values: values, selection: selection, output: output)
            else {
                return
            }
            await Self.runRemoteCost(request: request, output: output)
        } catch {
            exit(code: .failure, message: error.localizedDescription, output: output, kind: .args)
        }
    }

    static func runRemoteCost(request: CLIRemoteCostRequest, output: CLIOutputPreferences) async -> Never {
        let calendar = CostUsageBucketTimeZone.calendar(
            identifier: Self.stringFromAppDefaults("tokenCostUsageBucketTimeZone"))
        let fetcher = CostUsageFetcher(calendar: calendar)
        do {
            let result = try await CLIRemoteCostCommand.withTermination {
                try await CLIRemoteCostCommand.execute(
                    request: request,
                    loadLocal: { days, refresh in
                        // Provider-specific by design: no pi/OMP or other providers enter this summary.
                        let snapshot = try await fetcher.loadTokenSnapshot(
                            provider: .codex,
                            forceRefresh: refresh,
                            historyDays: days,
                            refreshPricingInBackground: false,
                            includePiSessions: false)
                        return CodexCostSummary(snapshot: snapshot, calendar: calendar)
                    },
                    loadRemote: { target, days, refresh in
                        try await RemoteCodexCostFetcher().fetch(
                            target: target,
                            historyDays: days,
                            forceRefresh: refresh)
                    })
            }
            if output.format == .json {
                print(CLIRemoteCostCommand.renderJSON(
                    result,
                    summaryOnly: request.target == nil,
                    pretty: output.pretty))
            } else {
                print(CLIRemoteCostCommand.renderText(result))
            }
            if request.target == nil, result.failed, !output.jsonOnly {
                Self.writeStderr("\(CLIRemoteCostCommand.localFailure)\n")
            }
            // stdout already contains the complete document. Do not emit an additional JSON error on exit.
            Self.exit(code: result.failed ? .failure : .success, output: output)
        } catch {
            Self.exit(code: .failure, output: output)
        }
    }
}

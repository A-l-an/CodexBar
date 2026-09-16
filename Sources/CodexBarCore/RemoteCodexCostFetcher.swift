import Foundation

/// The only cost fields sent between hosts. Unknown numbers remain absent, never zero-filled.
public struct CodexCostSummary: Codable, Sendable, Equatable {
    public let provider: String
    public let updatedAt: Date
    public let bucketTimeZone: String
    public let currencyCode: String
    public let historyDays: Int
    public let historyCoverageIsEstablished: Bool
    public let provenance: CostProvenance
    public let coverage: CostUsageCoverageCounts
    public let sessionTokens: Int?
    public let sessionCostUSD: Double?
    public let last30DaysTokens: Int?
    public let last30DaysCostUSD: Double?

    public init(snapshot: CostUsageTokenSnapshot, calendar: Calendar) {
        // Provider-specific by design: this bounded transport only describes native Codex history.
        self.provider = "codex"
        self.updatedAt = snapshot.updatedAt
        self.bucketTimeZone = calendar.timeZone.identifier
        self.currencyCode = snapshot.currencyCode
        self.historyDays = snapshot.historyDays
        self.historyCoverageIsEstablished = snapshot.historyCoverageIsEstablished
        let window = snapshot.summary(forLastDays: snapshot.historyDays, calendar: calendar)
        self.provenance = window.provenance
        self.coverage = window.coverage
        self.sessionTokens = snapshot.sessionTokens
        self.sessionCostUSD = snapshot.sessionCostUSD
        self.last30DaysTokens = snapshot.last30DaysTokens
        self.last30DaysCostUSD = snapshot.last30DaysCostUSD
    }

    public func validate(historyDays: Int) throws {
        // Provider-specific by design: reject summaries from other providers before rendering.
        guard self.provider == "codex",
              self.currencyCode == "USD",
              (1...365).contains(historyDays), self.historyDays == historyDays,
              CostUsageBucketTimeZone.isValidIdentifier(self.bucketTimeZone),
              self.updatedAt.timeIntervalSince1970.isFinite,
              [self.sessionTokens, self.last30DaysTokens].allSatisfy({ $0.map { $0 >= 0 } ?? true }),
              [self.sessionCostUSD, self.last30DaysCostUSD].allSatisfy({
                  guard let value = $0 else { return true }
                  return value.isFinite && value >= 0
              })
        else { throw RemoteCodexCostError.invalidSummary }

        // Coverage's convenience properties sum Ints without overflow checks. Validate before using them.
        var total = 0
        for count in [self.coverage.priced, self.coverage.unpriced, self.coverage.unmetered, self.coverage.estimated] {
            let sum = total.addingReportingOverflow(count)
            guard count >= 0, !sum.overflow else { throw RemoteCodexCostError.invalidSummary }
            total = sum.partialValue
        }
    }
}

public enum RemoteCodexCostError: LocalizedError, Sendable, Equatable {
    case invalidTarget
    case unavailable
    case timedOut
    case outputTooLarge
    case invalidSummary

    public var errorDescription: String? {
        switch self {
        case .invalidTarget:
            "Use one SSH alias, hostname, or user@host "
                + "(ASCII letters, digits, dots, underscores, hyphens; max 255 bytes)."
        case .unavailable:
            "Could not read remote Codex costs. Check SSH and that the remote CLI supports --summary-only."
        case .timedOut:
            "Remote Codex cost request timed out."
        case .outputTooLarge:
            "Remote Codex cost response exceeded the size limit."
        case .invalidSummary:
            "Remote CLI returned an invalid or incompatible Codex cost summary."
        }
    }
}

/// One explicit SSH request; no host discovery, raw-history transfer, or remote-result cache.
public struct RemoteCodexCostFetcher: Sendable {
    static let outputLimit = 16384
    typealias Runner = @Sendable (String, [String], [String: String], TimeInterval, Int) async throws
        -> SubprocessResult
    private let environment: [String: String]
    private let runner: Runner

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(environment: environment, runner: { binary, arguments, environment, timeout, limit in
            try await SubprocessRunner.run(
                binary: binary,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                maxOutputBytes: limit,
                acceptsNonZeroExit: false,
                label: "remote Codex cost")
        })
    }

    init(environment: [String: String], runner: @escaping Runner) {
        self.environment = environment
        self.runner = runner
    }

    public static func validateTarget(_ target: String) throws {
        let parts = target.split(separator: "@", omittingEmptySubsequences: false)
        guard !target.isEmpty, target.utf8.count <= 255, parts.count <= 2,
              parts.allSatisfy({ part in
                  func isStart(_ byte: UInt8) -> Bool {
                      (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95
                  }
                  guard let first = part.utf8.first, isStart(first) else { return false }
                  return part.utf8.allSatisfy { isStart($0) || $0 == 46 || $0 == 45 }
              })
        else { throw RemoteCodexCostError.invalidTarget }
    }

    static func arguments(target: String, historyDays: Int, forceRefresh: Bool) -> [String] {
        let options = "cost --provider codex --format json --summary-only --provider-native-only --days \(historyDays)"
            + (forceRefresh ? " --refresh" : "")
        // Only a validated Int and Bool vary in this template. OpenSSH joins the command arguments,
        // so pass the entire quoted command as one argument, including the quotes around the sh script.
        let script = "if command -v codexbar >/dev/null 2>&1; then exec codexbar \(options); "
            + "else exec /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI \(options); fi"
        return [
            "-n", "-T", "-a", "-x",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes",
            "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no", "-o", "PermitLocalCommand=no",
            target, "sh -lc '\(script)'",
        ]
    }

    public func fetch(target: String, historyDays: Int, forceRefresh: Bool) async throws -> CodexCostSummary {
        try Self.validateTarget(target)
        guard (1...365).contains(historyDays) else { throw RemoteCodexCostError.invalidSummary }
        try Task.checkCancellation()
        let result: SubprocessResult
        do {
            result = try await self.runner(
                "/usr/bin/ssh",
                Self.arguments(target: target, historyDays: historyDays, forceRefresh: forceRefresh),
                self.environment,
                60,
                Self.outputLimit)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            switch error {
            case SubprocessRunnerError.timedOut: throw RemoteCodexCostError.timedOut
            case SubprocessRunnerError.outputTooLarge: throw RemoteCodexCostError.outputTooLarge
            default: throw RemoteCodexCostError.unavailable
            }
        }
        try Task.checkCancellation()
        guard result.stdout.utf8.count <= Self.outputLimit, result.stderr.utf8.count <= Self.outputLimit else {
            throw RemoteCodexCostError.outputTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let summaries = try? decoder.decode([CodexCostSummary].self, from: Data(result.stdout.utf8)),
              summaries.count == 1, let summary = summaries.first
        else { throw RemoteCodexCostError.invalidSummary }
        try summary.validate(historyDays: historyDays)
        return summary
    }
}

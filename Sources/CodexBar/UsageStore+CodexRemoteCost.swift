import CodexBarCore
import CryptoKit
import Foundation
import Observation

extension UsageStore {
    func remoteCostPresentationEnabled(for provider: UsageProvider) -> Bool {
        provider == .codex && self.codexRemoteCosts.enabled &&
            self.tokenCostScope(for: .codex).signature == "codex:ambient"
    }

    func costPresentationShowsInline(for provider: UsageProvider) -> Bool {
        self.settings.costSummaryShowsInline(for: provider) ||
            (self.remoteCostPresentationEnabled(for: provider) && self.settings.costSummaryDisplayStyle
                .showsInlineSummary)
    }

    func costPresentationShowsSubmenu(for provider: UsageProvider) -> Bool {
        self.settings.costSummaryShowsSubmenu(for: provider) ||
            (self.remoteCostPresentationEnabled(for: provider) && self.settings.costSummaryDisplayStyle
                .showsCostSubmenu)
    }

    func codexRemoteCostContext(now: Date = Date()) -> CodexRemoteCostContext {
        let calendar = self.settings.costUsageBucketCalendar
        let home = CodexHomeScope.ambientHomeURL(env: self.environmentBase).resolvingSymlinksInPath()
        let pricingRoot = self.codexRemotePricingCacheRoot
        let defaultPricingRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        let catalog = (pricingRoot ?? defaultPricingRoot)
            .appendingPathComponent("model-pricing/models-dev-v1.json")
        let custom = pricingRoot?.appendingPathComponent(CostUsageCustomPricing.fileName)
            ?? CostUsageCustomPricing.defaultFileURL()
        let revision = [catalog, custom].map { url in
            (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).description } ?? "absent"
        }.joined(separator: ":")
        return CodexRemoteCostContext(
            source: self.codexRemoteCosts.source,
            localCodexHome: home,
            localScope: self.tokenCostScope(for: .codex).signature,
            historyDays: self.settings.costUsageHistoryDays,
            calendar: calendar,
            day: calendar.startOfDay(for: now),
            pricingRevision: revision,
            sshRevision: CodexRemoteLogMirror.configurationFingerprint(environment: self.environmentBase),
            pricingCacheRoot: pricingRoot,
            localCostCacheRoot: self.codexRemoteLocalCostCacheRoot,
            now: now)
    }

    /// Only the ambient menu/settings cost presentation consults this selector. Publication and spend stay local.
    func codexCostPresentationSnapshot(now: Date = Date()) -> CostUsageTokenSnapshot? {
        guard self.codexRemoteCosts.enabled else { return self.tokenSnapshot(for: .codex) }
        let context = self.codexRemoteCostContext(now: now)
        self.codexRemoteCosts.reconcile(context)
        return self.codexRemoteCosts.selectedResult(context: context)?.snapshot ?? self.tokenSnapshot(for: .codex)
    }

    func codexRemoteCostPresentation(now: Date = Date()) -> CodexRemoteCostPresentation? {
        guard self.codexRemoteCosts.enabled else { return nil }
        let context = self.codexRemoteCostContext(now: now)
        self.codexRemoteCosts.reconcile(context)
        guard context.isAmbient else { return nil }
        let state = self.codexRemoteCosts
        let result = state.selectedResult(context: context)
        let host = self.settings.hidePersonalInfo ? "Server" : context.source.host
        let title = result == nil ? "Only this Mac" : "Native Codex · This Mac + \(host)"
        var details = [
            result == nil ? "This Mac’s local cost history" : "Native Codex logs",
            "Day boundary: \(context.calendar.timeZone.identifier)",
        ]
        if let result {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            formatter.timeZone = context.calendar.timeZone
            details.append("As of \(formatter.string(from: result.capturedTo))")
        }
        var status: String
        if let error = state.errorMessage {
            status = error
        } else if state.isRunning {
            switch state.phase {
            case .fetching: status = "Fetching server logs…"
            case .scanning: status = "Scanning native logs…"
            case .cleaning: status = "Removing temporary logs…"
            case nil: status = "Cancelling and removing temporary logs…"
            }
        } else if let result {
            let snapshot = result.snapshot
            let hasUnpriced = snapshot.daily.contains { ($0.unpricedRequestCount ?? 0) > 0 || $0.costUSD == nil }
            let quality = snapshot.historyCoverageIsEstablished && snapshot.last30DaysCostUSD != nil && !hasUnpriced
                ? "" : "Partial known values; missing prices or history are not zero. "
            status = quality + result.notices.joined(separator: " ")
        } else {
            status = state.needsRefresh ? "Server statistics need a manual refresh." : "Server has not been read."
        }
        if result == nil, self.tokenSnapshot(for: .codex) == nil {
            status += " This Mac’s local history is unavailable; no zero amount is assumed."
        }
        return CodexRemoteCostPresentation(
            title: title,
            detail: details.joined(separator: " · "),
            status: status,
            isCombined: result != nil)
    }

    func refreshCodexRemoteCosts() {
        let context = self.codexRemoteCostContext()
        self.codexRemoteCosts.refresh(context: context) { [weak self] in
            self?.codexRemoteCostContext() ?? context
        }
    }

    func observeCodexRemoteCostContext() {
        withObservationTracking {
            _ = self.settings.costUsageHistoryDays
            _ = self.settings.costUsageBucketTimeZoneIdentifier
            _ = self.settings.codexLocalSessionCostLedgerEnabled
            _ = self.settings.codexActiveSource
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.codexRemoteCosts.enabled {
                    self.codexRemoteCosts.reconcile(self.codexRemoteCostContext())
                }
                self.observeCodexRemoteCostContext()
            }
        }
    }
}

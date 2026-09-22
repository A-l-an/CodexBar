import AppKit
import CodexBarCore
import Observation
import SwiftUI

/// One explicit query. This state never participates in the app's ordinary refresh or totals.
@MainActor
@Observable
final class CodexSSHCostQuery {
    typealias LocalLoader = @Sendable (Calendar) async throws -> CodexCostSummary
    typealias RemoteLoader = @Sendable (String) async throws -> CodexCostSummary

    private(set) var host = ""
    private(set) var reports: [CodexHostCostReport] = []
    private(set) var isRunning = false
    private(set) var isCancelling = false
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let local: LocalLoader
    @ObservationIgnored private let remote: RemoteLoader

    init(
        local: @escaping LocalLoader = { calendar in
            // Provider-specific by design: this window compares native Codex histories only.
            let snapshot = try await CostUsageFetcher(calendar: calendar).loadTokenSnapshot(
                provider: .codex,
                historyDays: 30,
                allowPricingRefresh: false,
                refreshPricingInBackground: false,
                includePiSessions: false)
            return CodexCostSummary(snapshot: snapshot, calendar: calendar)
        },
        remote: @escaping RemoteLoader = { host in
            try await RemoteCodexCostFetcher().fetch(host: host, historyDays: 30)
        })
    {
        self.local = local
        self.remote = remote
    }

    var canRefresh: Bool {
        guard !self.isRunning else { return false }
        do {
            try RemoteCodexCostFetcher.validateHost(self.host.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        } catch {
            return false
        }
    }

    func setHost(_ host: String) {
        guard !self.isRunning, self.host != host else { return }
        self.host = host
        self.reports = []
        self.message = nil
    }

    func refresh(calendar: Calendar) {
        guard self.task == nil else { return }
        let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try RemoteCodexCostFetcher.validateHost(host)
        } catch {
            self.message = RemoteCodexCostError.invalidHost.localizedDescription
            return
        }
        let local = self.local
        let remote = self.remote
        self.reports = []
        self.isRunning = true
        self.message = "Reading this Mac…"
        self.task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.isRunning = false
                self.isCancelling = false
            }
            do {
                try Task.checkCancellation()
                let localReport = try await Self.readReport(host: "local", source: "local") {
                    try await local(calendar)
                }
                try Task.checkCancellation()
                self.reports.append(localReport)
                self.message = "Reading SSH host…"
                let remoteReport = try await Self.readReport(host: host, source: "ssh") {
                    try await remote(host)
                }
                try Task.checkCancellation()
                self.reports.append(remoteReport)
                self.message = nil
            } catch is CancellationError {
                if !self.isCancelling { self.message = "Cancelled" }
            } catch {
                self.message = "Cost history unavailable"
            }
        }
    }

    func cancel(clearResults: Bool = false) {
        if clearResults {
            self.reports = []
            self.message = nil
        }
        guard let task = self.task else { return }
        self.isCancelling = true
        if !clearResults { self.message = "Cancelled" }
        task.cancel()
    }

    func waitUntilIdle() async {
        await self.task?.value
    }

    private nonisolated static func readReport(
        host: String,
        source: String,
        operation: @Sendable () async throws -> CodexCostSummary) async throws -> CodexHostCostReport
    {
        do {
            let summary = try await operation()
            try Task.checkCancellation()
            return .init(host: host, source: source, summary: summary)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let message = source == "local"
                ? "Local Codex cost history is unavailable."
                : ((error as? RemoteCodexCostError)?.localizedDescription
                    ?? RemoteCodexCostError.unavailable.localizedDescription)
            return .init(host: host, source: source, summary: nil, error: message)
        }
    }
}

@MainActor
final class CodexSSHCostWindowController: NSWindowController, NSWindowDelegate {
    let query: CodexSSHCostQuery

    convenience init(settings: SettingsStore) {
        let query = CodexSSHCostQuery()
        self.init(query: query, content: CodexSSHCostSettingsView(query: query, settings: settings))
    }

    init(query: CodexSSHCostQuery, content: some View) {
        self.query = query
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = L("Codex SSH Cost Report")
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        self.query.cancel(clearResults: true)
    }
}

extension StatusItemController {
    @objc func openCodexSSHCostReport() {
        let controller = self.codexSSHCostWindow ?? CodexSSHCostWindowController(settings: self.settings)
        self.codexSSHCostWindow = controller
        controller.present()
    }
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
@testable import CodexBarCore

struct RemoteCodexCostSubprocessTests {
    @Test(arguments: [false, true])
    func `real runner enforces the capture limit on each stream`(stderr: Bool) async throws {
        let command = "printf '%020000d' 0" + (stderr ? " >&2" : "")
        do {
            _ = try await SubprocessRunner.run(
                binary: "/bin/sh",
                arguments: ["-c", command],
                environment: [:],
                timeout: 5,
                maxOutputBytes: 16384,
                label: "synthetic output limit")
            Issue.record("oversized subprocess output was accepted")
        } catch SubprocessRunnerError.outputTooLarge {
            // The shared runner rejects its bounded captures before decoding or exposing stream contents.
        }
        let exact = try await SubprocessRunner.run(
            binary: "/bin/sh",
            arguments: ["-c", "printf '%016384d' 0"],
            environment: [:],
            timeout: 5,
            maxOutputBytes: 16384,
            label: "synthetic exact limit")
        #expect(exact.stdout.utf8.count == 16384)
    }

    @Test
    func `real timeout terminates the launched local process`() async throws {
        let directory = try RemoteCostFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        do {
            _ = try await SubprocessRunner.run(
                binary: "/bin/sh",
                arguments: ["-c", "echo $$ > \"$1\"; exec sleep 30", "test", pidFile.path],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 0.2,
                maxOutputBytes: 16384,
                label: "synthetic timeout")
            Issue.record("timeout was not propagated")
        } catch SubprocessRunnerError.timedOut {
            let pid = try self.pid(at: pidFile)
            #expect(kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test
    func `real cancellation terminates the launched local process`() async throws {
        let directory = try RemoteCostFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let task = Task {
            try await SubprocessRunner.run(
                binary: "/bin/sh",
                arguments: ["-c", "echo $$ > \"$1\"; exec sleep 30", "test", pidFile.path],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 10,
                maxOutputBytes: 16384,
                label: "synthetic cancellation")
        }
        defer { task.cancel() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try self.pid(at: pidFile)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func `final SSH command survives outer shell parsing and does not retry a failing executable`() async throws {
        let directory = try RemoteCostFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("calls")
        // A controlled login-shell stand-in avoids sourcing the developer's shell startup files.
        // The outer shell still parses the exact final command string passed to OpenSSH.
        try FakeExecutable.install("""
        [ "$1" = '-lc' ] || exit 91
        exec /bin/sh -c "$2"
        """, at: directory.appendingPathComponent("sh"))
        try FakeExecutable.install("""
        printf 'called\\n' >> "$MARKER"
        printf '%s\\n' "$@"
        exit "$RESULT"
        """, at: directory.appendingPathComponent("codexbar"))
        let command = try #require(RemoteCodexCostFetcher.arguments(
            target: "Alice@Host", historyDays: 7, forceRefresh: true).last)
        let environment = ["PATH": "\(directory.path):/usr/bin:/bin", "MARKER": marker.path, "RESULT": "0"]
        let result = try await SubprocessRunner.run(
            binary: "/bin/sh",
            arguments: ["-c", command],
            environment: environment,
            timeout: 5,
            maxOutputBytes: 16384,
            label: "synthetic remote command")
        #expect(result.stdout.split(separator: "\n").map(String.init) == [
            "cost", "--provider", "codex", "--format", "json", "--summary-only", "--provider-native-only",
            "--days", "7", "--refresh",
        ])
        var failedEnvironment = environment
        failedEnvironment["RESULT"] = "23"
        do {
            _ = try await SubprocessRunner.run(
                binary: "/bin/sh",
                arguments: ["-c", command],
                environment: failedEnvironment,
                timeout: 5,
                maxOutputBytes: 16384,
                label: "synthetic remote failure")
            Issue.record("nonzero CLI status was accepted")
        } catch let SubprocessRunnerError.nonZeroExit(code, _) {
            #expect(code == 23)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "called\ncalled\n")
    }

    private func pid(at url: URL) throws -> pid_t {
        try #require(pid_t(String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

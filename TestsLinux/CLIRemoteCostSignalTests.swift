#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIRemoteCostSignalTests {
    private static let childKey = "CODEXBAR_REMOTE_COST_SIGNAL_TEST"
    private static let directoryKey = "CODEXBAR_REMOTE_COST_SIGNAL_DIRECTORY"

    @Test(arguments: [SIGINT, SIGTERM, SIGHUP])
    func `terminal signals cancel the operation and reap its local child`(_ signalNumber: Int32) async throws {
        if let requested = ProcessInfo.processInfo.environment[Self.childKey] {
            guard requested == String(signalNumber) else { return }
            let directory = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment[Self.directoryKey]))
            try await Self.childScenario(directory: directory)
            return
        }
        let directory = try RemoteCostFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--filter", "CLIRemoteCostSignalTests", "--testing-library", "swift-testing"]
        if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
           CommandLine.arguments.indices.contains(index + 1)
        {
            process.arguments = ["--test-bundle-path", CommandLine.arguments[index + 1]] + (process.arguments ?? [])
        }
        var environment = ProcessInfo.processInfo.environment
        environment[Self.childKey] = String(signalNumber)
        environment[Self.directoryKey] = directory.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: pidFile.path) || !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let childPID = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(childPID, 0) == 0 { kill(childPID, SIGKILL) } }
        #expect(kill(process.processIdentifier, signalNumber) == 0)
        for _ in 0..<500 {
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!process.isRunning)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled").path))
        #expect(kill(childPID, 0) == -1)
        #expect(errno == ESRCH)
    }

    private static func childScenario(directory: URL) async throws {
        do {
            _ = try await CLIRemoteCostCommand.withTermination {
                _ = try await SubprocessRunner.run(
                    binary: "/bin/sh",
                    arguments: [
                        "-c",
                        "echo $$ > \"$1\"; exec sleep 30",
                        "test",
                        directory.appendingPathComponent("pid").path,
                    ],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: 10,
                    maxOutputBytes: 16384,
                    label: "synthetic signal cancellation")
                return CLIRemoteCostResult(reports: [])
            }
            Issue.record("signal did not cancel the operation")
        } catch is CancellationError {
            try Data().write(to: directory.appendingPathComponent("cancelled"))
        }
    }
}

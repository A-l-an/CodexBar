import Foundation
import Testing
@testable import CodexBarCore

struct CLIRemoteCostProcessTests {
    @Test
    func `actual CLI rejects incompatible parameters with one JSON error before creating scan caches`() throws {
        let directory = try RemoteCostFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(CodexBarConfig.makeDefault()).write(to: config)
        let cli = try Self.cliBinary()
        for arguments in [
            ["--provider", "cursor", "--remote", "server"],
            ["--provider", "both", "--summary-only"],
            ["--provider", "codex", "--remote", "one", "--remote", "two"],
            ["--provider", "codex", "--remote", "one", "--group-by", "session"],
            ["--provider", "codex", "--summary-only", "--breakdown"],
            ["--provider", "codex", "--summary-only", "--remote", "one"],
        ] {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["cost", "--json-only"] + arguments
            process.environment = [
                "PATH": "/usr/bin:/bin",
                "HOME": directory.path,
                "CFFIXED_USER_HOME": directory.path,
                "__CFPREFERENCES_AVOID_DAEMON": "1",
                "XDG_CACHE_HOME": directory.appendingPathComponent("cache").path,
                "CODEX_HOME": directory.appendingPathComponent("codex").path,
                "CODEXBAR_CONFIG": config.path,
                "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
                "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
                "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1",
            ]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let objects = try #require(JSONSerialization.jsonObject(
                with: stdout.fileHandleForReading.readDataToEndOfFile()) as? [[String: Any]])
            #expect(process.terminationStatus != 0)
            #expect(objects.count == 1)
            let error = try #require(objects.first?["error"] as? [String: Any])
            #expect(error["kind"] as? String == "args")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("cache").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("codex").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Library/Caches").path))
    }

    private static func cliBinary() throws -> URL {
        let bundleIndex = CommandLine.arguments.firstIndex(of: "--test-bundle-path")
        let testPath = bundleIndex.map { CommandLine.arguments[$0 + 1] } ?? CommandLine.arguments[0]
        var directory = URL(fileURLWithPath: testPath).deletingLastPathComponent()
        for _ in 0..<6 {
            let binary = directory.appendingPathComponent("CodexBarCLI")
            if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "CLIRemoteCostProcessTests", code: 1)
    }
}

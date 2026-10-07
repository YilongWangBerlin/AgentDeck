import AgentDeckCore
import AgentDeckParsing
import Foundation

func date(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: iso) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDeckCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A private copy of the parsing package's synthetic fixtures that a test may append to, truncate or
/// delete. Removed again by `cleanUp()`.
struct TestLogs {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/AgentDeckParsing/Tests/AgentDeckParsingTests/Fixtures")

    let root: URL
    let locations: LogLocations

    init() throws {
        root = try temporaryDirectory()
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("claude"), to: root.appendingPathComponent("claude"))
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("codex"), to: root.appendingPathComponent("codex"))
        locations = LogLocations(
            claudeProjectDirectories: [root.appendingPathComponent("claude")],
            codexHome: root.appendingPathComponent("codex")
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    var claudeSession: URL { root.appendingPathComponent("claude/-tmp-demo/11111111-1111-4111-8111-111111111111.jsonl") }
    var claudeSubagent: URL { root.appendingPathComponent("claude/-tmp-demo/11111111-1111-4111-8111-111111111111/subagents/agent-a1.jsonl") }
    var claudeResumed: URL { root.appendingPathComponent("claude/-tmp-demo/22222222-2222-4222-8222-222222222222.jsonl") }
    var codexLegacy: URL { codexRollout("2026/09/08/rollout-2026-09-08T10-00-00", 3) }
    var codexTransition: URL { codexRollout("2026/10/06/rollout-2026-10-06T02-00-00", 5) }
    var importsFile: URL { locations.codexImportsFile }

    static func codexThread(_ n: Int) -> String { "0199aaaa-0000-7000-8000-00000000000\(n)" }

    private func codexRollout(_ prefix: String, _ n: Int) -> URL {
        root.appendingPathComponent("codex/sessions/\(prefix)-\(Self.codexThread(n)).jsonl")
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}

/// Thread-safe call counter for callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

import Foundation
import Testing
@testable import AgentDeckParsing

/// Synthetic logs that mirror the real formats documented in FORMATS.md. No real data.
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static let claudeProjects = root.appendingPathComponent("claude")
    static let claudeSession = claudeProjects.appendingPathComponent("-tmp-demo/11111111-1111-4111-8111-111111111111.jsonl")
    static let claudeSubagent = claudeProjects.appendingPathComponent("-tmp-demo/11111111-1111-4111-8111-111111111111/subagents/agent-a1.jsonl")
    static let claudeResumed = claudeProjects.appendingPathComponent("-tmp-demo/22222222-2222-4222-8222-222222222222.jsonl")
    static let claudeFiles = [claudeSession, claudeSubagent, claudeResumed]
    static let claudeSessionA = "11111111-1111-4111-8111-111111111111"
    static let claudeSessionB = "22222222-2222-4222-8222-222222222222"

    static let codexHome = root.appendingPathComponent("codex")
    static let importsFile = codexHome.appendingPathComponent("external_agent_session_imports.json")
    static let codexMain = codexRollout("2026/10/06/rollout-2026-10-06T01-02-43", 1)
    static let codexGuardian = codexRollout("2026/10/06/rollout-2026-10-06T01-05-00", 2)
    static let codexLegacy = codexRollout("2026/09/08/rollout-2026-09-08T10-00-00", 3)
    static let codexImported = codexRollout("2026/09/07/rollout-2026-09-07T15-03-06", 4)
    static let codexTransition = codexRollout("2026/10/06/rollout-2026-10-06T02-00-00", 5)
    static let codexFiles = [codexMain, codexGuardian, codexLegacy, codexImported, codexTransition]

    static func codexThread(_ n: Int) -> String { "0199aaaa-0000-7000-8000-00000000000\(n)" }

    private static func codexRollout(_ prefix: String, _ n: Int) -> URL {
        codexHome.appendingPathComponent("sessions/\(prefix)-\(codexThread(n)).jsonl")
    }

    static func date(_ iso: String) -> Date {
        guard let date = Timestamp.parse(iso) else { fatalError("bad fixture date \(iso)") }
        return date
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDeckParsingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A copy of the first `byteCount` bytes of `url`, with the same file name (Codex reads the thread
    /// id from it). Cutting mid-line simulates a file that is still being written.
    static func prefixCopy(of url: URL, byteCount: Int, in directory: URL) throws -> URL {
        let copy = directory.appendingPathComponent(url.lastPathComponent)
        try Data(contentsOf: url).prefix(byteCount).write(to: copy)
        return copy
    }
}

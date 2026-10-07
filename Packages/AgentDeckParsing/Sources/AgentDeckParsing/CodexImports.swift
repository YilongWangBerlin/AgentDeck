import Foundation

/// Reads `external_agent_session_imports.json`, Codex Desktop's list of sessions it copied from other
/// agents. Those copies hold Claude Code usage stamped at import time, so they must not count as Codex
/// usage. See FORMATS.md section 2.7.
public enum CodexImports {
    private struct File: Decodable {
        struct Record: Decodable {
            var importedThreadID: String?

            private enum CodingKeys: String, CodingKey { case importedThreadID = "imported_thread_id" }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                importedThreadID = c.lenient(String.self, .importedThreadID)
            }
        }

        var records: [Record]?
    }

    /// Returns an empty set when the file does not exist. Throws if it exists but cannot be read.
    public static func importedThreadIDs(from url: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return Set((file.records ?? []).compactMap(\.importedThreadID))
    }
}

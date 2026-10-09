import Foundation

/// Where each tool keeps its logs on this machine.
///
/// A GUI app does not inherit variables set in shell profiles, so the app passes its own settings in
/// `environment` rather than relying on `ProcessInfo`.
public struct LogLocations: Equatable, Sendable {
    /// Directories whose `**/*.jsonl` files are Claude Code transcripts.
    public var claudeProjectDirectories: [URL]
    /// `$CODEX_HOME`, or `~/.codex`.
    public var codexHome: URL
    /// The Claude desktop app's record of the plan's usage percentages (FORMATS.md 3.4).
    public var claudePlanUsageFile: URL?

    public init(claudeProjectDirectories: [URL], codexHome: URL, claudePlanUsageFile: URL? = nil) {
        self.claudeProjectDirectories = claudeProjectDirectories
        self.codexHome = codexHome
        self.claudePlanUsageFile = claudePlanUsageFile
    }

    /// `$CLAUDE_CONFIG_DIR/projects` when set, plus `~/.claude/projects` and
    /// `~/.config/claude/projects`; `$CODEX_HOME` or `~/.codex`; the Claude app's
    /// `~/Library/Application Support/Claude/plan-usage-history.json`.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LogLocations {
        var claude: [URL] = []
        if let configured = nonEmpty(environment["CLAUDE_CONFIG_DIR"]) {
            claude.append(URL(fileURLWithPath: configured).appendingPathComponent("projects"))
        }
        claude.append(homeDirectory.appendingPathComponent(".claude/projects"))
        claude.append(homeDirectory.appendingPathComponent(".config/claude/projects"))

        let codexHome = nonEmpty(environment["CODEX_HOME"]).map { URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent(".codex")

        var seen = Set<String>()
        let unique = claude.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let planUsage = homeDirectory.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        return LogLocations(claudeProjectDirectories: unique, codexHome: codexHome, claudePlanUsageFile: planUsage)
    }

    public var codexSessionDirectories: [URL] {
        [codexHome.appendingPathComponent("sessions"), codexHome.appendingPathComponent("archived_sessions")]
    }

    public var codexImportsFile: URL {
        codexHome.appendingPathComponent("external_agent_session_imports.json")
    }

    public func claudeLogFiles() -> [URL] {
        Self.jsonlFiles(under: claudeProjectDirectories)
    }

    public func codexLogFiles() -> [URL] {
        Self.jsonlFiles(under: codexSessionDirectories)
    }

    /// Regular `*.jsonl` files below `directories`, sorted by path. Missing directories are skipped.
    static func jsonlFiles(under directories: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var files: [URL] = []
        for directory in directories {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    files.append(url)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

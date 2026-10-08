import AgentDeckParsing
import CryptoKit
import Foundation

/// Where skills live, and how each tool loads them (FORMATS.md section 4.1).
public struct SkillLocations: Equatable, Sendable {
    /// AgentDeck's canonical store.
    public var canonical: URL
    /// Claude Code loads `<dir>/SKILL.md` one level deep, following symlinks.
    public var claudeUser: URL
    /// Codex loads these recursively.
    public var codexUser: URL
    public var agentsUser: URL
    /// Read-only sources.
    public var claudePlugins: URL
    public var codexPlugins: URL
    public var claudeDesktopManaged: URL

    public init(canonical: URL, claudeUser: URL, codexUser: URL, agentsUser: URL,
                claudePlugins: URL, codexPlugins: URL, claudeDesktopManaged: URL) {
        self.canonical = canonical
        self.claudeUser = claudeUser
        self.codexUser = codexUser
        self.agentsUser = agentsUser
        self.claudePlugins = claudePlugins
        self.codexPlugins = codexPlugins
        self.claudeDesktopManaged = claudeDesktopManaged
    }

    public static func standard(logs: LogLocations, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> SkillLocations {
        let claudeConfig = logs.claudeProjectDirectories.first?.deletingLastPathComponent()
            ?? homeDirectory.appendingPathComponent(".claude")
        return SkillLocations(
            canonical: homeDirectory.appendingPathComponent(".agentdeck/skills"),
            claudeUser: claudeConfig.appendingPathComponent("skills"),
            codexUser: logs.codexHome.appendingPathComponent("skills"),
            agentsUser: homeDirectory.appendingPathComponent(".agents/skills"),
            claudePlugins: claudeConfig.appendingPathComponent("plugins"),
            codexPlugins: logs.codexHome.appendingPathComponent("plugins/cache"),
            claudeDesktopManaged: homeDirectory.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        )
    }
}

public struct DiscoveredSkill: Equatable, Sendable {
    public enum Origin: String, Sendable, CaseIterable {
        case canonical = "AgentDeck"
        case claudeUser = "~/.claude/skills"
        case codexUser = "~/.codex/skills"
        case agentsUser = "~/.agents/skills"
        case codexBundled = "Codex built-in"
        case claudePlugin = "Claude Code plugin"
        case codexPlugin = "Codex plugin"
        case claudeDesktopManaged = "Claude desktop app"
        /// A folder or git checkout the user chose to import from.
        case external = "Imported folder"

        /// Plugin, bundled and app-managed skills are shown but never moved or edited.
        public var isReadOnly: Bool {
            switch self {
            case .canonical, .claudeUser, .codexUser, .agentsUser, .external: false
            case .codexBundled, .claudePlugin, .codexPlugin, .claudeDesktopManaged: true
            }
        }
    }

    public var origin: Origin
    /// The folder holding SKILL.md, as found (not resolved through symlinks).
    public var directory: URL
    /// Where a symlinked folder points, if it is one.
    public var symlinkDestination: URL?
    public var manifest: SkillManifest?
    public var issues: [SkillIssue]
    /// SHA-256 over every file in the folder (path and bytes), so identical copies match.
    public var contentHash: String
    /// The tools that load this copy from where it is now.
    public var loadedBy: Set<SkillTarget>
    /// Set when Claude Code loads this copy as part of a plugin folder in `~/.claude/skills`, which it
    /// lists as `plugin:name`.
    public var pluginName: String? = nil

    /// The frontmatter name, or the folder name when there is none.
    public var name: String { manifest?.name ?? directory.lastPathComponent }
}

/// Finds every skill the two tools can see. Read-only.
public enum SkillScanner {
    public static func scan(_ locations: SkillLocations) -> [DiscoveredSkill] {
        var skills: [DiscoveredSkill] = []
        // Claude Code: one level, symlinks followed. Nested skills in bundles are found too, but marked
        // as not loaded by Claude Code.
        skills += find(in: locations.canonical, origin: .canonical, loadedBy: { _ in [] })
        skills += markPluginSkills(find(in: locations.claudeUser, origin: .claudeUser, loadedBy: { depth in depth == 0 ? [.claudeCode] : [] }),
                                   root: locations.claudeUser)
        skills += find(in: locations.codexUser, origin: .codexUser, loadedBy: { _ in [.codex] }) // hidden .system is skipped
        skills += find(in: locations.codexUser.appendingPathComponent(".system"), origin: .codexBundled, loadedBy: { _ in [.codex] })
        skills += find(in: locations.agentsUser, origin: .agentsUser, loadedBy: { _ in [.codex] })
        skills += find(in: locations.claudePlugins, origin: .claudePlugin, loadedBy: { _ in [] })
        skills += find(in: locations.codexPlugins, origin: .codexPlugin, loadedBy: { _ in [.codex] })
        skills += find(in: locations.claudeDesktopManaged, origin: .claudeDesktopManaged, loadedBy: { _ in [.claudeCode] })
        return skills
    }

    /// A folder in `~/.claude/skills` with `.claude-plugin/plugin.json` is a plugin to Claude Code: the
    /// skills in its `skills/` folder are loaded too, named `plugin:skill` (FORMATS.md 4.1).
    static func markPluginSkills(_ skills: [DiscoveredSkill], root: URL) -> [DiscoveredSkill] {
        let rootPath = root.standardizedFileURL.path + "/"
        return skills.map { skill in
            let path = skill.directory.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { return skill }
            let parts = path.dropFirst(rootPath.count).split(separator: "/")
            guard parts.count == 3, parts[1] == "skills" else { return skill }
            let plugin = root.appendingPathComponent(String(parts[0]))
            guard FileManager.default.fileExists(atPath: plugin.appendingPathComponent(".claude-plugin/plugin.json").path) else { return skill }
            var marked = skill
            marked.loadedBy.insert(.claudeCode)
            marked.pluginName = String(parts[0])
            return marked
        }
    }

    /// Groups by name; a group with more than one distinct hash is a conflict to resolve.
    public static func duplicates(_ skills: [DiscoveredSkill]) -> [String: [DiscoveredSkill]] {
        Dictionary(grouping: skills, by: \.name).filter { $0.value.count > 1 }
    }

    /// Hidden folders are not searched.
    /// - Parameter loadedBy: Which tools load a skill found `depth` folders below `root` (0 = direct child).
    static func find(in root: URL, origin: DiscoveredSkill.Origin, loadedBy: (Int) -> Set<SkillTarget>) -> [DiscoveredSkill] {
        let fileManager = FileManager.default
        var results: [DiscoveredSkill] = []
        var visited = Set<String>()

        func visit(_ directory: URL, depth: Int) {
            guard depth <= 8 else { return }
            let resolved = directory.resolvingSymlinksInPath().path
            guard visited.insert(resolved).inserted else { return }
            guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent
                guard !name.hasPrefix(".") else { continue } // .git, .system, .claude-plugin, ...
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let skillFile = entry.appendingPathComponent("SKILL.md")
                if fileManager.fileExists(atPath: skillFile.path) {
                    results.append(describe(entry, skillFile: skillFile, origin: origin, loadedBy: loadedBy(depth)))
                } else {
                    visit(entry, depth: depth + 1)
                }
            }
        }
        visit(root, depth: 0)
        return results
    }

    static func describe(_ directory: URL, skillFile: URL, origin: DiscoveredSkill.Origin, loadedBy: Set<SkillTarget>) -> DiscoveredSkill {
        let text = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
        var manifest: SkillManifest?
        var parseError: Error?
        do { manifest = try SkillManifest.parse(text) } catch { parseError = error }
        let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path))
            .map { URL(fileURLWithPath: $0, relativeTo: directory.deletingLastPathComponent()).standardizedFileURL }
        return DiscoveredSkill(
            origin: origin,
            directory: directory,
            symlinkDestination: destination,
            manifest: manifest,
            issues: SkillValidator.issues(manifest: manifest, parseError: parseError, directoryName: directory.lastPathComponent),
            contentHash: contentHash(of: directory),
            loadedBy: loadedBy
        )
    }

    /// SHA-256 over relative path and bytes of every regular file, in path order. `.DS_Store` and
    /// `.git` are ignored.
    public static func contentHash(of directory: URL) -> String {
        let root = directory.resolvingSymlinksInPath()
        var files: [(String, URL)] = []
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name == ".git" { enumerator.skipDescendants(); continue }
                guard name != ".DS_Store",
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                files.append((String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count)), url))
            }
        }
        var hasher = SHA256()
        for (path, url) in files.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: (try? Data(contentsOf: url)) ?? Data())
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

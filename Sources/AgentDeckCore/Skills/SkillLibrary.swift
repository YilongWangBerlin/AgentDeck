import Foundation

/// A list of file changes, computed without touching anything, shown to the user, and applied only
/// after confirmation.
public struct SkillPlan: Equatable, Sendable {
    public enum Existing: Equatable, Sendable {
        case nothing
        case symlink(to: URL)
        /// A real folder: the user's original. It is only ever moved into the backup, and only when
        /// the user confirmed that explicitly.
        case folder
    }

    public enum Step: Equatable, Sendable {
        /// Copy a skill folder into the library under `name`.
        case importSkill(name: String, from: URL, source: String)
        /// Point `link` at the library copy of `name`.
        case link(name: String, target: SkillTarget, link: URL, replacing: Existing)
        /// Remove an AgentDeck symlink (never a real folder).
        case unlink(name: String, target: SkillTarget, link: URL)
    }

    public var steps: [Step] = []
    public var warnings: [String] = []

    public init(steps: [Step] = [], warnings: [String] = []) {
        self.steps = steps
        self.warnings = warnings
    }

    public var isEmpty: Bool { steps.isEmpty }

    /// Original folders this plan would move into the backup.
    public var originalsToMove: [URL] {
        steps.compactMap { if case .link(_, _, let link, .folder) = $0 { link } else { nil } }
    }

    /// One readable line per step, for the confirmation sheet.
    public var summary: [String] {
        steps.map { step in
            switch step {
            case let .importSkill(name, from, _):
                return "Copy \(name) into the AgentDeck library from \(Self.tilde(from))"
            case let .link(name, target, link, existing):
                let action = "Enable \(name) for \(target.rawValue): link \(Self.tilde(link))"
                switch existing {
                case .nothing: return action
                case .symlink(let old): return action + " (replaces a link to \(Self.tilde(old)), backed up)"
                case .folder: return action + " (moves the existing folder into the backup)"
                }
            case let .unlink(name, target, link):
                return "Disable \(name) for \(target.rawValue): remove the link \(Self.tilde(link)) (backed up)"
            }
        }
    }

    /// The path with the home folder shown as `~`.
    public static func tilde(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Two or more copies of a skill with different content. The user picks one before importing.
public struct ImportConflict: Equatable, Sendable {
    public var name: String
    public var copies: [DiscoveredSkill]

    /// SKILL.md differences between the first copy and each other copy.
    public var preview: String {
        guard let first = copies.first else { return "" }
        let base = (try? String(contentsOf: first.directory.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
        return copies.dropFirst().map { copy in
            let other = (try? String(contentsOf: copy.directory.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
            let diff = LineDiff.unified(from: base, to: other)
            return "\(first.origin.rawValue) → \(copy.origin.rawValue)\n" + (diff.isEmpty ? "  SKILL.md is identical; other files differ." : diff)
        }.joined(separator: "\n\n")
    }
}

public struct ApplyReport: Equatable, Sendable {
    public var imported: [String] = []
    public var linked: [String] = []
    public var unlinked: [String] = []
    public var backup: URL?
}

/// AgentDeck's canonical skill store (`~/.agentdeck/skills`, a git repository) and the links that
/// enable its skills per tool: `~/.claude/skills/<name>` and `~/.codex/skills/<name>`.
public struct SkillLibrary: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case originalsNeedConfirmation([URL])
        case alreadyInLibrary(String)
        case notAnAgentDeckLink(URL)
        case changedSincePlanned(URL)

        public var description: String {
            switch self {
            case .originalsNeedConfirmation(let urls): "Moving original folders needs your confirmation: \(urls.map(SkillPlan.tilde).joined(separator: ", "))"
            case .alreadyInLibrary(let name): "\(name) is already in the library."
            case .notAnAgentDeckLink(let url): "\(SkillPlan.tilde(url)) is not a link into the AgentDeck library, so it was left alone."
            case .changedSincePlanned(let url): "\(SkillPlan.tilde(url)) changed after the plan was made. Review the plan again."
            }
        }
    }

    public var locations: SkillLocations
    public var backupsRoot: URL

    public init(locations: SkillLocations, backupsRoot: URL) {
        self.locations = locations
        self.backupsRoot = backupsRoot
    }

    var root: URL { locations.canonical }

    // MARK: - Reading

    /// Skills in the library (one level deep).
    public func skills() -> [DiscoveredSkill] {
        SkillScanner.find(in: root, origin: .canonical) { _ in [] }
    }

    public func linkLocation(for target: SkillTarget, name: String) -> URL {
        (target == .claudeCode ? locations.claudeUser : locations.codexUser).appendingPathComponent(name)
    }

    /// Tools whose skill folder links to the library copy of `name`.
    public func enabledTargets(for name: String) -> Set<SkillTarget> {
        Set(SkillTarget.allCases.filter { target in
            guard case .symlink(let destination) = existing(at: linkLocation(for: target, name: name)) else { return false }
            return destination.standardizedFileURL.resolvingSymlinksInPath() == root.appendingPathComponent(name).resolvingSymlinksInPath()
        })
    }

    func existing(at url: URL) -> SkillPlan.Existing {
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return .symlink(to: URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL)
        }
        return FileManager.default.fileExists(atPath: url.path) ? .folder : .nothing
    }

    /// The skill pack each library skill was imported from, such as `research-co-pilot` for
    /// `~/.claude/skills/research-co-pilot/skills/peer-review`. Skills imported on their own have
    /// none. Symlinks are resolved first, so a link at the top of a skills folder still counts.
    public func packs() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [locations.claudeUser, locations.codexUser, locations.agentsUser]
            .map { $0.resolvingSymlinksInPath().path + "/" }
        var result: [String: String] = [:]
        for (name, source) in loadSources() {
            let expanded = source.path.hasPrefix("~") ? home + source.path.dropFirst() : source.path
            let path = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
            guard let root = roots.first(where: { path.hasPrefix($0) }) else { continue }
            let parts = path.dropFirst(root.count).split(separator: "/")
            if parts.count > 1 { result[name] = String(parts[0]) }
        }
        return result
    }

    // MARK: - Planning

    /// Imports every skill the tools can edit (`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`)
    /// that the library lacks. Identical copies import once; differing copies are returned as conflicts
    /// unless `choices` names the copy to take (keyed by skill name).
    public func importPlan(from discovered: [DiscoveredSkill], choices: [String: URL] = [:]) -> (plan: SkillPlan, conflicts: [ImportConflict]) {
        let inLibrary = Set(skills().map(\.name))
        let editable = discovered.filter { [.claudeUser, .codexUser, .agentsUser].contains($0.origin) }
        var plan = SkillPlan()
        var conflicts: [ImportConflict] = []
        for (name, copies) in Dictionary(grouping: editable, by: \.name).sorted(by: { $0.key < $1.key }) {
            guard !inLibrary.contains(name) else { continue }
            // Several paths can reach the same folder (a symlink and its target); count it once.
            var seen = Set<String>()
            let unique = copies.filter { seen.insert($0.directory.resolvingSymlinksInPath().path).inserted }
            let chosen: DiscoveredSkill?
            if let choice = choices[name] {
                // Compare resolved paths: the same folder can arrive as /var/… or /private/var/…, with
                // or without a trailing slash.
                let wanted = choice.resolvingSymlinksInPath().path
                chosen = unique.first { $0.directory.resolvingSymlinksInPath().path == wanted }
            } else if Set(unique.map(\.contentHash)).count == 1 {
                chosen = unique.first
            } else {
                conflicts.append(ImportConflict(name: name, copies: unique))
                continue
            }
            guard let chosen else { continue }
            if chosen.issues.contains(where: { $0.severity == .error }) {
                plan.warnings.append("\(name) has frontmatter errors; it imports, but the tools may not load it.")
            }
            plan.steps.append(.importSkill(name: name, from: chosen.directory, source: chosen.origin.rawValue))
        }
        return (plan, conflicts)
    }

    /// Imports the skills found in a folder (a local path or a fresh `git clone`), skipping names the
    /// library already has.
    public func importFolderPlan(_ folder: URL, source: String) -> SkillPlan {
        var plan = SkillPlan()
        let inLibrary = Set(skills().map(\.name))
        var skills = SkillScanner.find(in: folder, origin: .external) { _ in [] }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) {
            skills.append(SkillScanner.describe(folder, skillFile: folder.appendingPathComponent("SKILL.md"), origin: .external, loadedBy: []))
        }
        if skills.isEmpty { plan.warnings.append("No SKILL.md found in \(SkillPlan.tilde(folder)).") }
        for skill in skills.sorted(by: { $0.name < $1.name }) {
            if inLibrary.contains(skill.name) {
                plan.warnings.append("\(skill.name) is already in the library and was skipped.")
            } else {
                plan.steps.append(.importSkill(name: skill.name, from: skill.directory, source: source))
            }
        }
        return plan
    }

    /// Turns `name` on or off for `target`.
    public func togglePlan(name: String, target: SkillTarget, enabled: Bool, discovered: [DiscoveredSkill] = []) -> SkillPlan {
        let link = linkLocation(for: target, name: name)
        let current = existing(at: link)
        var plan = SkillPlan()
        if enabled {
            guard !enabledTargets(for: name).contains(target) else { return plan }
            plan.steps.append(.link(name: name, target: target, link: link, replacing: current))
            if target == .codex {
                for other in discovered where other.name == name && other.origin == .agentsUser {
                    plan.warnings.append("Codex also loads \(SkillPlan.tilde(other.directory)) and will list \(name) twice.")
                }
            }
            // Built-in and plugin skills are left alone, so a library skill with the same name sits
            // next to them rather than replacing them.
            for other in discovered where other.name == name && other.origin.isReadOnly && other.loadedBy.contains(target) {
                plan.warnings.append("\(target.rawValue) already has a \(other.origin.rawValue) skill named \(name); it will list both.")
            }
        } else if enabledTargets(for: name).contains(target) {
            plan.steps.append(.unlink(name: name, target: target, link: link))
        }
        return plan
    }

    // MARK: - Applying

    /// Applies `plan`: backs up everything it replaces, copies imports into the library and commits
    /// them, then creates or removes links.
    ///
    /// - Parameter allowMovingOriginals: Must be true when the plan replaces real folders; they are
    ///   moved into the backup, never deleted.
    public func apply(_ plan: SkillPlan, allowMovingOriginals: Bool, now: Date = Date()) throws -> ApplyReport {
        if !plan.originalsToMove.isEmpty, !allowMovingOriginals {
            throw Failure.originalsNeedConfirmation(plan.originalsToMove)
        }
        let fileManager = FileManager.default
        try ensureRepository()
        var report = ApplyReport()
        var backup: BackupSession?
        func session() throws -> BackupSession {
            if let backup { return backup }
            let created = try BackupSession(root: backupsRoot, now: now)
            backup = created
            report.backup = created.directory
            return created
        }

        var sources = loadSources()
        for case let .importSkill(name, from, source) in plan.steps {
            let destination = root.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: destination.path) else { throw Failure.alreadyInLibrary(name) }
            try fileManager.copyItem(at: from.resolvingSymlinksInPath(), to: destination)
            try? fileManager.removeItem(at: destination.appendingPathComponent(".git"))
            sources[name] = Source(origin: source, path: SkillPlan.tilde(from), importedAt: ISO8601DateFormatter().string(from: now))
            report.imported.append(name)
        }
        if !report.imported.isEmpty {
            try saveSources(sources)
            try Git.run(["add", "-A"], in: root)
            try Git.run(["-c", "user.name=AgentDeck", "-c", "user.email=agentdeck@localhost",
                         "commit", "-q", "-m", "Import \(report.imported.joined(separator: ", "))"], in: root)
        }

        for step in plan.steps {
            switch step {
            case .importSkill:
                continue
            case let .link(name, _, link, expected):
                let current = existing(at: link)
                guard current == expected else { throw Failure.changedSincePlanned(link) }
                switch current {
                case .nothing: break
                case .symlink:
                    try session().copy(link)
                    try fileManager.removeItem(at: link)
                case .folder:
                    try session().move(link)
                }
                try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent(name))
                report.linked.append(name)
            case let .unlink(name, target, link):
                guard enabledTargets(for: name).contains(target) else { throw Failure.notAnAgentDeckLink(link) }
                try session().copy(link)
                try fileManager.removeItem(at: link)
                report.unlinked.append(name)
            }
        }
        return report
    }

    // MARK: - Library repository

    struct Source: Codable, Equatable {
        var origin: String
        var path: String
        var importedAt: String
    }

    private var sourcesFile: URL { root.appendingPathComponent(".agentdeck-sources.json") }

    func loadSources() -> [String: Source] {
        (try? JSONDecoder().decode([String: Source].self, from: Data(contentsOf: sourcesFile))) ?? [:]
    }

    func saveSources(_ sources: [String: Source]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(sources).write(to: sourcesFile, options: .atomic)
    }

    /// Creates the library folder and its git repository on first use.
    public func ensureRepository() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            try Git.run(["init", "-q"], in: root)
        }
    }
}

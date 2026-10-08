import Foundation

/// A repository AgentDeck publishes to. Only configured targets are ever pushed to.
public struct PublishTarget: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// SVG cards (and optionally a marked README block) in the profile repository.
        case profile
        /// `data.json` for the usage section on a GitHub Pages site.
        case pages
    }

    public enum CommitStrategy: String, Codable, Sendable, CaseIterable {
        /// A new commit for every change.
        case newCommit = "new-commit"
        /// Keep a single AgentDeck commit on top: amend it and force-push (with lease). Only
        /// AgentDeck's own tip commit is ever rewritten; after anyone else's commit a new one starts.
        case amendOwnCommit = "amend"
    }

    public var id = UUID()
    /// Disabled targets are kept in settings but never prepared or pushed.
    public var isEnabled = true
    public var kind: Kind
    /// Any URL `git clone` accepts, e.g. `https://github.com/owner/repo.git`.
    public var remote: String
    public var branch: String
    /// Folder inside the repository that AgentDeck writes to.
    public var folder: String
    public var strategy: CommitStrategy
    /// Profile only: replace the content between `<!-- agentdeck:start -->` and
    /// `<!-- agentdeck:end -->` in the README. Nothing outside the markers is touched.
    public var updateReadmeBlock: Bool

    public init(kind: Kind, remote: String, branch: String = "main", folder: String, strategy: CommitStrategy, updateReadmeBlock: Bool = false) {
        self.kind = kind
        self.remote = remote
        self.branch = branch
        self.folder = folder
        self.strategy = strategy
        self.updateReadmeBlock = updateReadmeBlock
    }
}

/// What a publish would change, prepared in AgentDeck's own clone and staged, but not committed.
public struct PublishPreview: Sendable {
    public enum ReadmeStatus: Equatable, Sendable {
        case notRequested, updated, unchanged, noReadme, noMarkers
    }

    public var target: PublishTarget
    public var checkout: URL
    /// Paths (relative to the repository) whose content changes.
    public var changedPaths: [String]
    /// `git diff --cached`, cut to a readable length.
    public var diff: String
    public var readme: ReadmeStatus

    public var hasChanges: Bool { !changedPaths.isEmpty }
}

public struct PublishResult: Equatable, Sendable {
    public var pushed: Bool
    public var commit: String?
    public var amended: Bool
    public var note: String
}

/// Publishes the export to configured repositories through local clones in `workspace`. Never
/// touches the user's own working copies, and uses the local git credentials.
public struct Publisher: Sendable {
    public struct Identity: Sendable {
        public var name: String
        public var email: String
        public init(name: String, email: String) { self.name = name; self.email = email }
    }

    public static let trailerKey = "AgentDeck-Target"
    public static let startMarker = "<!-- agentdeck:start -->"
    public static let endMarker = "<!-- agentdeck:end -->"

    public var workspace: URL
    /// Commit identity. Nil uses the user's git configuration.
    public var identity: Identity?

    public init(workspace: URL, identity: Identity? = nil) {
        self.workspace = workspace
        self.identity = identity
    }

    /// The `<picture>` block for a profile README, switching card by color scheme.
    public static func readmeSnippet(folder: String) -> String {
        """
        \(startMarker)
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="\(folder)/card-dark.svg" />
          <img alt="Coding agent usage" src="\(folder)/card-light.svg" />
        </picture>
        \(endMarker)
        """
    }

    public func checkout(for target: PublishTarget) -> URL {
        let name = target.remote
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: ".git", with: "")
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return workspace.appendingPathComponent(String(name) + "@" + target.branch)
    }

    // MARK: - Prepare

    /// Brings the clone up to date with the remote, writes the files and stages them.
    public func prepare(_ target: PublishTarget, export: PublicExport) throws -> PublishPreview {
        let repo = try sync(target)
        let folder = repo.appendingPathComponent(target.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var readme = PublishPreview.ReadmeStatus.notRequested
        switch target.kind {
        case .pages:
            try PublicExporter.encode(export).write(to: folder.appendingPathComponent("data.json"), options: .atomic)
        case .profile:
            for theme in UsageCard.Theme.allCases {
                try Data(UsageCard.svg(export, theme: theme).utf8)
                    .write(to: folder.appendingPathComponent("card-\(theme.rawValue).svg"), options: .atomic)
            }
            if target.updateReadmeBlock {
                readme = try updateReadme(in: repo, folder: target.folder)
            }
        }

        try Git.run(["add", "-A", "--", target.folder] + (readme == .updated ? [readmeName(in: repo)!] : []), in: repo)
        let changed = try Git.run(["diff", "--cached", "--name-only"], in: repo)
            .split(separator: "\n").map(String.init)
        var diff = try Git.run(["diff", "--cached", "--stat"], in: repo)
        let full = try Git.run(["diff", "--cached", "--", ":!*.svg"], in: repo)
        if !full.isEmpty { diff += "\n\n" + (full.count > 20_000 ? String(full.prefix(20_000)) + "\n…" : full) }
        return PublishPreview(target: target, checkout: repo, changedPaths: changed, diff: diff, readme: readme)
    }

    /// Clones on first use; afterwards fetches and resets to the remote branch. The clone belongs to
    /// AgentDeck, so resetting it never loses user work.
    func sync(_ target: PublishTarget) throws -> URL {
        let repo = checkout(for: target)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) {
            try Git.run(["clone", "--quiet", "--branch", target.branch, "--single-branch", target.remote, repo.path], in: workspace)
        } else {
            try Git.run(["fetch", "--quiet", "origin", target.branch], in: repo)
            try Git.run(["checkout", "--quiet", "-B", target.branch, "origin/\(target.branch)"], in: repo)
            try Git.run(["reset", "--quiet", "--hard", "origin/\(target.branch)"], in: repo)
            try Git.run(["clean", "--quiet", "-fd"], in: repo)
        }
        return repo
    }

    func readmeName(in repo: URL) -> String? {
        (try? FileManager.default.contentsOfDirectory(atPath: repo.path))?
            .sorted()
            .first { $0.lowercased() == "readme.md" }
    }

    /// Replaces only the text between the markers. Without both markers the README is left alone.
    func updateReadme(in repo: URL, folder: String) throws -> PublishPreview.ReadmeStatus {
        guard let name = readmeName(in: repo) else { return .noReadme }
        let url = repo.appendingPathComponent(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let start = text.range(of: Self.startMarker),
              let end = text.range(of: Self.endMarker, range: start.upperBound..<text.endIndex)
        else { return .noMarkers }
        let snippet = Self.readmeSnippet(folder: folder)
        let inner = snippet[snippet.range(of: Self.startMarker)!.upperBound..<snippet.range(of: Self.endMarker)!.lowerBound]
        let updated = text.replacingCharacters(in: start.upperBound..<end.lowerBound, with: inner)
        guard updated != text else { return .unchanged }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return .updated
    }

    // MARK: - Publish

    /// Commits and pushes a prepared change. `dryRun` returns without committing.
    public func publish(_ preview: PublishPreview, dryRun: Bool = false) throws -> PublishResult {
        guard preview.hasChanges else {
            return PublishResult(pushed: false, commit: nil, amended: false, note: "Nothing changed; no commit.")
        }
        guard !dryRun else {
            return PublishResult(pushed: false, commit: nil, amended: false, note: "Dry run: \(preview.changedPaths.count) file(s) would change.")
        }
        let repo = preview.checkout
        let target = preview.target
        let trailer = "\(Self.trailerKey): \(target.kind.rawValue)"
        let message = "Update coding agent usage\n\n\(trailer)"
        let identityFlags = identity.map { ["-c", "user.name=\($0.name)", "-c", "user.email=\($0.email)"] } ?? []
        let remoteHead = try Git.run(["rev-parse", "origin/\(target.branch)"], in: repo)
        let headMessage = try Git.run(["log", "-1", "--format=%B"], in: repo)
        let amend = target.strategy == .amendOwnCommit && headMessage.contains(trailer)

        try Git.run(identityFlags + ["commit", "--quiet"] + (amend ? ["--amend"] : []) + ["-m", message], in: repo)
        let commit = try Git.run(["rev-parse", "HEAD"], in: repo)
        if amend {
            try Git.run(["push", "--quiet", "--force-with-lease=refs/heads/\(target.branch):\(remoteHead)",
                         "origin", "HEAD:refs/heads/\(target.branch)"], in: repo)
        } else {
            try Git.run(["push", "--quiet", "origin", "HEAD:refs/heads/\(target.branch)"], in: repo)
        }
        return PublishResult(pushed: true, commit: commit, amended: amend,
                             note: amend ? "Replaced AgentDeck's previous commit (force-pushed with lease)." : "Pushed a new commit.")
    }
}

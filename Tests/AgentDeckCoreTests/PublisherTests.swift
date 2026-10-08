@testable import AgentDeckCore
import AgentDeckParsing
import Foundation
import Testing

@Suite struct PublisherTests {
    static let identity = Publisher.Identity(name: "Test", email: "test@example.com")

    /// A bare repository standing in for GitHub, seeded with `files` in one commit.
    struct Remote {
        let root: URL
        var url: URL { root.appendingPathComponent("remote.git") }

        init(files: [String: String]) throws {
            root = try temporaryDirectory()
            let seed = root.appendingPathComponent("seed")
            try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
            try Git.run(["init", "--quiet", "--initial-branch=main"], in: seed)
            for (path, text) in files {
                try text.write(to: seed.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            try Git.run(["add", "-A"], in: seed)
            try Git.run(["-c", "user.name=Owner", "-c", "user.email=owner@example.com", "commit", "--quiet", "-m", "Initial"], in: seed)
            try Git.run(["clone", "--quiet", "--bare", seed.path, url.path], in: root)
        }

        /// A commit the owner makes elsewhere, outside AgentDeck.
        func ownerCommit(_ path: String, _ text: String) throws {
            let work = root.appendingPathComponent("owner-\(UUID().uuidString)")
            try Git.run(["clone", "--quiet", url.path, work.path], in: root)
            try text.write(to: work.appendingPathComponent(path), atomically: true, encoding: .utf8)
            try Git.run(["add", "-A"], in: work)
            try Git.run(["-c", "user.name=Owner", "-c", "user.email=owner@example.com", "commit", "--quiet", "-m", "Owner edit"], in: work)
            try Git.run(["push", "--quiet", "origin", "main"], in: work)
        }

        func log() throws -> [String] {
            try Git.run(["log", "--format=%s", "main"], in: url).split(separator: "\n").map(String.init)
        }

        func file(_ path: String) throws -> String {
            try Git.run(["show", "main:\(path)"], in: url)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func export(tokens: Int) -> PublicExport {
        PublicExporter.build(
            records: [UsageRecord(source: .claudeCode, messageID: "m", sessionID: "s", timestamp: date("2026-10-07T10:00:00Z"),
                                  model: "claude-opus-5-5", tokens: TokenCounts(input: tokens))],
            options: PublicExportOptions(), now: date("2026-10-08T10:00:00Z"), calendar: LocalCalendar(timeZone: TimeZone(identifier: "UTC")!)
        )
    }

    private func publisher(_ remote: Remote) -> Publisher {
        Publisher(workspace: remote.root.appendingPathComponent("workspace"), identity: Self.identity)
    }

    @Test func pagesPublishWritesDataAndSkipsWhenNothingChanged() throws {
        let remote = try Remote(files: ["index.html": "<p>site</p>"])
        defer { remote.cleanUp() }
        let target = PublishTarget(kind: .pages, remote: remote.url.path, folder: "agentdeck", strategy: .newCommit)
        let publisher = publisher(remote)

        let preview = try publisher.prepare(target, export: export(tokens: 10))
        #expect(preview.changedPaths == ["agentdeck/data.json"])
        #expect(preview.diff.contains("\"total\" : 10"))
        let result = try publisher.publish(preview)
        #expect(result.pushed && !result.amended)
        #expect(try remote.file("agentdeck/data.json").contains("agentdeck.usage/v1"))
        #expect(try remote.file("index.html") == "<p>site</p>")

        let again = try publisher.prepare(target, export: export(tokens: 10))
        #expect(!again.hasChanges)
        #expect(try publisher.publish(again).pushed == false)
        #expect(try remote.log().count == 2)
    }

    @Test func dryRunPushesNothing() throws {
        let remote = try Remote(files: ["index.html": "x"])
        defer { remote.cleanUp() }
        let target = PublishTarget(kind: .pages, remote: remote.url.path, folder: "agentdeck", strategy: .newCommit)
        let result = try publisher(remote).publish(publisher(remote).prepare(target, export: export(tokens: 1)), dryRun: true)
        #expect(!result.pushed && result.note.contains("Dry run"))
        #expect(try remote.log() == ["Initial"])
    }

    @Test func amendKeepsOneAgentDeckCommitButNeverRewritesTheOwners() throws {
        let remote = try Remote(files: ["readme.md": "# Hi"])
        defer { remote.cleanUp() }
        let target = PublishTarget(kind: .profile, remote: remote.url.path, folder: "assets/agentdeck", strategy: .amendOwnCommit)
        let publisher = publisher(remote)

        #expect(try publisher.publish(publisher.prepare(target, export: export(tokens: 1))).amended == false)
        #expect(try publisher.publish(publisher.prepare(target, export: export(tokens: 2))).amended == true)
        #expect(try remote.log() == ["Update coding agent usage", "Initial"])
        #expect(try remote.file("assets/agentdeck/card-light.svg").contains(">2<"))

        try remote.ownerCommit("notes.txt", "mine")
        let afterOwner = try publisher.publish(publisher.prepare(target, export: export(tokens: 3)))
        #expect(afterOwner.amended == false)
        #expect(try remote.log() == ["Update coding agent usage", "Owner edit", "Update coding agent usage", "Initial"])
        #expect(try remote.file("notes.txt") == "mine")
    }

    @Test func newCommitStrategyOnlyAppends() throws {
        let remote = try Remote(files: ["readme.md": "# Hi"])
        defer { remote.cleanUp() }
        let target = PublishTarget(kind: .profile, remote: remote.url.path, folder: "assets/agentdeck", strategy: .newCommit)
        let publisher = publisher(remote)
        _ = try publisher.publish(publisher.prepare(target, export: export(tokens: 1)))
        let first = try Git.run(["rev-parse", "main"], in: remote.url)
        _ = try publisher.publish(publisher.prepare(target, export: export(tokens: 2)))
        #expect(try remote.log().count == 3)
        // The earlier commit is still an ancestor: history was not rewritten.
        #expect((try? Git.run(["merge-base", "--is-ancestor", first, "main"], in: remote.url)) != nil)
    }

    @Test func readmeChangesOnlyBetweenTheMarkers() throws {
        let before = "# Yilong\n\nIntro stays.\n\n\(Publisher.startMarker)\nold\n\(Publisher.endMarker)\n\nFooter stays.\n"
        let remote = try Remote(files: ["readme.md": before])
        defer { remote.cleanUp() }
        let target = PublishTarget(kind: .profile, remote: remote.url.path, folder: "assets/agentdeck",
                                   strategy: .newCommit, updateReadmeBlock: true)
        let preview = try publisher(remote).prepare(target, export: export(tokens: 1))
        #expect(preview.readme == .updated)
        #expect(preview.changedPaths.contains("readme.md"))
        _ = try publisher(remote).publish(preview)

        let after = try remote.file("readme.md")
        #expect(after.hasPrefix("# Yilong\n\nIntro stays.\n\n\(Publisher.startMarker)\n<picture>"))
        #expect(after.hasSuffix("</picture>\n\(Publisher.endMarker)\n\nFooter stays."))
        #expect(!after.contains("old"))
    }

    @Test func aReadmeWithoutMarkersIsLeftAlone() throws {
        let remote = try Remote(files: ["README.md": "# No markers here"])
        defer { remote.cleanUp() }
        let target = PublishTarget(kind: .profile, remote: remote.url.path, folder: "assets/agentdeck",
                                   strategy: .newCommit, updateReadmeBlock: true)
        let preview = try publisher(remote).prepare(target, export: export(tokens: 1))
        #expect(preview.readme == .noMarkers)
        #expect(!preview.changedPaths.contains("README.md"))
    }
}

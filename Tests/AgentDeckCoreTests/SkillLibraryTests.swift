@testable import AgentDeckCore
import Foundation
import Testing

@Suite struct SkillLibraryTests {
    /// A fake home with both tools' skill folders, the AgentDeck library and a backups folder.
    struct Sandbox {
        let root: URL
        let library: SkillLibrary
        let fm = FileManager.default

        init() throws {
            root = try temporaryDirectory()
            let locations = SkillLocations(
                canonical: root.appendingPathComponent("agentdeck/skills"),
                claudeUser: root.appendingPathComponent("claude/skills"),
                codexUser: root.appendingPathComponent("codex/skills"),
                agentsUser: root.appendingPathComponent("agents/skills"),
                claudePlugins: root.appendingPathComponent("claude/plugins"),
                codexPlugins: root.appendingPathComponent("codex/plugins"),
                claudeDesktopManaged: root.appendingPathComponent("desktop")
            )
            library = SkillLibrary(locations: locations, backupsRoot: root.appendingPathComponent("agentdeck/backups"))
        }

        func url(_ path: String) -> URL { root.appendingPathComponent(path) }

        func skill(_ path: String, name: String, body: String = "Body", extra: [String: String] = [:]) throws {
            let directory = url(path)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: Test skill.\n---\n\(body)\n".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            for (file, text) in extra { try text.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        }

        func scan() -> [DiscoveredSkill] { SkillScanner.scan(library.locations) }
        func cleanUp() { try? fm.removeItem(at: root) }
    }

    @Test func identicalCopiesImportOnceAndAreCommitted() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.skill("claude/skills/alpha", name: "alpha")
        try box.skill("codex/skills/alpha", name: "alpha")
        try box.skill("codex/skills/beta", name: "beta", extra: ["run.sh": "echo hi"])

        let (plan, conflicts) = box.library.importPlan(from: box.scan())
        #expect(conflicts.isEmpty)
        #expect(plan.steps.count == 2)
        #expect(plan.originalsToMove.isEmpty)

        let report = try box.library.apply(plan, allowMovingOriginals: false)
        #expect(report.imported == ["alpha", "beta"])
        #expect(report.backup == nil) // nothing was replaced
        #expect(box.fm.fileExists(atPath: box.url("agentdeck/skills/beta/run.sh").path))
        #expect(try Git.run(["log", "--format=%s"], in: box.url("agentdeck/skills")) == "Import alpha, beta")
        // The originals are untouched.
        #expect(box.fm.fileExists(atPath: box.url("claude/skills/alpha/SKILL.md").path))
        // Nothing left to import.
        #expect(box.library.importPlan(from: box.scan()).plan.isEmpty)
    }

    @Test func differingCopiesWaitForAChoice() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.skill("claude/skills/alpha", name: "alpha", body: "Claude wording")
        try box.skill("agents/skills/alpha", name: "alpha", body: "Codex wording")

        let first = box.library.importPlan(from: box.scan())
        #expect(first.plan.isEmpty)
        let conflict = try #require(first.conflicts.first)
        #expect(conflict.copies.count == 2)
        #expect(conflict.preview.contains("- Claude wording") || conflict.preview.contains("- Codex wording"))

        let chosen = box.url("agents/skills/alpha")
        let second = box.library.importPlan(from: box.scan(), choices: ["alpha": chosen])
        _ = try box.library.apply(second.plan, allowMovingOriginals: false)
        #expect(try String(contentsOf: box.url("agentdeck/skills/alpha/SKILL.md"), encoding: .utf8).contains("Codex wording"))
    }

    @Test func aSymlinkAndItsTargetCountAsOneCopy() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.skill("claude/skills/bundle/skills/lit", name: "lit")
        try box.fm.createSymbolicLink(atPath: box.url("claude/skills/lit").path, withDestinationPath: "bundle/skills/lit")

        let (plan, conflicts) = box.library.importPlan(from: box.scan())
        #expect(conflicts.isEmpty && plan.steps.count == 1)
        _ = try box.library.apply(plan, allowMovingOriginals: false)
        // Imported as a real folder, not a link.
        #expect((try? box.fm.destinationOfSymbolicLink(atPath: box.url("agentdeck/skills/lit").path)) == nil)
    }

    @Test func enablingOverAnOriginalFolderNeedsConfirmationAndKeepsABackup() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.skill("claude/skills/alpha", name: "alpha", extra: ["notes.md": "mine"])
        _ = try box.library.apply(box.library.importPlan(from: box.scan()).plan, allowMovingOriginals: false)

        let plan = box.library.togglePlan(name: "alpha", target: .claudeCode, enabled: true)
        #expect(plan.originalsToMove == [box.url("claude/skills/alpha")])
        #expect(throws: SkillLibrary.Failure.originalsNeedConfirmation([box.url("claude/skills/alpha")])) {
            try box.library.apply(plan, allowMovingOriginals: false)
        }
        #expect(box.fm.fileExists(atPath: box.url("claude/skills/alpha/notes.md").path)) // still untouched

        let report = try box.library.apply(plan, allowMovingOriginals: true)
        let backup = try #require(report.backup)
        let saved = backup.appendingPathComponent(String(box.url("claude/skills/alpha").standardizedFileURL.path.dropFirst()))
        #expect(try String(contentsOf: saved.appendingPathComponent("notes.md"), encoding: .utf8) == "mine")
        #expect(try String(contentsOf: backup.appendingPathComponent("RESTORE.txt"), encoding: .utf8).contains("restore: mv"))
        #expect(box.library.enabledTargets(for: "alpha") == [.claudeCode])
    }

    @Test func enablingAndDisablingOnlyTouchesAgentDeckLinks() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.skill("claude/skills/alpha", name: "alpha")
        try box.skill("agents/skills/alpha", name: "alpha")
        _ = try box.library.apply(box.library.importPlan(from: box.scan()).plan, allowMovingOriginals: false)

        let enable = box.library.togglePlan(name: "alpha", target: .codex, enabled: true, discovered: box.scan())
        #expect(enable.warnings.contains { $0.contains("list alpha twice") })
        _ = try box.library.apply(enable, allowMovingOriginals: false)
        #expect(box.library.enabledTargets(for: "alpha") == [.codex])
        #expect(box.library.togglePlan(name: "alpha", target: .codex, enabled: true).isEmpty)

        let disable = box.library.togglePlan(name: "alpha", target: .codex, enabled: false)
        let report = try box.library.apply(disable, allowMovingOriginals: false)
        #expect(report.unlinked == ["alpha"] && report.backup != nil)
        #expect(!box.fm.fileExists(atPath: box.url("codex/skills/alpha").path))
        #expect(box.fm.fileExists(atPath: box.url("agentdeck/skills/alpha/SKILL.md").path))
        // Disabling Claude Code, which links nothing, plans nothing: its real folder is never removed.
        #expect(box.library.togglePlan(name: "alpha", target: .claudeCode, enabled: false).isEmpty)
    }

    @Test func aPlanIsRefusedIfTheFolderChangedMeanwhile() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.skill("codex/skills/alpha", name: "alpha")
        _ = try box.library.apply(box.library.importPlan(from: box.scan()).plan, allowMovingOriginals: false)
        try box.fm.removeItem(at: box.url("codex/skills/alpha"))
        let plan = box.library.togglePlan(name: "alpha", target: .codex, enabled: true)
        try box.skill("codex/skills/alpha", name: "alpha") // reappears after planning
        do {
            _ = try box.library.apply(plan, allowMovingOriginals: true)
            Issue.record("the stale plan was applied")
        } catch let error as SkillLibrary.Failure {
            #expect(error.description.contains("changed after the plan was made"))
        }
        // The folder that reappeared is untouched.
        #expect((try? box.fm.destinationOfSymbolicLink(atPath: box.url("codex/skills/alpha").path)) == nil)
    }

    @Test func importsAFolderOfSkillsAndRecordsTheSource() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.skill("download/repo/skills/one", name: "one")
        try box.skill("download/repo/skills/two", name: "two")
        let plan = box.library.importFolderPlan(box.url("download/repo"), source: "https://example.com/repo.git")
        #expect(plan.steps.count == 2)
        _ = try box.library.apply(plan, allowMovingOriginals: false)
        let sources = try String(contentsOf: box.url("agentdeck/skills/.agentdeck-sources.json"), encoding: .utf8)
        #expect(sources.contains("https://example.com/repo.git"))
        #expect(box.library.importFolderPlan(box.url("download/repo"), source: "x").warnings.count == 2)
    }

    @Test func lineDiffShowsChangesWithContext() {
        #expect(LineDiff.unified(from: "a\nb\nc", to: "a\nb\nc").isEmpty)
        #expect(LineDiff.unified(from: "a\nb\nc\nd", to: "a\nB\nc\nd", context: 1) == "  a\n- b\n+ B\n  c")
    }
}

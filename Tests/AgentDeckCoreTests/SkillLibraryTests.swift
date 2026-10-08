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

    @Test func enablingANameABuiltInSkillAlsoHasWarns() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.skill("claude/skills/skill-creator", name: "skill-creator")
        try box.skill("codex/skills/.system/skill-creator", name: "skill-creator", body: "Bundled")
        let (importPlan, conflicts) = box.library.importPlan(from: box.scan())
        // The bundled copy is neither imported nor a conflict.
        #expect(conflicts.isEmpty && importPlan.steps.count == 1)
        _ = try box.library.apply(importPlan, allowMovingOriginals: false)

        let codex = box.library.togglePlan(name: "skill-creator", target: .codex, enabled: true, discovered: box.scan())
        #expect(codex.warnings.contains { $0.contains("Codex built-in") && $0.contains("list both") })
        // Claude Code does not load Codex's bundled skills, so nothing to warn about there.
        let claude = box.library.togglePlan(name: "skill-creator", target: .claudeCode, enabled: true, discovered: box.scan())
        #expect(claude.warnings.isEmpty)
    }

    @Test func remembersWhichPackASkillCameFrom() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.skill("claude/skills/co-pilot/skills/review", name: "review")
        try box.skill("claude/skills/solo", name: "solo")
        // A link at the top of the folder into a pack still belongs to the pack.
        try box.fm.createSymbolicLink(atPath: box.url("claude/skills/review-link").path, withDestinationPath: "co-pilot/skills/review")
        let found = box.scan().filter { $0.directory.lastPathComponent != "review" }
        _ = try box.library.apply(box.library.importPlan(from: found).plan, allowMovingOriginals: false)
        #expect(box.library.packs() == ["review": "co-pilot"])
    }

    @Test func claudeCodeGetsAMarkedCopyAndCodexALink() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.skill("agents/skills/alpha", name: "alpha")
        _ = try box.library.apply(box.library.importPlan(from: box.scan()).plan, allowMovingOriginals: false)
        for target in SkillTarget.allCases {
            _ = try box.library.apply(box.library.togglePlan(name: "alpha", target: target, enabled: true), allowMovingOriginals: false)
        }
        let claude = box.url("claude/skills/alpha")
        // A real folder (the Claude app skips symlinked skill folders), with AgentDeck's marker.
        #expect((try? box.fm.destinationOfSymbolicLink(atPath: claude.path)) == nil)
        #expect(box.fm.fileExists(atPath: claude.appendingPathComponent("SKILL.md").path))
        #expect(box.fm.fileExists(atPath: claude.appendingPathComponent(SkillLibrary.markerName).path))
        #expect((try? box.fm.destinationOfSymbolicLink(atPath: box.url("codex/skills/alpha").path)) != nil)
        #expect(box.library.enabledTargets(for: "alpha") == [.claudeCode, .codex])
        // The copy hashes like the library skill: the marker is not content.
        #expect(SkillScanner.contentHash(of: claude) == SkillScanner.contentHash(of: box.url("agentdeck/skills/alpha")))
        #expect(box.library.syncPlan().isEmpty)

        // Disabling moves the copy into the backup; nothing is deleted.
        let report = try box.library.apply(box.library.togglePlan(name: "alpha", target: .claudeCode, enabled: false), allowMovingOriginals: false)
        #expect(!box.fm.fileExists(atPath: claude.path))
        #expect(box.fm.fileExists(atPath: try #require(report.backup).appendingPathComponent(String(claude.path.dropFirst())).appendingPathComponent("SKILL.md").path))
    }

    @Test func syncTurnsOldLinksIntoCopiesAndFollowsLibraryEdits() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.skill("agents/skills/alpha", name: "alpha")
        try box.skill("agents/skills/beta", name: "beta")
        _ = try box.library.apply(box.library.importPlan(from: box.scan()).plan, allowMovingOriginals: false)
        // How earlier versions enabled Claude Code: a link into the library.
        try box.fm.createDirectory(at: box.url("claude/skills"), withIntermediateDirectories: true)
        try box.fm.createSymbolicLink(at: box.url("claude/skills/alpha"), withDestinationURL: box.url("agentdeck/skills/alpha"))
        try box.fm.createSymbolicLink(at: box.url("claude/skills/beta"), withDestinationURL: box.url("agentdeck/skills/beta"))
        #expect(box.library.enabledTargets(for: "alpha") == [.claudeCode])

        _ = try box.library.apply(box.library.syncPlan(), allowMovingOriginals: false)
        #expect((try? box.fm.destinationOfSymbolicLink(atPath: box.url("claude/skills/alpha").path)) == nil)
        #expect(box.library.enabledTargets(for: "alpha") == [.claudeCode])
        #expect(box.library.syncPlan().isEmpty)

        // The library changes: the untouched copy is refreshed, the copy edited in place is not.
        try "---\nname: alpha\ndescription: Test skill.\n---\nNew body\n".write(to: box.url("agentdeck/skills/alpha/SKILL.md"), atomically: true, encoding: .utf8)
        try "---\nname: beta\ndescription: Test skill.\n---\nNew body\n".write(to: box.url("agentdeck/skills/beta/SKILL.md"), atomically: true, encoding: .utf8)
        try "Edited here".write(to: box.url("claude/skills/beta/notes.md"), atomically: true, encoding: .utf8)
        let sync = box.library.syncPlan()
        #expect(sync.steps.count == 1)
        #expect(sync.warnings.contains { $0.contains("claude/skills/beta") && $0.contains("edited") })
        _ = try box.library.apply(sync, allowMovingOriginals: false)
        #expect(try String(contentsOf: box.url("claude/skills/alpha/SKILL.md"), encoding: .utf8).contains("New body"))
        #expect(box.fm.fileExists(atPath: box.url("claude/skills/beta/notes.md").path))
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

/// Opt-in: runs the library against copies of this Mac's real skill folders, never the folders
/// themselves. `AGENTDECK_REAL_SKILLS=1 swift test --filter RealSkillsSmokeTest`
@Suite struct RealSkillsSmokeTest {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTDECK_REAL_SKILLS"] == "1"))
    func importAndLinkOnACopyOfTheRealFolders() throws {
        let box = try SkillLibraryTests.Sandbox()
        defer { box.cleanUp() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for (real, copy) in [(".claude/skills", "claude/skills"), (".codex/skills", "codex/skills"), (".agents/skills", "agents/skills")] {
            try box.fm.createDirectory(at: box.url(copy).deletingLastPathComponent(), withIntermediateDirectories: true)
            try box.fm.copyItem(at: home.appendingPathComponent(real), to: box.url(copy))
        }

        let first = box.library.importPlan(from: box.scan())
        print("plan without choices: \(first.plan.steps.count) imports, \(first.conflicts.count) conflicts")
        // Prefer the Claude Code copy in every conflict.
        let choices = Dictionary(uniqueKeysWithValues: first.conflicts.map { conflict in
            (conflict.name, (conflict.copies.first { $0.origin == .claudeUser } ?? conflict.copies[0]).directory)
        })
        let resolved = box.library.importPlan(from: box.scan(), choices: choices)
        #expect(resolved.conflicts.isEmpty)
        let report = try box.library.apply(resolved.plan, allowMovingOriginals: false)
        print("imported \(report.imported.count): \(report.imported.joined(separator: ", "))")
        #expect(report.imported.count == first.plan.steps.count + first.conflicts.count)

        // Enable a skill whose original is a real folder in ~/.claude/skills.
        let name = "paper-poster"
        let plan = box.library.togglePlan(name: name, target: .claudeCode, enabled: true, discovered: box.scan())
        print("toggle plan: \(plan.summary.joined(separator: " | ")); warnings: \(plan.warnings)")
        let linked = try box.library.apply(plan, allowMovingOriginals: true)
        #expect(box.library.enabledTargets(for: name) == [.claudeCode])
        print("backup: \(linked.backup?.lastPathComponent ?? "none")")
        // Claude Code still sees exactly one paper-poster, now through the link.
        let claudeLoaded = SkillScanner.scan(box.library.locations).filter { $0.name == name && $0.loadedBy.contains(.claudeCode) }
        #expect(claudeLoaded.count == 1)
    }
}

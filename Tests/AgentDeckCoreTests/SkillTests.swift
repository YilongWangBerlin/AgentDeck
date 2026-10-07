@testable import AgentDeckCore
import Foundation
import Testing

@Suite struct SkillManifestTests {
    @Test func readsScalarsQuotesAndBlockScalars() throws {
        let manifest = try SkillManifest.parse("""
            ---
            name: "paper-poster"
            description: >
              Builds a poster
              from a paper.
            allowed-tools: Read, Write
            metadata:
              short-description: x
            ---
            # Body
            """)
        #expect(manifest.keys == ["name", "description", "allowed-tools", "metadata"])
        #expect(manifest.name == "paper-poster")
        #expect(manifest.description == "Builds a poster from a paper.")
        #expect(manifest.values["metadata"]?.contains("short-description") == true)

        let literal = try SkillManifest.parse("---\nname: 'it''s'\ndescription: |\n  line one\n  line two\n---\n")
        #expect(literal.name == "it's")
        #expect(literal.description == "line one\nline two")
    }

    @Test func missingOrUnterminatedFrontmatterThrows() {
        #expect(throws: SkillManifest.ParseError.noFrontmatter) { try SkillManifest.parse("# Just a heading") }
        #expect(throws: SkillManifest.ParseError.unterminatedFrontmatter) { try SkillManifest.parse("---\nname: x\n") }
    }
}

@Suite struct SkillValidatorTests {
    private func issues(_ frontmatter: String, folder: String = "demo") throws -> [SkillIssue] {
        SkillValidator.issues(manifest: try SkillManifest.parse("---\n\(frontmatter)\n---\n"), parseError: nil, directoryName: folder)
    }

    @Test func aCleanSkillHasNoIssues() throws {
        #expect(try issues("name: demo\ndescription: Does one thing.").isEmpty)
    }

    @Test func missingFieldsAreErrorsForBothTools() throws {
        let found = try issues("name: demo")
        #expect(found.map(\.severity) == [.error])
        #expect(found.first?.targets == [.claudeCode, .codex])
        let none = SkillValidator.issues(manifest: nil, parseError: SkillManifest.ParseError.noFrontmatter, directoryName: "x")
        #expect(none.map(\.severity) == [.error])
    }

    @Test func codexRulesAreWarnings() throws {
        let found = try issues("name: Spreadsheets\ndescription: Use <tables>.\nargument-hint: x\ncustom: y", folder: "spreadsheets")
        #expect(found.allSatisfy { $0.severity < .error })
        #expect(found.contains { $0.message.contains("differs from its folder") })
        #expect(found.contains { $0.targets == [.codex] && $0.message.contains("hyphen-case") })
        #expect(found.contains { $0.message.contains("< or >") })
        #expect(found.contains { $0.severity == .info && $0.message.contains("argument-hint") })
        #expect(found.contains { $0.severity == .warning && $0.message.contains("custom") })
        #expect(try issues("name: demo\ndescription: \(String(repeating: "a", count: 1025))").contains { $0.message.contains("1024") })
    }
}

@Suite struct SkillScannerTests {
    @Test func findsSkillsWhereEachToolLoadsThem() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func skill(_ path: String, name: String, body: String = "Body") throws {
            let directory = root.appendingPathComponent(path)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: Test skill.\n---\n\(body)\n".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try skill("claude/skills/alpha", name: "alpha")
        try skill("claude/skills/bundle/nested", name: "nested")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("claude/skills/nested").path, withDestinationPath: "bundle/nested")
        try skill("claude/skills/.git/ignored", name: "ignored")
        try skill("codex/skills/alpha", name: "alpha")
        try skill("codex/skills/.system/imagegen", name: "imagegen")
        try skill("agents/skills/alpha", name: "alpha", body: "Edited for Codex")
        try skill("codex-plugins/openai/figma/1.0/skills/figma-use", name: "figma-use")

        let locations = SkillLocations(
            canonical: root.appendingPathComponent("agentdeck/skills"),
            claudeUser: root.appendingPathComponent("claude/skills"),
            codexUser: root.appendingPathComponent("codex/skills"),
            agentsUser: root.appendingPathComponent("agents/skills"),
            claudePlugins: root.appendingPathComponent("claude/plugins"),
            codexPlugins: root.appendingPathComponent("codex-plugins"),
            claudeDesktopManaged: root.appendingPathComponent("desktop")
        )
        let skills = SkillScanner.scan(locations)

        #expect(skills.map(\.name).sorted() == ["alpha", "alpha", "alpha", "figma-use", "imagegen", "nested", "nested"])
        let nested = skills.filter { $0.name == "nested" }
        #expect(nested.first { $0.symlinkDestination != nil }?.loadedBy == [.claudeCode])
        #expect(nested.first { $0.symlinkDestination == nil }?.loadedBy == [])
        #expect(skills.first { $0.name == "imagegen" }?.origin == .codexBundled)
        #expect(skills.first { $0.name == "figma-use" }?.origin.isReadOnly == true)

        let alphas = try #require(SkillScanner.duplicates(skills)["alpha"])
        let byOrigin = Dictionary(uniqueKeysWithValues: alphas.map { ($0.origin, $0.contentHash) })
        #expect(byOrigin[.claudeUser] == byOrigin[.codexUser])
        #expect(byOrigin[.claudeUser] != byOrigin[.agentsUser])
    }

    @Test func contentHashIgnoresFinderMetadata() throws {
        let a = try temporaryDirectory(), b = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        for directory in [a, b] { try "same".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8) }
        try "junk".write(to: b.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        #expect(SkillScanner.contentHash(of: a) == SkillScanner.contentHash(of: b))
        try "extra".write(to: b.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        #expect(SkillScanner.contentHash(of: a) != SkillScanner.contentHash(of: b))
    }
}

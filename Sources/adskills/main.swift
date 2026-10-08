import AgentDeckCore
import AgentDeckParsing
import Foundation

// Manages skills from the command line with the same library code as the app's Skills tab. Every
// command prints its plan; nothing changes without --apply, and originals are only ever moved into
// ~/.agentdeck/backups.
//
//   adskills list
//   adskills import NAME... [--prefer claude|codex|agents] [--apply]
//   adskills enable NAME... --tool claude|codex [--move-originals] [--apply]
//   adskills retire PATH... [--apply]      move folders out of the tools' skill folders, into the backup

let arguments = Array(CommandLine.arguments.dropFirst())
let apply = arguments.contains("--apply")
let moveOriginals = arguments.contains("--move-originals")
func value(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}
/// Positional arguments after the command, without flags and their values.
let operands: [String] = {
    var result: [String] = []
    var skip = false
    for argument in arguments.dropFirst() {
        if skip { skip = false; continue }
        if ["--prefer", "--tool"].contains(argument) { skip = true; continue }
        if !argument.hasPrefix("--") { result.append(argument) }
    }
    return result
}()

let locations = SkillLocations.standard(logs: LogLocations.standard())
let library = SkillLibrary(locations: locations, backupsRoot: AgentDeckPaths.home.appendingPathComponent("backups"))

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func show(_ plan: SkillPlan) {
    plan.summary.forEach { print("  " + $0) }
    plan.warnings.forEach { print("  ! " + $0) }
    if plan.isEmpty { print("  (nothing to do)") }
}

func run(_ plan: SkillPlan) {
    show(plan)
    guard apply, !plan.isEmpty else {
        if !plan.isEmpty { print("Dry run. Add --apply to do this.") }
        return
    }
    do {
        let report = try library.apply(plan, allowMovingOriginals: moveOriginals)
        if let backup = report.backup { print("Backup: \(SkillPlan.tilde(backup))") }
        print("Done.")
    } catch {
        fail("\(error)")
    }
}

switch arguments.first {
case "list":
    let skills = SkillScanner.scan(locations)
    for (name, copies) in Dictionary(grouping: skills, by: \.name).sorted(by: { $0.key < $1.key }) {
        let tools = copies.reduce(into: Set<SkillTarget>()) { $0.formUnion($1.loadedBy) }.map(\.rawValue).sorted()
        let differing = Set(copies.map(\.contentHash)).count > 1
        print("\(name)  [\(tools.isEmpty ? "not loaded" : tools.joined(separator: ", "))]\(differing ? "  differing copies" : "")")
        for copy in copies { print("    \(copy.origin.rawValue): \(SkillPlan.tilde(copy.directory))") }
    }

case "import":
    guard !operands.isEmpty else { fail("Name the skills to import.") }
    let preferred: DiscoveredSkill.Origin = switch value(after: "--prefer") {
    case "codex": .codexUser
    case "agents": .agentsUser
    default: .claudeUser
    }
    let wanted = Set(operands)
    let discovered = SkillScanner.scan(locations).filter { wanted.contains($0.name) }
    for name in wanted.subtracting(discovered.map(\.name)).sorted() { print("  ! \(name) was not found.") }
    // Differing copies: take the preferred folder's, else the first one found.
    var choices: [String: URL] = [:]
    for (name, copies) in Dictionary(grouping: discovered, by: \.name) where Set(copies.map(\.contentHash)).count > 1 {
        choices[name] = (copies.first { $0.origin == preferred } ?? copies[0]).directory
    }
    let (plan, conflicts) = library.importPlan(from: discovered, choices: choices)
    for conflict in conflicts { print("  ! \(conflict.name) has differing copies and none was chosen.") }
    run(plan)

case "enable":
    guard !operands.isEmpty else { fail("Name the skills to enable.") }
    let target: SkillTarget = switch value(after: "--tool") {
    case "claude": .claudeCode
    case "codex": .codex
    default: fail("--tool claude|codex is required.")
    }
    let discovered = SkillScanner.scan(locations)
    var plan = SkillPlan()
    for name in operands {
        let part = library.togglePlan(name: name, target: target, enabled: true, discovered: discovered)
        plan.steps += part.steps
        plan.warnings += part.warnings
    }
    if !plan.originalsToMove.isEmpty, !moveOriginals {
        print("  ! This replaces original folders. Add --move-originals to move them into the backup.")
    }
    run(plan)

case "retire":
    guard !operands.isEmpty else { fail("Name the folders to move into the backup.") }
    let roots = [locations.claudeUser, locations.codexUser, locations.agentsUser].map { $0.standardizedFileURL.path + "/" }
    let paths = operands.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
    for path in paths {
        guard roots.contains(where: { path.path.hasPrefix($0) }) else {
            fail("\(SkillPlan.tilde(path)) is not inside ~/.claude/skills, ~/.codex/skills or ~/.agents/skills.")
        }
        guard FileManager.default.fileExists(atPath: path.path) else { fail("\(SkillPlan.tilde(path)) does not exist.") }
        print("  Move \(SkillPlan.tilde(path)) into the backup")
    }
    guard apply else { print("Dry run. Add --apply to do this."); exit(0) }
    do {
        let session = try BackupSession(root: AgentDeckPaths.home.appendingPathComponent("backups"))
        for path in paths { try session.move(path) }
        print("Backup: \(SkillPlan.tilde(session.directory))")
    } catch {
        fail("\(error)")
    }

default:
    print("""
        usage: adskills list
               adskills import NAME... [--prefer claude|codex|agents] [--apply]
               adskills enable NAME... --tool claude|codex [--move-originals] [--apply]
               adskills retire PATH... [--apply]
        """)
}

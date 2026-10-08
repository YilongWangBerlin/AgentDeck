import AgentDeckCore
import AppKit
import SwiftUI

/// True while `--render-…` draws a view offscreen, where scroll views render empty.
struct RenderingSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isRenderingSnapshot: Bool {
        get { self[RenderingSnapshotKey.self] }
        set { self[RenderingSnapshotKey.self] = newValue }
    }
}

@MainActor @Observable
final class SkillsModel {
    struct Group: Identifiable {
        var name: String
        var copies: [DiscoveredSkill]
        var id: String { name }

        /// Copies with different content: the user has to pick one when importing.
        var isConflict: Bool { Set(copies.map(\.contentHash)).count > 1 }
        var loadedBy: Set<SkillTarget> { copies.reduce(into: []) { $0.formUnion($1.loadedBy) } }
        var worstIssue: SkillIssue.Severity? { copies.flatMap(\.issues).map(\.severity).max() }
        var isReadOnly: Bool { copies.allSatisfy(\.origin.isReadOnly) }
    }

    /// A plan waiting for the user's confirmation.
    struct PendingPlan: Identifiable {
        let id = UUID()
        var title: String
        var plan: SkillPlan
        /// A temporary git clone the plan copies from, removed once the plan is applied or cancelled.
        var checkout: URL?
    }

    private(set) var discovered: [DiscoveredSkill] = []
    /// Skills in the folders AgentDeck manages (`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`).
    private(set) var groups: [Group] = []
    /// Built-in, plugin and app-managed skills. Listed for reference; AgentDeck never touches them.
    private(set) var builtIns: [Group] = []
    /// Names a built-in or plugin skill already uses, with the tools that load it.
    private(set) var builtInNames: [String: Set<SkillTarget>] = [:]
    private(set) var librarySkills: [DiscoveredSkill] = []
    private(set) var enabled: [String: Set<SkillTarget>] = [:]
    private(set) var isBusy = false
    var showBuiltIns = false
    var showingSourceSheet = false
    var pending: PendingPlan?
    var conflicts: [ImportConflict] = []
    var choices: [String: URL] = [:]
    var message: String?

    func library(for locations: SkillLocations) -> SkillLibrary {
        SkillLibrary(locations: locations, backupsRoot: AgentDeckPaths.home.appendingPathComponent("backups"))
    }

    func scan(locations: SkillLocations) async {
        isBusy = true
        let library = library(for: locations)
        let (skills, inLibrary, links) = await Task.detached(priority: .utility) {
            let inLibrary = library.skills()
            let links = Dictionary(uniqueKeysWithValues: inLibrary.map { ($0.name, library.enabledTargets(for: $0.name)) })
            return (SkillScanner.scan(locations), inLibrary, links)
        }.value
        discovered = skills
        librarySkills = inLibrary.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        enabled = links
        func grouped(_ copies: [DiscoveredSkill]) -> [Group] {
            Dictionary(grouping: copies, by: \.name)
                .map { Group(name: $0.key, copies: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let readOnly = skills.filter(\.origin.isReadOnly)
        groups = grouped(skills.filter { $0.origin != .canonical && !$0.origin.isReadOnly })
        builtIns = grouped(readOnly)
        builtInNames = readOnly.reduce(into: [:]) { $0[$1.name, default: []].formUnion($1.loadedBy) }
        isBusy = false
    }

    /// The tools that would list `name` twice: a built-in or plugin skill of that name is loaded there.
    func clashes(_ name: String, loadedBy targets: Set<SkillTarget>) -> Set<SkillTarget> {
        (builtInNames[name] ?? []).intersection(targets)
    }

    // MARK: Planning

    func planImport(locations: SkillLocations, skippingUnresolved: Bool = false) {
        let (plan, found) = library(for: locations).importPlan(from: discovered, choices: choices)
        if !found.isEmpty, !skippingUnresolved {
            conflicts = found
            return
        }
        conflicts = []
        guard !plan.isEmpty else {
            message = "Everything is already in the library."
            return
        }
        pending = PendingPlan(title: "Import \(plan.steps.count) skill(s) into the library", plan: plan)
    }

    func planToggle(_ name: String, _ target: SkillTarget, enabled on: Bool, locations: SkillLocations) {
        let plan = library(for: locations).togglePlan(name: name, target: target, enabled: on, discovered: discovered)
        guard !plan.isEmpty else { return }
        pending = PendingPlan(title: "\(on ? "Enable" : "Disable") \(name) for \(target.rawValue)", plan: plan)
    }

    func planFolderImport(_ folder: URL, source: String, locations: SkillLocations, checkout: URL? = nil) {
        let plan = library(for: locations).importFolderPlan(folder, source: source)
        if plan.isEmpty {
            message = plan.warnings.joined(separator: " ")
            Self.remove(checkout)
        } else {
            pending = PendingPlan(title: "Import from \(source)", plan: plan, checkout: checkout)
        }
    }

    func cancelPending() {
        Self.remove(pending?.checkout)
        pending = nil
    }

    private static func remove(_ checkout: URL?) {
        if let checkout { try? FileManager.default.removeItem(at: checkout) }
    }

    /// Shallow-clones `url` into a temporary folder, then plans an import from it.
    func planGitImport(_ url: String, locations: SkillLocations) async {
        isBusy = true
        defer { isBusy = false }
        let checkout = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-import-\(UUID().uuidString)")
        do {
            try await Task.detached {
                _ = try Git.run(["clone", "--depth", "1", "--quiet", url, checkout.path], in: FileManager.default.temporaryDirectory)
            }.value
            planFolderImport(checkout, source: url, locations: locations, checkout: checkout)
        } catch {
            Self.remove(checkout)
            message = "Could not clone \(url): \(error)"
        }
    }

    // MARK: Applying

    func apply(_ pending: PendingPlan, allowMovingOriginals: Bool, locations: SkillLocations) async {
        let library = library(for: locations)
        isBusy = true
        do {
            let report = try await Task.detached { try library.apply(pending.plan, allowMovingOriginals: allowMovingOriginals) }.value
            var parts: [String] = []
            if !report.imported.isEmpty { parts.append("Imported \(report.imported.count)") }
            if !report.linked.isEmpty { parts.append("enabled \(report.linked.joined(separator: ", "))") }
            if !report.unlinked.isEmpty { parts.append("disabled \(report.unlinked.joined(separator: ", "))") }
            if let backup = report.backup { parts.append("backup in \(SkillPlan.tilde(backup))") }
            message = parts.joined(separator: "; ") + "."
        } catch {
            message = "\(error)"
        }
        isBusy = false
        Self.remove(pending.checkout)
        self.pending = nil
        await scan(locations: locations)
    }
}

struct SkillsView: View {
    @Bindable var model: SkillsModel
    let locations: SkillLocations
    @Environment(\.isRenderingSnapshot) private var isRenderingSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Import from tools…") { model.planImport(locations: locations) }
                    .help("Copy the skills in ~/.claude/skills, ~/.codex/skills and ~/.agents/skills into the library. Originals stay where they are.")
                Button("Add from git or folder…") { model.showingSourceSheet = true }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Rescan") { Task { await model.scan(locations: locations) } }.disabled(model.isBusy)
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            // Confirmations replace the list inside the dropdown: sheets and extra windows are
            // unreliable in a menu bar panel, which closes when it loses focus.
            if let pending = model.pending {
                PlanSheet(pending: pending, cancel: { model.cancelPending() }) { allowMove in
                    Task { await model.apply(pending, allowMovingOriginals: allowMove, locations: locations) }
                }
            } else if !model.conflicts.isEmpty {
                ConflictSheet(model: model, cancel: { model.conflicts = [] }) {
                    model.planImport(locations: locations, skippingUnresolved: true)
                }
            } else if model.showingSourceSheet {
                SourceSheet(cancel: { model.showingSourceSheet = false }) { source in
                    model.showingSourceSheet = false
                    switch source {
                    case .git(let url): Task { await model.planGitImport(url, locations: locations) }
                    case .folder(let folder): model.planFolderImport(folder, source: folder.path, locations: locations)
                    }
                }
            } else if isRenderingSnapshot {
                content
            } else {
                ScrollView { content }
            }
        }
        .task { if model.groups.isEmpty { await model.scan(locations: locations) } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AgentDeck library (\(model.librarySkills.count))").font(.headline)
                if model.librarySkills.isEmpty {
                    Text("Empty. Import skills to manage them here and switch them on per tool.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.librarySkills, id: \.name) { skill in
                    let enabled = model.enabled[skill.name] ?? []
                    LibraryRow(skill: skill, enabled: enabled, clashes: model.clashes(skill.name, loadedBy: enabled)) { target, on in
                        model.planToggle(skill.name, target, enabled: on, locations: locations)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                let conflicts = model.groups.filter(\.isConflict).count
                Text("Your skill folders (\(model.groups.count), \(conflicts) with differing copies)").font(.headline)
                    .help("~/.claude/skills, ~/.codex/skills and ~/.agents/skills: the skills AgentDeck can import and manage.")
                ForEach(model.groups) { group in
                    SkillGroupRow(group: group, clashes: model.clashes(group.name, loadedBy: group.loadedBy))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.showBuiltIns.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.showBuiltIns ? "chevron.down" : "chevron.right").frame(width: 12)
                        Text("Built-in and plugin skills (\(model.builtIns.count))").font(.headline)
                        Text("Left as they are").font(.callout).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Skills that ship with Codex, Claude Code plugins or the Claude app. Each tool keeps managing its own; AgentDeck only lists them.")
                if model.showBuiltIns {
                    ForEach(model.builtIns) { group in
                        SkillGroupRow(group: group, clashes: [])
                    }
                }
            }
        }
    }
}

// MARK: - Rows

private struct LibraryRow: View {
    let skill: DiscoveredSkill
    let enabled: Set<SkillTarget>
    let clashes: Set<SkillTarget>
    let toggle: (SkillTarget, Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(skill.name).fontWeight(.medium)
            ClashBadge(name: skill.name, targets: clashes)
            if let worst = skill.issues.map(\.severity).max(), worst > .info {
                SeverityIcon(severity: worst).help(skill.issues.map(\.message).joined(separator: "\n"))
            }
            Spacer()
            ForEach(SkillTarget.allCases, id: \.self) { target in
                Toggle(target == .claudeCode ? "Claude Code" : "Codex", isOn: Binding(
                    get: { enabled.contains(target) },
                    set: { toggle(target, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.tile.opacity(0.6)))
    }
}

private struct SkillGroupRow: View {
    let group: SkillsModel.Group
    let clashes: Set<SkillTarget>
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
            if expanded {
                ForEach(Array(group.copies.enumerated()), id: \.offset) { _, copy in
                    CopyDetail(copy: copy).padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.tile.opacity(0.6)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.secondary).frame(width: 12)
            Text(group.name).fontWeight(.medium)
            if group.isConflict { Badge(text: "\(group.copies.count) differing copies", color: Palette.warning) }
            else if group.copies.count > 1 { Badge(text: "\(group.copies.count) identical copies", color: .secondary) }
            if group.isReadOnly, let origin = group.copies.first?.origin { Badge(text: origin.rawValue, color: .secondary) }
            ClashBadge(name: group.name, targets: clashes)
            Spacer()
            ForEach(SkillTarget.allCases, id: \.self) { target in
                Text(target == .claudeCode ? "CC" : "CX")
                    .font(.caption.monospaced())
                    .foregroundStyle(group.loadedBy.contains(target) ? .primary : .tertiary)
                    .help(group.loadedBy.contains(target) ? "\(target.rawValue) loads it" : "\(target.rawValue) does not load it")
            }
            if let worst = group.worstIssue {
                SeverityIcon(severity: worst)
            }
        }
    }
}

private struct CopyDetail: View {
    let copy: DiscoveredSkill

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(copy.origin.rawValue).font(.caption.weight(.semibold))
                Text(String(copy.contentHash.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(location).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(Array(copy.issues.enumerated()), id: \.offset) { _, issue in
                Text(Self.line(for: issue)).font(.caption).foregroundStyle(SeverityIcon.color(issue.severity))
            }
        }
    }

    private var location: String {
        let path = SkillPlan.tilde(copy.directory)
        guard let destination = copy.symlinkDestination else { return path }
        return path + " → " + SkillPlan.tilde(destination)
    }

    static func line(for issue: SkillIssue) -> String {
        let targets = issue.targets.map(\.rawValue).sorted().joined(separator: ", ")
        return "\(targets): \(issue.message)"
    }
}

private struct SeverityIcon: View {
    let severity: SkillIssue.Severity

    static func color(_ severity: SkillIssue.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: Palette.warning
        case .info: .secondary
        }
    }

    var body: some View {
        let name = switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
        Image(systemName: name).foregroundStyle(Self.color(severity))
    }
}

/// A built-in or plugin skill with the same name is loaded by `targets`, so those tools list both.
private struct ClashBadge: View {
    let name: String
    let targets: Set<SkillTarget>

    var body: some View {
        if !targets.isEmpty {
            Badge(text: "same name as a built-in", color: .purple)
                .help("\(targets.map(\.rawValue).sorted().joined(separator: " and ")) also has a built-in or plugin skill named \(name) and will list both.")
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().strokeBorder(color.opacity(0.5)))
    }
}

// MARK: - Sheets

/// Shows exactly what a plan will do. Moving original folders needs its own checkbox.
private struct PlanSheet: View {
    let pending: SkillsModel.PendingPlan
    let cancel: () -> Void
    let apply: (Bool) -> Void
    @State private var allowMove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(pending.plan.summary.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "arrow.right.circle").font(.callout)
                    }
                    ForEach(pending.plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Palette.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            Text("Anything replaced is first saved to ~/.agentdeck/backups with instructions to restore it.")
                .font(.caption).foregroundStyle(.secondary)
            if !pending.plan.originalsToMove.isEmpty {
                Toggle("Move \(pending.plan.originalsToMove.count) original folder(s) into the backup. Nothing is deleted.", isOn: $allowMove)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply") { apply(allowMove) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!pending.plan.originalsToMove.isEmpty && !allowMove)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.tile.opacity(0.5)))
    }
}

/// One choice per skill whose copies differ, with a SKILL.md diff to decide by.
private struct ConflictSheet: View {
    @Bindable var model: SkillsModel
    let cancel: () -> Void
    let proceed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.conflicts.count) skill(s) have differing copies").font(.headline)
            Text("Pick the copy to import for each, or skip it. Nothing changes until you confirm the next step.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.conflicts, id: \.name) { conflict in
                        ConflictRow(conflict: conflict, choice: Binding(
                            get: { model.choices[conflict.name] },
                            set: { model.choices[conflict.name] = $0 }
                        ))
                    }
                }
            }
            .frame(maxHeight: 330)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Continue") { proceed() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ConflictRow: View {
    let conflict: ImportConflict
    @Binding var choice: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(conflict.name, selection: $choice) {
                Text("Skip").tag(URL?.none)
                ForEach(conflict.copies, id: \.directory) { copy in
                    Text(Self.label(copy)).tag(Optional(copy.directory))
                }
            }
            .pickerStyle(.radioGroup)
            DisclosureGroup("Differences") {
                Text(conflict.preview)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.tile.opacity(0.5)))
    }

    static func label(_ copy: DiscoveredSkill) -> String {
        "\(copy.origin.rawValue): \(SkillPlan.tilde(copy.directory))"
    }
}

private struct SourceSheet: View {
    enum Source { case git(String), folder(URL) }

    let cancel: () -> Void
    let choose: (Source) -> Void
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add skills from elsewhere").font(.headline)
            Text("A git repository is cloned (shallow) into a temporary folder; a local folder is only read. Either way you see the plan before anything is copied.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("https://github.com/owner/skills.git", text: $url)
            HStack {
                Button("Choose a folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if MenuBarPanel.runModal(panel) == .OK, let folder = panel.url { choose(.folder(folder)) }
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Clone") { choose(.git(url.trimmingCharacters(in: .whitespaces))) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.tile.opacity(0.5)))
    }
}

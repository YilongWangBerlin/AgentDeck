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
    /// Skills in the tools' own folders (`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`)
    /// that are not in the library yet. Links into the library are the library's, not listed here.
    private(set) var groups: [Group] = []
    /// Built-in, plugin and app-managed skills. Listed for reference; AgentDeck never touches them.
    private(set) var builtIns: [Group] = []
    /// Names a built-in or plugin skill already uses, with the tools that load it.
    private(set) var builtInNames: [String: Set<SkillTarget>] = [:]
    private(set) var librarySkills: [DiscoveredSkill] = []
    private(set) var enabled: [String: Set<SkillTarget>] = [:]
    /// Library skills grouped by the pack they were imported from (research-co-pilot, …).
    private(set) var libraryEntries: [LibraryEntry] = []
    /// Where a tool already gets a library skill without AgentDeck's link: a plugin folder, the
    /// Claude app or a Codex plugin. Shown instead of the switch.
    private(set) var providers: [String: [SkillTarget: String]] = [:]

    enum LibraryEntry: Identifiable {
        case skill(DiscoveredSkill)
        case pack(name: String, skills: [DiscoveredSkill])

        var id: String {
            switch self {
            case .skill(let skill): skill.name
            case .pack(let name, _): "pack:" + name
            }
        }
        var sortKey: String {
            switch self {
            case .skill(let skill): skill.name
            case .pack(let name, _): name
            }
        }
    }
    private(set) var isBusy = false
    /// Claude Code copies that are links from an older version or behind the library.
    private(set) var syncNeeded = SkillPlan()
    var showBuiltIns = false
    var showingSourceSheet = false
    var pending: PendingPlan?
    var conflicts: [ImportConflict] = []
    var choices: [String: URL] = [:]
    var message: String?

    func library(for locations: SkillLocations) -> SkillLibrary {
        SkillLibrary(locations: locations, backupsRoot: AgentDeckPaths.home.appendingPathComponent("backups"))
    }

    @ObservationIgnored private var lastLocations: SkillLocations?

    func scan(locations: SkillLocations) async {
        isBusy = true
        lastLocations = locations
        let library = library(for: locations)
        let (skills, inLibrary, links, packs, sync) = await Task.detached(priority: .utility) {
            let inLibrary = library.skills()
            let links = Dictionary(uniqueKeysWithValues: inLibrary.map { ($0.name, library.enabledTargets(for: $0.name)) })
            return (SkillScanner.scan(locations), inLibrary, links, library.packs(), library.syncPlan())
        }.value
        syncNeeded = sync
        discovered = skills
        librarySkills = inLibrary.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        enabled = links
        func grouped(_ copies: [DiscoveredSkill]) -> [Group] {
            Dictionary(grouping: copies, by: \.name)
                .map { Group(name: $0.key, copies: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let readOnly = skills.filter(\.origin.isReadOnly)
        let libraryPath = locations.canonical.resolvingSymlinksInPath().path + "/"
        let libraryNames = Set(inLibrary.map(\.name))
        groups = grouped(skills.filter { skill in
            skill.origin != .canonical && !skill.origin.isReadOnly && !libraryNames.contains(skill.name)
                && !skill.directory.resolvingSymlinksInPath().path.hasPrefix(libraryPath)
        })
        builtIns = grouped(readOnly)

        var entries: [LibraryEntry] = librarySkills.filter { packs[$0.name] == nil }.map(LibraryEntry.skill)
        for (pack, members) in Dictionary(grouping: librarySkills.filter { packs[$0.name] != nil }, by: { packs[$0.name]! }) {
            entries.append(.pack(name: pack, skills: members))
        }
        libraryEntries = entries.sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }

        var providers: [String: [SkillTarget: String]] = [:]
        for skill in skills where libraryNames.contains(skill.name) && !skill.directory.resolvingSymlinksInPath().path.hasPrefix(libraryPath) {
            let label: String? = if let plugin = skill.pluginName { plugin } else {
                switch skill.origin {
                case .claudeDesktopManaged: "Claude app"
                case .codexPlugin, .claudePlugin: "a plugin"
                case .codexBundled: "Codex"
                default: nil
                }
            }
            guard let label else { continue }
            for target in skill.loadedBy { providers[skill.name, default: [:]][target] = label }
        }
        self.providers = providers
        builtInNames = readOnly.reduce(into: [:]) { $0[$1.name, default: []].formUnion($1.loadedBy) }
        isBusy = false
    }

    /// "Not in the library", with the skills of one pack (a folder of skills in a tool's skills
    /// folder) under one row.
    var unmanagedEntries: [(id: String, pack: String?, groups: [Group])] {
        func pack(_ group: Group) -> String? {
            for copy in group.copies {
                for root in [lastLocations?.claudeUser, lastLocations?.codexUser, lastLocations?.agentsUser].compactMap({ $0 }) {
                    let prefix = root.standardizedFileURL.path + "/"
                    let path = copy.directory.standardizedFileURL.path
                    guard path.hasPrefix(prefix) else { continue }
                    let parts = path.dropFirst(prefix.count).split(separator: "/")
                    if parts.count > 1 { return String(parts[0]) }
                }
            }
            return nil
        }
        var single: [(id: String, pack: String?, groups: [Group])] = []
        var packs: [String: [Group]] = [:]
        for group in groups {
            if let name = pack(group) { packs[name, default: []].append(group) } else { single.append((group.name, nil, [group])) }
        }
        let grouped = packs.map { (id: "pack:" + $0.key, pack: Optional($0.key), groups: $0.value) }
        return (single + grouped).sorted { ($0.pack ?? $0.id).localizedStandardCompare($1.pack ?? $1.id) == .orderedAscending }
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
        planToggle([name], title: name, target, enabled: on, locations: locations)
    }

    /// One plan for several skills, such as a whole pack.
    func planToggle(_ names: [String], title: String, _ target: SkillTarget, enabled on: Bool, locations: SkillLocations) {
        let library = library(for: locations)
        var plan = SkillPlan()
        for name in names {
            let part = library.togglePlan(name: name, target: target, enabled: on, discovered: discovered)
            plan.steps += part.steps
            plan.warnings += part.warnings
        }
        guard !plan.isEmpty else { return }
        pending = PendingPlan(title: "\(on ? "Enable" : "Disable") \(title) for \(target.rawValue)", plan: plan)
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
            .buttonStyle(GlassButtonStyle())
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

    private func libraryRow(_ skill: DiscoveredSkill) -> LibraryRow {
        let enabled = model.enabled[skill.name] ?? []
        return LibraryRow(skill: skill, enabled: enabled, providers: model.providers[skill.name] ?? [:],
                          clashes: model.clashes(skill.name, loadedBy: enabled)) { target, on in
            model.planToggle(skill.name, target, enabled: on, locations: locations)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.syncNeeded.isEmpty || !model.syncNeeded.warnings.isEmpty {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.syncNeeded.isEmpty ? "Claude Code copies" : "\(model.syncNeeded.steps.count) Claude Code skill(s) to update")
                            .font(.callout.weight(.semibold))
                        Text(model.syncNeeded.isEmpty
                             ? model.syncNeeded.warnings.joined(separator: " ")
                             : "Claude Code gets a copy of each skill (the Claude app skips links). These are older links or copies behind the library.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.syncNeeded.isEmpty {
                        Button("Update…") { model.pending = .init(title: "Update Claude Code's copies", plan: model.syncNeeded) }
                            .buttonStyle(GlassButtonStyle())
                    }
                }
                .glassCard(cornerRadius: 10, padding: 10)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("AgentDeck library (\(model.librarySkills.count))").font(.headline)
                if model.librarySkills.isEmpty {
                    Text("Empty. Import skills to manage them here and switch them on per tool.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.libraryEntries) { entry in
                    switch entry {
                    case .skill(let skill):
                        libraryRow(skill)
                    case .pack(let name, let skills):
                        PackRow(name: name, skills: skills, enabled: model.enabled, providers: model.providers, row: libraryRow) { target, on in
                            model.planToggle(skills.map(\.name), title: name, target, enabled: on, locations: locations)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                let conflicts = model.groups.filter(\.isConflict).count
                Text(conflicts > 0 ? "Not in the library (\(model.groups.count), \(conflicts) with differing copies)" : "Not in the library (\(model.groups.count))")
                    .font(.headline)
                    .help("Skills in ~/.claude/skills, ~/.codex/skills and ~/.agents/skills that AgentDeck does not manage yet.")
                ForEach(model.unmanagedEntries, id: \.id) { entry in
                    if entry.groups.count == 1, entry.pack == nil, let group = entry.groups.first {
                        SkillGroupRow(group: group, clashes: model.clashes(group.name, loadedBy: group.loadedBy))
                    } else {
                        UnmanagedPackRow(name: entry.pack ?? "", groups: entry.groups) { group in
                            SkillGroupRow(group: group, clashes: model.clashes(group.name, loadedBy: group.loadedBy))
                        }
                    }
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
    let providers: [SkillTarget: String]
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
                ToolSwitch(target: target, isOn: enabled.contains(target), provider: providers[target]) { toggle(target, $0) }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.tile.opacity(0.6)))
    }
}

/// A tool's switch for one skill or pack. When the tool already gets it some other way (a plugin,
/// the Claude app) and AgentDeck has not linked it, that is shown instead, so an off switch never
/// reads as "this tool cannot use it".
private struct ToolSwitch: View {
    let target: SkillTarget
    let isOn: Bool
    var isMixed = false
    let provider: String?
    let set: (Bool) -> Void

    var body: some View {
        if let provider, !isOn {
            HStack(spacing: 4) {
                ToolIcon(target: target, isActive: true, size: 14)
                Text("\(ToolIcons.name(target)) via \(provider)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .help("\(ToolIcons.name(target)) already loads this from \(provider), so AgentDeck does not link a second copy.")
        } else {
            Toggle(isOn: Binding(get: { isOn }, set: set)) {
                HStack(spacing: 4) {
                    ToolIcon(target: target, isActive: isOn || isMixed, size: 14)
                    Text(ToolIcons.name(target) + (isMixed ? " (some)" : ""))
                }
            }
            .toggleStyle(GlassSwitchStyle())
        }
    }
}

/// Skills of one pack that are not in the library, collapsed under the pack's name.
private struct UnmanagedPackRow<Row: View>: View {
    let name: String
    let groups: [SkillsModel.Group]
    let row: (SkillsModel.Group) -> Row
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.secondary).frame(width: 12)
                Text(name).fontWeight(.semibold)
                Text("\(groups.count) skills").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            if expanded {
                ForEach(groups) { group in row(group).padding(.leading, 20) }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.tile.opacity(0.6)))
    }
}

/// A pack (research-co-pilot, …) as one row, with one switch per tool for all its skills. Expanding
/// it shows each skill with its own switches.
private struct PackRow: View {
    let name: String
    let skills: [DiscoveredSkill]
    let enabled: [String: Set<SkillTarget>]
    let providers: [String: [SkillTarget: String]]
    let row: (DiscoveredSkill) -> LibraryRow
    let toggle: (SkillTarget, Bool) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.secondary).frame(width: 12)
                Text(name).fontWeight(.semibold)
                Text("\(skills.count) skills").font(.callout).foregroundStyle(.secondary)
                Spacer()
                ForEach(SkillTarget.allCases, id: \.self) { target in
                    let on = skills.filter { enabled[$0.name]?.contains(target) == true }.count
                    let provided = Set(skills.compactMap { providers[$0.name]?[target] })
                    let allProvided = provided.count == 1 && skills.allSatisfy { providers[$0.name]?[target] != nil }
                    ToolSwitch(target: target, isOn: on == skills.count, isMixed: on > 0 && on < skills.count,
                               provider: allProvided ? provided.first : nil) { toggle(target, $0) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            if expanded {
                ForEach(skills, id: \.name) { skill in row(skill).padding(.leading, 20) }
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
                ToolIcon(target: target, isActive: group.loadedBy.contains(target))
                    .help(group.loadedBy.contains(target) ? "\(target.rawValue) loads it" : "\(target.rawValue) does not load it")
            }
            // A fixed slot, so the tool icons line up whether or not a row has an issue.
            Group {
                if let worst = group.worstIssue { SeverityIcon(severity: worst) } else { Color.clear }
            }
            .frame(width: 16)
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

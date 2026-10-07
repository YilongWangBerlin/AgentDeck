import AgentDeckCore
import SwiftUI

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

    private(set) var groups: [Group] = []
    private(set) var isScanning = false
    var showReadOnly = false

    func scan(locations: SkillLocations) async {
        isScanning = true
        let skills = await Task.detached(priority: .utility) { SkillScanner.scan(locations) }.value
        groups = Dictionary(grouping: skills, by: \.name)
            .map { Group(name: $0.key, copies: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        isScanning = false
    }

    var visibleGroups: [Group] { showReadOnly ? groups : groups.filter { !$0.isReadOnly } }
}

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

struct SkillsView: View {
    @Bindable var model: SkillsModel
    let locations: SkillLocations
    @Environment(\.isRenderingSnapshot) private var isRenderingSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                let conflicts = model.visibleGroups.filter(\.isConflict).count
                Text("\(model.visibleGroups.count) skills · \(conflicts) with differing copies")
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Show plugin and built-in skills", isOn: $model.showReadOnly).toggleStyle(.checkbox)
                Button(model.isScanning ? "Scanning…" : "Rescan") { Task { await model.scan(locations: locations) } }
                    .disabled(model.isScanning)
            }
            if isRenderingSnapshot {
                list
            } else {
                ScrollView { list }
            }
            Text("Read-only view. Importing into AgentDeck and enabling skills per tool come next; nothing here changes your files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { if model.groups.isEmpty { await model.scan(locations: locations) } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.visibleGroups) { group in
                SkillGroupRow(group: group)
            }
        }
    }
}

private struct SkillGroupRow: View {
    let group: SkillsModel.Group
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.secondary).frame(width: 12)
                Text(group.name).fontWeight(.medium)
                if group.isConflict { Badge(text: "\(group.copies.count) differing copies", color: .orange) }
                else if group.copies.count > 1 { Badge(text: "\(group.copies.count) identical copies", color: .secondary) }
                if group.isReadOnly { Badge(text: "read-only", color: .secondary) }
                Spacer()
                ForEach(SkillTarget.allCases, id: \.self) { target in
                    Text(target == .claudeCode ? "CC" : "CX")
                        .font(.caption.monospaced())
                        .foregroundStyle(group.loadedBy.contains(target) ? .primary : .tertiary)
                        .help(group.loadedBy.contains(target) ? "\(target.rawValue) loads it" : "\(target.rawValue) does not load it")
                }
                if let worst = group.worstIssue {
                    Image(systemName: worst == .error ? "xmark.octagon.fill" : worst == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(worst == .error ? .red : worst == .warning ? .orange : .secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                ForEach(Array(group.copies.enumerated()), id: \.offset) { _, copy in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(copy.origin.rawValue).font(.caption.weight(.semibold))
                            Text(String(copy.contentHash.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(Self.tilde(copy.directory.path) + (copy.symlinkDestination.map { " → " + Self.tilde($0.path) } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        ForEach(Array(copy.issues.enumerated()), id: \.offset) { _, issue in
                            Text("\(issue.targets.map(\.rawValue).sorted().joined(separator: ", ")): \(issue.message)")
                                .font(.caption)
                                .foregroundStyle(issue.severity == .error ? .red : issue.severity == .warning ? .orange : .secondary)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.tile.opacity(0.6)))
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
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

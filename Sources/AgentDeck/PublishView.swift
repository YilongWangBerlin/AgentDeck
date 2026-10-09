import AgentDeckCore
import AppKit
import SwiftUI

struct PublishView: View {
    @Bindable var app: AppModel
    let publishing: PublishModel
    @Environment(\.isRenderingSnapshot) private var isRenderingSnapshot

    var body: some View {
        if isRenderingSnapshot { form } else { ScrollView { form } }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            if publishing.awaitingReview {
                Label("Today's scheduled update is prepared and waits for your review below.", systemImage: "bell")
                    .foregroundStyle(Palette.warning)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Publish usage to GitHub", isOn: $app.settings.publish.isEnabled)
                    Text("Off by default. When on, AgentDeck pushes from its own clones in ~/.agentdeck/publish with your git credentials. Nothing else uses the network.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("What is published").font(.subheadline.weight(.semibold))
                    HStack(spacing: 18) {
                        Toggle("Claude Code", isOn: $app.settings.publish.options.includeClaudeCode)
                        Toggle("Codex", isOn: $app.settings.publish.options.includeCodex)
                        Toggle("Model names", isOn: $app.settings.publish.options.includeModelNames)
                    }
                    Text("Daily totals per tool (and model), sessions, messages, active days, peak hour and favorite model. Never paths, project or repository names, session IDs, prompts or message content.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach($app.settings.publish.targets) { $target in
                TargetEditor(target: $target)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Prepare an update every day at", isOn: $app.settings.publish.scheduleEnabled)
                    DatePicker("Time", selection: scheduleTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .disabled(!app.settings.publish.scheduleEnabled)
                    Toggle("Push scheduled updates without asking me", isOn: $app.settings.publish.pushScheduledWithoutReview)
                        .disabled(!app.settings.publish.scheduleEnabled)
                    Text("Without this, the daily run only prepares the update and sends a notification; you review and push it here. Unchanged data is never committed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            previewSection
        }
        .padding(.bottom, 8)
        .disabled(publishing.isWorking)
    }

    private var scheduleTime: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(app.settings.publish.scheduleMinute) * 60) },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                app.settings.publish.scheduleMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Preview and publish").font(.headline)
                if publishing.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Preview…") { Task { await publishing.prepare(app.settings.publish) } }
                    .disabled(!app.settings.publish.isEnabled)
                Button("Push") {
                    Task { if await publishing.push() { app.settings.publish.lastPublished = Date() } }
                }
                .disabled(!publishing.hasChanges)
                .help("Commits and pushes exactly what the preview shows.")
            }
            if let last = app.settings.publish.lastPublished {
                Text("Last published \(MenuText.ago(last, now: app.now)).").font(.caption).foregroundStyle(.secondary)
            }
            if let message = publishing.message {
                Text(message).font(.callout).textSelection(.enabled)
            }
            ForEach(publishing.previews) { item in
                PreviewCard(item: item)
            }
        }
    }
}

private struct TargetEditor: View {
    @Binding var target: PublishTarget

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(target.kind == .profile ? "Profile README card" : "GitHub Pages data", isOn: $target.isEnabled)
                    .font(.subheadline.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Repository").foregroundStyle(.secondary)
                        TextField(target.kind == .profile ? "https://github.com/<you>/<you>.git" : "https://github.com/<you>/<you>.github.io.git",
                                  text: $target.remote)
                    }
                    GridRow {
                        Text("Branch").foregroundStyle(.secondary)
                        TextField("main", text: $target.branch).frame(width: 140)
                    }
                    GridRow {
                        Text("Folder").foregroundStyle(.secondary)
                        TextField("assets/agentdeck", text: $target.folder).frame(width: 220)
                    }
                    GridRow {
                        Text("Commits").foregroundStyle(.secondary)
                        Picker("", selection: $target.strategy) {
                            Text("A new commit for each update").tag(PublishTarget.CommitStrategy.newCommit)
                            Text("Amend AgentDeck's own commit (force-push)").tag(PublishTarget.CommitStrategy.amendOwnCommit)
                        }
                        .labelsHidden()
                        .frame(width: 320)
                    }
                }
                .disabled(!target.isEnabled)
                Text(target.strategy == .amendOwnCommit
                     ? "Keeps one AgentDeck commit on top so your contribution graph is not inflated. Only AgentDeck's own commit is rewritten; pull with --rebase if you edit this repository elsewhere."
                     : "Adds one commit whenever the numbers change.")
                    .font(.caption).foregroundStyle(.secondary)
                if target.kind == .profile {
                    Toggle("Update the agentdeck block in README.md", isOn: $target.updateReadmeBlock)
                        .disabled(!target.isEnabled)
                    HStack(alignment: .top) {
                        Text(Publisher.readmeSnippet(folder: target.folder))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Publisher.readmeSnippet(folder: target.folder), forType: .string)
                        }
                    }
                    Text("Paste this block into your README once. AgentDeck only ever edits between the two markers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PreviewCard: View {
    let item: PublishModel.TargetPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(item.target.kind == .profile ? "Profile" : "Pages") · \(item.target.remote)").font(.subheadline.weight(.semibold))
            if let error = item.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if let preview = item.preview {
                if preview.hasChanges {
                    Text("Changes: \(preview.changedPaths.joined(separator: ", "))").font(.callout)
                } else {
                    Text("No changes; nothing will be committed.").font(.callout).foregroundStyle(.secondary)
                }
                if let readme = readmeNote(preview.readme) {
                    Text(readme).font(.caption).foregroundStyle(.secondary)
                }
                if preview.hasChanges {
                    DisclosureGroup("Diff") {
                        Text(preview.diff).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            }
            if let result = item.result {
                Label(result.note, systemImage: result.pushed ? "checkmark.circle" : "info.circle").font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.tile.opacity(0.5)))
    }

    private func readmeNote(_ status: PublishPreview.ReadmeStatus) -> String? {
        switch status {
        case .notRequested: nil
        case .updated: "README: the agentdeck block is updated."
        case .unchanged: "README: the agentdeck block is already current."
        case .noReadme: "README: no README.md in this repository."
        case .noMarkers: "README: no agentdeck markers yet, so it is left alone. Paste the snippet above to enable it."
        }
    }
}

import AgentDeckCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemNote: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show 5-hour usage next to the menu bar icon", isOn: $model.settings.showUsageInMenuBar)
                Toggle("Open AgentDeck at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginItemNote {
                    Text(loginItemNote).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Appearance") {
                ThemePicker(selection: $model.settings.theme)
            }

            Section {
                budgetField("5-hour window", tokens: $model.settings.budgets.claudeFiveHourTokens)
                budgetField("Last 7 days", tokens: $model.settings.budgets.claudeSevenDayTokens)
            } header: {
                Text("Claude Code soft budgets")
            } footer: {
                Text("Claude Code does not log its limits, so AgentDeck shows no percentage unless you set a budget here. It only drives a progress bar and an alert.")
                    .foregroundStyle(.secondary)
            }

            Section("Alerts") {
                Toggle("Notify when a window passes the threshold", isOn: $model.settings.alertsEnabled)
                LabeledContent("Threshold") {
                    HStack {
                        Slider(value: $model.settings.alertThresholdPercent, in: 50...100, step: 5)
                        Text("\(Int(model.settings.alertThresholdPercent))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!model.settings.alertsEnabled)
                if model.notificationsDenied {
                    Text("Notifications are turned off for AgentDeck in System Settings › Notifications.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                TextField("Claude config directory", text: $model.settings.claudeConfigDirectory, prompt: Text("~/.claude"))
                TextField("Codex home", text: $model.settings.codexHome, prompt: Text("~/.codex"))
            } header: {
                Text("Log locations")
            } footer: {
                Text("Same meaning as $CLAUDE_CONFIG_DIR and $CODEX_HOME, which apps started from Finder do not see. Logs are only ever read.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemNote = SMAppService.mainApp.status == .requiresApproval
                ? "Allow AgentDeck in System Settings › General › Login Items." : nil
        } catch {
            loginItemNote = "macOS refused: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Edits a token budget in millions; empty means no budget.
    private func budgetField(_ label: String, tokens: Binding<Int?>) -> some View {
        let millions = Binding<Double?>(
            get: { tokens.wrappedValue.map { Double($0) / 1_000_000 } },
            set: { tokens.wrappedValue = $0.flatMap { $0 > 0 ? Int(($0 * 1_000_000).rounded()) : nil } }
        )
        return LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("", value: millions, format: .number, prompt: Text("none"))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("M tokens").foregroundStyle(.secondary)
            }
        }
    }
}

/// A row of swatches, one per theme: its glass, a card, and its accent and heatmap colors.
private struct ThemePicker: View {
    @Binding var selection: Theme

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Theme.allCases) { theme in
                Button { selection = theme } label: { swatch(theme) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.name)
                    .accessibilityAddTraits(selection == theme ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func swatch(_ theme: Theme) -> some View {
        let colors = theme.colors
        let selected = selection == theme
        return VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colors.glass.color)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 2) {
                        ForEach(colors.heat.indices, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2).fill(colors.heat[index].color).frame(width: 8, height: 8)
                        }
                    }
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    Circle().fill(colors.accent?.color ?? .accentColor).frame(width: 12, height: 12).padding(6)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? (colors.accent?.color ?? .accentColor) : Color.primary.opacity(0.12),
                                      lineWidth: selected ? 2 : 0.5)
                )
                .frame(width: 70, height: 46)
            Text(theme.name)
                .font(.caption)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
    }
}

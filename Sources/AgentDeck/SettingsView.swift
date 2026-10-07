import AgentDeckCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
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

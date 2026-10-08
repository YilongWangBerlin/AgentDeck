import AgentDeckCore
import AgentDeckParsing
import AppKit
import SwiftUI

/// Wording shared by the menu and the notifications.
enum MenuText {
    /// English with a 24-hour clock (`23:30`, `Sat 00:27`), matching the rest of the UI rather than the
    /// system language.
    static func time(_ date: Date, now: Date) -> String {
        var style: Date.FormatStyle = date.timeIntervalSince(now) > 20 * 3600
            ? .dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            : .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        style.locale = Locale(identifier: "en_GB")
        return date.formatted(style)
    }

    static func ago(_ date: Date, now: Date) -> String {
        "\(Formatting.duration(now.timeIntervalSince(date))) ago"
    }

    static func alert(for gauge: LimitGauge, snapshot: LimitsSnapshot) -> Notifier.Message {
        let percent = Int(((gauge.fraction ?? 0) * 100).rounded())
        let resets = gauge.resetsAt.map { " Resets \(time($0, now: snapshot.computedAt)) (in \(Formatting.duration($0.timeIntervalSince(snapshot.computedAt))))." } ?? ""
        switch gauge.kind {
        case .codexFiveHour:
            return .init(title: "Codex 5-hour window at \(percent)%", body: "As reported by Codex." + resets)
        case .codexWeekly:
            return .init(title: "Codex weekly window at \(percent)%", body: "As reported by Codex." + resets)
        case .claudeFiveHour:
            return .init(title: "Claude Code: about \(percent)% of the 5-hour limit",
                         body: "\(Formatting.compactTokens(snapshot.claude.tokensInWindow)) tokens this window (estimate)." + resets)
        case .claudeSevenDay:
            return .init(title: "Claude Code: about \(percent)% of the 7-day limit",
                         body: "\(Formatting.compactTokens(snapshot.claude.tokensLast7Days)) tokens in the last 7 days.")
        }
    }
}

/// The whole app UI: the dropdown under the menu bar text. A one-line limits summary on top, then
/// the tabs (Limits, Overview, Models, Skills, Publish).
struct MenuContentView: View {
    let model: AppModel
    /// True in the standalone window, which can be resized; the dropdown has a fixed width.
    var inWindow = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            summary
            DashboardView(model: model.dashboard, app: model)
                .frame(maxHeight: inWindow ? .infinity : nil, alignment: .top)
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Palette.warning)
            }
            footer
        }
        .padding(16)
        .padding(.top, inWindow ? 18 : 0) // room for the window buttons
        .frame(minWidth: 620, idealWidth: 620, maxWidth: inWindow ? .infinity : 620,
               maxHeight: inWindow ? .infinity : nil, alignment: .top)
        .background(GlassBackground())
        .environment(\.dashboardFillsHeight, inWindow)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(nsImage: MenuBarLabel.icon).renderingMode(.template).foregroundStyle(.secondary)
            Text("AgentDeck").font(.headline)
            Spacer()
            if let scanned = model.lastScanAt {
                Text("Scanned \(MenuText.ago(scanned, now: model.now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !inWindow {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: MainWindow.id)
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(GlassButtonStyle(iconOnly: true))
                .help("Open AgentDeck in a window")
            }
        }
    }

    /// Both tools' 5-hour windows at a glance; a click opens the Limits tab.
    private var summary: some View {
        HStack(spacing: 10) {
            Label { Text(claudeSummary) } icon: { ToolIcon(target: .claudeCode) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 10, padding: 9)
            Label { Text(codexSummary) } icon: { ToolIcon(target: .codex) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 10, padding: 9)
        }
        .font(.callout)
        .lineLimit(1)
        .contentShape(Rectangle())
        .onTapGesture { model.dashboard.tab = .limits }
        .help("Open the Limits tab")
    }

    private var claudeSummary: String {
        guard let snapshot = model.snapshot else { return "Claude Code: reading logs" }
        guard let window = snapshot.claude.window, window.end > model.now else { return "Claude Code: no window running" }
        let percent = model.gauge(.claudeFiveHour)?.fraction.map { "\(Int(($0 * 100).rounded()))% · " } ?? ""
        return "Claude Code \(percent)~\(Formatting.compactTokens(snapshot.claude.tokensInWindow)) · resets ~\(MenuText.time(window.end, now: model.now))"
    }

    private var codexSummary: String {
        guard let codex = model.snapshot?.codex, codex.fiveHour != nil || codex.weekly != nil else { return "Codex: no limit data yet" }
        func part(_ label: String, _ window: ReportedWindow?, tokens: Int? = nil) -> String? {
            guard let window else { return nil }
            switch window.status(at: model.now) {
            case .current(let percent):
                return "\(label) \(Int(percent.rounded()))%" + (tokens.map { " · \(Formatting.compactTokens($0))" } ?? "")
            case .resetSinceLastUpdate: return "\(label) reset"
            }
        }
        return "Codex " + [part("5h", codex.fiveHour, tokens: codex.tokensInFiveHour), part("weekly", codex.weekly)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            if model.settings.publish.isEnabled {
                Button("Publish now…") {
                    model.dashboard.tab = .publish
                    Task { await model.publishing.prepare(model.settings.publish) }
                }
                .help("Prepares the update and shows it in the Publish tab; nothing is pushed until you click Push.")
            }
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Spacer()
            Button("Quit AgentDeck") { NSApp.terminate(nil) }
        }
        .buttonStyle(GlassButtonStyle())
    }
}

/// The detailed rate-limit view: each tool's 5-hour window, the weekly window, and how fresh the
/// data is.
struct LimitsView: View {
    let model: AppModel

    var body: some View {
        if let snapshot = model.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                claudeSection(snapshot).glassCard()
                codexSection(snapshot).glassCard()
            }
        } else {
            Text("Reading logs…").foregroundStyle(.secondary)
        }
    }

    // MARK: Claude Code

    @ViewBuilder
    private func claudeSection(_ snapshot: LimitsSnapshot) -> some View {
        let claude = snapshot.claude
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Claude Code", badge: "Estimate")

            if let window = claude.window, window.end > model.now {
                MetricRow(label: "5-hour window", value: withPercent(.claudeFiveHour, "~\(Formatting.compactTokens(claude.tokensInWindow)) tokens"))
                if let gauge = model.gauge(.claudeFiveHour) { BudgetBar(gauge: gauge) }
                Caption("Resets ~\(MenuText.time(window.end, now: model.now)) (in \(Formatting.duration(window.end.timeIntervalSince(model.now))))")
            } else {
                MetricRow(label: "5-hour window", value: "Not running")
                Caption("The next request starts a new window.")
            }

            MetricRow(label: "Last 7 days", value: withPercent(.claudeSevenDay, "\(Formatting.compactTokens(claude.tokensLast7Days)) tokens"))
            if let gauge = model.gauge(.claudeSevenDay) { BudgetBar(gauge: gauge) }
        }
    }

    /// When a tool last reported its limits; orange after an hour, since the values may be out of date.
    private func freshness(_ prefix: String, _ observed: Date) -> some View {
        let stale = model.now.timeIntervalSince(observed) > 3600
        return Label("\(prefix) \(MenuText.ago(observed, now: model.now))", systemImage: stale ? "clock.badge.exclamationmark" : "clock")
            .font(.caption)
            .foregroundStyle(stale ? AnyShapeStyle(Palette.warning) : AnyShapeStyle(.secondary))
    }

    // MARK: Codex

    @ViewBuilder
    private func codexSection(_ snapshot: LimitsSnapshot) -> some View {
        let codex = snapshot.codex
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Codex", badge: codex.planType.map { $0.capitalized })
            if codex.fiveHour == nil, codex.weekly == nil {
                Caption("No rate-limit data in the Codex logs yet.")
            }
            if let window = codex.fiveHour {
                reportedWindow("5-hour window", window, kind: .codexFiveHour,
                               tokens: codex.tokensInFiveHour.map { "\(Formatting.compactTokens($0)) tokens" })
            }
            if let window = codex.weekly {
                reportedWindow("Weekly", window, kind: .codexWeekly,
                               tokens: codex.tokensInWeek.map { "\(Formatting.compactTokens($0)) tokens" })
            }
            if let observed = [codex.fiveHour?.observedAt, codex.weekly?.observedAt].compactMap({ $0 }).max() {
                freshness("Last reported by Codex", observed)
            }
        }
    }

    /// `54% · ~80.8M tokens` when a budget gives a percentage, otherwise just the tokens.
    private func withPercent(_ kind: LimitGauge.Kind, _ tokens: String) -> String {
        guard let fraction = model.gauge(kind)?.fraction else { return tokens }
        return "\(Int((fraction * 100).rounded()))% · \(tokens)"
    }

    @ViewBuilder
    private func reportedWindow(_ label: String, _ window: ReportedWindow, kind: LimitGauge.Kind, tokens: String? = nil) -> some View {
        switch window.status(at: model.now) {
        case .current(let percent):
            MetricRow(label: label, value: ["\(Int(percent.rounded()))% used", tokens].compactMap { $0 }.joined(separator: " · "))
            if let gauge = model.gauge(kind) { BudgetBar(gauge: gauge) }
            Caption("Resets \(MenuText.time(window.resetsAt, now: model.now)) (in \(Formatting.duration(window.resetsAt.timeIntervalSince(model.now))))")
        case .resetSinceLastUpdate:
            MetricRow(label: label, value: "Reset")
            Caption("Reset at \(MenuText.time(window.resetsAt, now: model.now)). No newer value until the tool runs again.")
        }
    }
}

// MARK: - Pieces

private struct SectionTitle: View {
    let title: String
    let badge: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.tile, in: Capsule())
            }
        }
    }
}

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.callout)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A bar for a gauge. Bars that are not the provider's own percentage say what they measure against.
private struct BudgetBar: View {
    let gauge: LimitGauge

    static func note(_ basis: LimitGauge.Basis) -> String? {
        switch basis {
        case .reported: nil
        case .softBudget(let tokens): "Of your \(Formatting.compactTokens(tokens)) budget"
        case .learned(let tokens, let samples):
            "Of ~\(Formatting.compactTokens(tokens)), the limit measured " + (samples == 1 ? "the one time" : "over the \(samples) times") + " Claude Code stopped you"
        }
    }

    var body: some View {
        if let fraction = gauge.fraction {
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.tile)
                        Capsule()
                            .fill(fraction >= 0.9 ? Color.red : fraction >= 0.75 ? Color.orange : Color.accentColor)
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
                }
                .frame(height: 6)
                .accessibilityElement()
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                if let note = Self.note(gauge.basis) {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

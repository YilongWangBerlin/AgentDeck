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
            return .init(title: "Claude Code: \(percent)% of your 5-hour budget",
                         body: "\(Formatting.compactTokens(snapshot.claude.tokensInWindow)) tokens this window (estimate)." + resets)
        case .claudeSevenDay:
            return .init(title: "Claude Code: \(percent)% of your 7-day budget",
                         body: "\(Formatting.compactTokens(snapshot.claude.tokensLast7Days)) tokens in the last 7 days.")
        }
    }
}

struct MenuContentView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let snapshot = model.snapshot {
                claudeSection(snapshot)
                Divider()
                codexSection(snapshot)
            } else {
                Text("Reading logs…").foregroundStyle(.secondary)
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("AgentDeck").font(.headline)
            Spacer()
            if let scanned = model.lastScanAt {
                Text("Scanned \(MenuText.ago(scanned, now: model.now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Claude Code

    @ViewBuilder
    private func claudeSection(_ snapshot: LimitsSnapshot) -> some View {
        let claude = snapshot.claude
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Claude Code", badge: "Estimate")

            if let window = claude.window, window.end > model.now {
                MetricRow(label: "5-hour window", value: "~\(Formatting.compactTokens(claude.tokensInWindow)) tokens")
                if let gauge = model.gauge(.claudeFiveHour) { BudgetBar(gauge: gauge) }
                Caption(window.isConfirmedByRefusal
                    ? "Resets \(MenuText.time(window.end, now: model.now)) (in \(Formatting.duration(window.end.timeIntervalSince(model.now)))), confirmed by a rate-limit message"
                    : "Started ~\(MenuText.time(window.start, now: model.now)) · resets ~\(MenuText.time(window.end, now: model.now)) (in \(Formatting.duration(window.end.timeIntervalSince(model.now))))")
            } else {
                MetricRow(label: "5-hour window", value: "Not running")
                Caption("The next request starts a new window.")
            }

            MetricRow(label: "Last 7 days", value: "\(Formatting.compactTokens(claude.tokensLast7Days)) tokens")
            if let gauge = model.gauge(.claudeSevenDay) { BudgetBar(gauge: gauge) }

            Caption("From Claude Code logs only. Use in claude.ai counts toward the same limits but is not visible here. Claude Code logs no weekly limit.")
        }
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
            if let window = codex.fiveHour { reportedWindow("5-hour window", window, kind: .codexFiveHour) }
            if let window = codex.weekly { reportedWindow("Weekly", window, kind: .codexWeekly) }
            if let observed = [codex.fiveHour?.observedAt, codex.weekly?.observedAt].compactMap({ $0 }).max() {
                let stale = model.now.timeIntervalSince(observed) > 3600
                Label("Last reported by Codex \(MenuText.ago(observed, now: model.now))", systemImage: stale ? "clock.badge.exclamationmark" : "clock")
                    .font(.caption)
                    .foregroundStyle(stale ? .orange : .secondary)
            }
        }
    }

    @ViewBuilder
    private func reportedWindow(_ label: String, _ window: ReportedWindow, kind: LimitGauge.Kind) -> some View {
        switch window.status(at: model.now) {
        case .current(let percent):
            MetricRow(label: label, value: "\(Int(percent.rounded()))% used")
            if let gauge = model.gauge(kind) { BudgetBar(gauge: gauge) }
            Caption("Resets \(MenuText.time(window.resetsAt, now: model.now)) (in \(Formatting.duration(window.resetsAt.timeIntervalSince(model.now))))")
        case .resetSinceLastUpdate:
            MetricRow(label: label, value: "Reset")
            Caption("Reset at \(MenuText.time(window.resetsAt, now: model.now)). No newer value until Codex runs again.")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Open Dashboard") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "dashboard")
            }
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Spacer()
            Button("Quit AgentDeck") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
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
                    .background(.quaternary, in: Capsule())
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

/// A bar for a gauge. Budget bars say so, so they are never mistaken for the provider's own limit.
private struct BudgetBar: View {
    let gauge: LimitGauge

    var body: some View {
        if let fraction = gauge.fraction {
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(fraction >= 0.9 ? Color.red : fraction >= 0.75 ? Color.orange : Color.accentColor)
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
                }
                .frame(height: 6)
                .accessibilityElement()
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                if case .softBudget(let tokens) = gauge.basis {
                    Text("\(Int((fraction * 100).rounded()))% of your \(Formatting.compactTokens(tokens)) budget")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

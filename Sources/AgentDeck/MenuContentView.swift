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
            Label(claudeSummary, systemImage: "gauge.with.dots.needle.33percent")
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 10, padding: 9)
            Label(codexSummary, systemImage: "gauge.with.dots.needle.67percent")
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
        return "Claude Code ~\(Formatting.compactTokens(snapshot.claude.tokensInWindow)) · resets ~\(MenuText.time(window.end, now: model.now))"
    }

    private var codexSummary: String {
        guard let codex = model.snapshot?.codex, codex.fiveHour != nil || codex.weekly != nil else { return "Codex: no limit data yet" }
        func part(_ label: String, _ window: ReportedWindow?) -> String? {
            guard let window else { return nil }
            switch window.status(at: model.now) {
            case .current(let percent): return "\(label) \(Int(percent.rounded()))%"
            case .resetSinceLastUpdate: return "\(label) reset"
            }
        }
        return "Codex " + [part("5h", codex.fiveHour), part("weekly", codex.weekly)].compactMap { $0 }.joined(separator: " · ")
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
            CalibrationRow(model: model, snapshot: snapshot)
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
                    .foregroundStyle(stale ? AnyShapeStyle(Palette.warning) : AnyShapeStyle(.secondary))
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
}

// MARK: - Pieces

/// Claude Code logs no limits, so its bars need a budget. This turns the percentages on Claude's own
/// usage card into budgets: tokens in the window divided by the percentage shown.
private struct CalibrationRow: View {
    let model: AppModel
    let snapshot: LimitsSnapshot
    @State private var editing = false
    @State private var session = ""
    @State private var weekly = ""

    private var hasBudget: Bool {
        model.settings.budgets.claudeFiveHourTokens != nil || model.settings.budgets.claudeSevenDayTokens != nil
    }

    private var windowIsRunning: Bool { snapshot.claude.window.map { $0.end > model.now } ?? false }

    private var sessionBudget: Int? {
        guard windowIsRunning, let percent = Self.percent(session) else { return nil }
        return SoftBudgets.calibrated(tokens: snapshot.claude.tokensInWindow, percent: percent)
    }

    private var weeklyBudget: Int? {
        Self.percent(weekly).flatMap { SoftBudgets.calibrated(tokens: snapshot.claude.tokensLast7Days, percent: $0) }
    }

    var body: some View {
        if editing || !hasBudget {
            VStack(alignment: .leading, spacing: 6) {
                Text(hasBudget ? "Recalibrate from Claude's usage card" : "Add bars: enter the percentages from Claude's usage card")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    field("Session limit", $session).disabled(!windowIsRunning)
                    field("Weekly", $weekly)
                    Spacer()
                    if hasBudget { Button("Cancel") { editing = false } }
                    Button("Calibrate", action: apply).disabled(sessionBudget == nil && weeklyBudget == nil)
                }
                .buttonStyle(GlassButtonStyle())
                Caption("In the Claude app, open the usage card (Session limit, Weekly · all models). "
                    + "The bars stay estimates: claude.ai use is not in the logs, and the weekly bar sums a rolling 7 days.")
            }
            .padding(.top, 4)
        } else {
            Button("Recalibrate…") { editing = true }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("–", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
            Text("%").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func apply() {
        if let sessionBudget { model.settings.budgets.claudeFiveHourTokens = sessionBudget }
        if let weeklyBudget { model.settings.budgets.claudeSevenDayTokens = weeklyBudget }
        session = ""
        weekly = ""
        editing = false
    }

    static func percent(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: "."))
    }
}

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

/// A bar for a gauge. Budget bars say so, so they are never mistaken for the provider's own limit.
private struct BudgetBar: View {
    let gauge: LimitGauge

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
                if case .softBudget(let tokens) = gauge.basis {
                    Text("\(Int((fraction * 100).rounded()))% of your \(Formatting.compactTokens(tokens)) budget")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

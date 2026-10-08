import AgentDeckWidgetData
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date(), snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let snapshot = WidgetSnapshot.load() ?? (context.isPreview ? .preview : nil)
        completion(UsageEntry(date: Date(), snapshot: snapshot))
    }

    /// One entry now and one at each reset in the next hours, so "reset" shows up on time without
    /// AgentDeck running. The file is read again every 10 minutes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        let refresh = now.addingTimeInterval(600)
        let resets = [snapshot?.claude.windowEnd, snapshot?.codex.fiveHour?.resetsAt, snapshot?.codex.weekly?.resetsAt]
            .compactMap { $0 }
            .filter { $0 > now && $0 < refresh }
        let entries = ([now] + resets.sorted()).map { UsageEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

// MARK: - Widget

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AgentDeckUsage", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                // English like the rest of AgentDeck, whatever the system language.
                .environment(\.locale, Locale(identifier: "en_GB"))
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Coding agent usage")
        .description("Claude Code and Codex limits, and tokens over the last two weeks.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct AgentDeckWidgets: WidgetBundle {
    var body: some Widget { UsageWidget() }
}

// MARK: - Views

struct UsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemSmall: SmallView(snapshot: snapshot, now: entry.date)
            case .systemMedium: MediumView(snapshot: snapshot, now: entry.date)
            default: LargeView(snapshot: snapshot, now: entry.date)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Header()
                Spacer()
                Text("Open AgentDeck to start.").font(.callout)
                Text("The widget shows what AgentDeck last read from your logs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SmallView: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header()
            HStack(spacing: 10) {
                ClaudeRing(snapshot: snapshot, now: now)
                CodexRing(snapshot: snapshot, now: now)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MediumView: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Header()
                HStack(spacing: 10) {
                    ClaudeRing(snapshot: snapshot, now: now)
                    CodexRing(snapshot: snapshot, now: now)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: 150)
            VStack(alignment: .leading, spacing: 6) {
                TodayLine(snapshot: snapshot, compact: true)
                DailyBars(days: snapshot.days)
            }
        }
    }
}

private struct LargeView: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header()
            LimitRow(title: "Claude Code · 5 hours", tint: .claude, fraction: snapshot.claude.windowEnd == nil ? nil : snapshot.claude.windowFraction,
                     value: claudeValue, detail: claudeDetail)
            LimitRow(title: "Claude Code · 7 days", tint: .claude, fraction: snapshot.claude.sevenDayFraction,
                     value: (snapshot.claude.sevenDayFraction.map { "\(Int(($0 * 100).rounded()))% · " } ?? "") + Compact.tokens(snapshot.claude.tokensLast7Days),
                     detail: nil)
            LimitRow(title: "Codex · 5 hours", tint: .codex, fraction: codexFraction(snapshot.codex.fiveHour),
                     value: codexValue(snapshot.codex.fiveHour, tokens: snapshot.codex.fiveHourTokens), detail: resetText(snapshot.codex.fiveHour))
            LimitRow(title: "Codex · weekly", tint: .codex, fraction: codexFraction(snapshot.codex.weekly),
                     value: codexValue(snapshot.codex.weekly, tokens: snapshot.codex.weeklyTokens), detail: resetText(snapshot.codex.weekly))
            Divider().opacity(0.4)
            TodayLine(snapshot: snapshot)
            DailyBars(days: snapshot.days)
        }
    }

    /// `67% · 64.7M` when Claude reported a percentage (or a budget gives one), else the tokens.
    private var claudeValue: String {
        guard snapshot.claude.windowEnd != nil else { return "Not running" }
        let tokens = Compact.tokens(snapshot.claude.tokensInWindow)
        return snapshot.claude.windowFraction.map { "\(Int(($0 * 100).rounded()))% · \(tokens)" } ?? "~" + tokens
    }

    private var claudeDetail: Text? {
        snapshot.claude.windowEnd.map { Text("resets in ") + Text($0, style: .relative) }
    }

    private func codexFraction(_ window: WidgetSnapshot.Window?) -> Double? {
        window?.percent(at: now).map { $0 / 100 }
    }

    private func codexValue(_ window: WidgetSnapshot.Window?, tokens: Int?) -> String {
        guard let window else { return "–" }
        guard let percent = window.percent(at: now) else { return "Reset" }
        return "\(Int(percent.rounded()))%" + (tokens.map { " · " + Compact.tokens($0) } ?? "")
    }

    private func resetText(_ window: WidgetSnapshot.Window?) -> Text? {
        guard let window, window.resetsAt > now else { return nil }
        return Text("resets in ") + Text(window.resetsAt, style: .relative)
    }
}

// MARK: - Pieces

private struct Header: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.stack.3d.up.fill").font(.caption2)
            Text("AgentDeck").font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .widgetAccentable()
    }
}

/// A ring with the number in the middle and a caption under it. Without a denominator the ring is
/// drawn faint and only the number counts.
private struct Ring: View {
    let label: String
    let tint: Color
    let fraction: Double?
    let center: String
    /// Tokens under the name, when the center shows a percentage.
    var detail: String? = nil
    let caption: Text?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(tint.opacity(0.18), lineWidth: 7)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: min(max(fraction, 0.02), 1))
                        .stroke(fraction >= 0.9 ? Color.red : tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .widgetAccentable()
                }
                Text(center)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
            .frame(width: 64, height: 64)
            Text(label).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            if let detail {
                Text(detail).font(.caption2).monospacedDigit().lineLimit(1)
            }
            (caption ?? Text(" "))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ClaudeRing: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        let claude = snapshot.claude
        if let end = claude.windowEnd, end > now {
            Ring(label: "Claude Code", tint: .claude, fraction: claude.windowFraction,
                 center: claude.windowFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? Compact.tokens(claude.tokensInWindow),
                 detail: claude.windowFraction == nil ? nil : Compact.tokens(claude.tokensInWindow),
                 caption: Text(timerInterval: now...max(now, end), countsDown: true))
        } else {
            Ring(label: "Claude Code", tint: .claude, fraction: nil, center: "–", caption: Text("idle"))
        }
    }
}

private struct CodexRing: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        if let window = snapshot.codex.fiveHour, let percent = window.percent(at: now) {
            Ring(label: "Codex", tint: .codex, fraction: percent / 100, center: "\(Int(percent.rounded()))%",
                 detail: snapshot.codex.fiveHourTokens.map(Compact.tokens),
                 caption: Text(timerInterval: now...max(now, window.resetsAt), countsDown: true))
        } else if let weekly = snapshot.codex.weekly, let percent = weekly.percent(at: now) {
            Ring(label: "Codex weekly", tint: .codex, fraction: percent / 100, center: "\(Int(percent.rounded()))%",
                 caption: Text("5h reset"))
        } else {
            Ring(label: "Codex", tint: .codex, fraction: nil, center: "–", caption: Text("no data"))
        }
    }
}

private struct LimitRow: View {
    let title: String
    let tint: Color
    let fraction: Double?
    let value: String
    let detail: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                Text(value).font(.caption.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.16))
                    if let fraction {
                        Capsule()
                            .fill(fraction >= 0.9 ? Color.red : tint)
                            .frame(width: max(4, geometry.size.width * min(fraction, 1)))
                            .widgetAccentable()
                    }
                }
            }
            .frame(height: 5)
            if let detail { detail.font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

private struct TodayLine: View {
    let snapshot: WidgetSnapshot
    /// Short tool names, for the narrow chart of the medium size.
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Today").font(.caption.weight(.semibold))
            Text(Compact.tokens(snapshot.days.last?.total ?? 0)).font(.caption).monospacedDigit()
            Spacer(minLength: 4)
            // The medium size has room for the colors only; the rings below name the tools.
            Legend(color: .claude, label: compact ? nil : "Claude Code")
            Legend(color: .codex, label: compact ? nil : "Codex")
        }
        .lineLimit(1)
    }
}

private struct Legend: View {
    let color: Color
    let label: String?

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            if let label { Text(label).font(.caption2).foregroundStyle(.secondary).fixedSize() }
        }
    }
}

/// Stacked daily bars, today on the right.
private struct DailyBars: View {
    let days: [WidgetSnapshot.Day]

    var body: some View {
        let peak = max(days.map(\.total).max() ?? 0, 1)
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    let height = geometry.size.height * CGFloat(day.total) / CGFloat(peak)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(Color.codex).frame(height: height * CGFloat(day.codex) / CGFloat(max(day.total, 1)))
                        Rectangle().fill(Color.claude).frame(height: height * CGFloat(day.claude) / CGFloat(max(day.total, 1)))
                    }
                    .frame(maxWidth: .infinity)
                    .background(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06)).frame(height: 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
        }
        .widgetAccentable()
    }
}

private struct WidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(white: 0.16), Color(white: 0.10)]
                : [Color(white: 0.99), Color(white: 0.93)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

private extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.31, green: 0.49, blue: 0.85)
}

enum Compact {
    /// `64.7M`, `1.8B`, `950K`.
    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        switch number {
        case 1e9...: return String(format: number >= 1e10 ? "%.0fB" : "%.1fB", number / 1e9)
        case 1e6...: return String(format: number >= 1e8 ? "%.0fM" : "%.1fM", number / 1e6)
        case 1e3...: return String(format: "%.0fK", number / 1e3)
        default: return "\(value)"
        }
    }
}

extension WidgetSnapshot {
    /// For the widget gallery and placeholders.
    static var preview: WidgetSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let days = (0..<14).reversed().map { offset in
            WidgetSnapshot.Day(start: calendar.date(byAdding: .day, value: -offset, to: today)!,
                               claude: [40, 0, 85, 120, 60, 0, 30, 150, 90, 20, 110, 70, 160, 65][13 - offset] * 1_000_000,
                               codex: [10, 5, 0, 30, 25, 0, 0, 40, 15, 10, 0, 35, 20, 12][13 - offset] * 1_000_000)
        }
        return WidgetSnapshot(
            generatedAt: now,
            claude: .init(tokensInWindow: 64_700_000, windowEnd: now.addingTimeInterval(3 * 3600), windowFraction: 0.67,
                          tokensLast7Days: 452_000_000, sevenDayFraction: 0.76),
            codex: .init(fiveHour: .init(usedPercent: 38, resetsAt: now.addingTimeInterval(2 * 3600)),
                         weekly: .init(usedPercent: 65, resetsAt: now.addingTimeInterval(42 * 3600)), reportedAt: now,
                         fiveHourTokens: 21_300_000, weeklyTokens: 159_000_000),
            days: days
        )
    }
}

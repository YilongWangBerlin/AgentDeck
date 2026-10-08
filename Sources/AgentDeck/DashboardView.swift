import AgentDeckCore
import AgentDeckParsing
import Charts
import SwiftUI

@MainActor @Observable
final class DashboardModel {
    enum Tab: String, CaseIterable { case limits = "Limits", overview = "Overview", models = "Models", skills = "Skills", publish = "Publish" }

    enum SourceFilter: String, CaseIterable {
        case all = "All", claude = "Claude Code", codex = "Codex"

        var source: UsageSource? {
            switch self {
            case .all: nil
            case .claude: .claudeCode
            case .codex: .codex
            }
        }
    }

    struct DailyBar: Identifiable {
        var day: Date
        var kind: TokenKind
        var tokens: Int
        var id: String { "\(day.timeIntervalSince1970)-\(kind.rawValue)" }
    }

    var tab = Tab.overview
    var range = DashboardRange.all { didSet { reload() } }
    var sourceFilter = SourceFilter.all { didSet { reload() } }
    var chartModel: String? { didSet { reload() } }
    var includeCache = true

    private(set) var stats = DashboardStats()
    private(set) var heatmap: Heatmap?
    private(set) var models: [ModelUsage] = []
    private(set) var dailyBars: [DailyBar] = []
    private(set) var problem: String?

    let calendar = LocalCalendar()
    @ObservationIgnored private let store: UsageStore?

    init(store: UsageStore?) {
        self.store = store
    }

    /// The usage card for everything in the store, as the profile README would show it.
    func cardSVG(theme: UsageCard.Theme) -> String? {
        guard let store, let export = try? PublicExporter.export(store: store, options: PublicExportOptions()) else { return nil }
        return UsageCard.svg(export, theme: theme)
    }

    func reload(now: Date = Date()) {
        guard let store else { return }
        do {
            let records = try store.usage(in: range.interval(now: now, calendar: calendar), source: sourceFilter.source)
            stats = DashboardData.stats(records, calendar: calendar)
            heatmap = DashboardData.heatmap(records, calendar: calendar, today: calendar.day(containing: now))
            models = DashboardData.models(records)
            let charted = chartModel.map { model in records.filter { $0.model == model } } ?? records
            dailyBars = DashboardData.dailyByKind(charted, calendar: calendar).map {
                DailyBar(day: calendar.start(of: $0.day), kind: $0.kind, tokens: $0.tokens)
            }
            problem = nil
        } catch {
            problem = "Could not read the database: \(error.localizedDescription)"
        }
    }
}

/// The tabs inside the menu bar dropdown.
struct DashboardView: View {
    @Bindable var model: DashboardModel
    var app: AppModel?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isRenderingSnapshot) private var isRenderingSnapshot
    @Environment(\.dashboardFillsHeight) private var fillsHeight
    @State private var exportStatus: String?

    /// The dropdown keeps every tab at one height; the window and offscreen renders let them size freely.
    private var fixedHeight: CGFloat? { isRenderingSnapshot || fillsHeight ? nil : Self.contentHeight }
    private var maxHeight: CGFloat? { fillsHeight ? .infinity : nil }

    /// Fixed height for the larger tabs, so the dropdown does not jump in size between them.
    static let contentHeight: CGFloat = 470

    private var showsUsage: Bool { model.tab == .overview || model.tab == .models }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if showsUsage { filters }
            content
            if let problem = model.problem, showsUsage {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.warning)
            }
        }
        .environment(\.locale, Locale(identifier: "en_GB"))
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .limits:
            if let app { LimitsView(model: app) }
        case .overview:
            OverviewView(model: model)
                .frame(height: fixedHeight, alignment: .top)
                .frame(maxHeight: maxHeight, alignment: .top)
        case .models:
            if isRenderingSnapshot {
                ModelsView(model: model)
            } else {
                ScrollView { ModelsView(model: model) }
                    .frame(height: fixedHeight)
                    .frame(maxHeight: maxHeight)
            }
        case .skills:
            if let app {
                SkillsView(model: app.skills, locations: app.skillLocations)
                    .frame(height: fixedHeight, alignment: .top)
                .frame(maxHeight: maxHeight, alignment: .top)
            }
        case .publish:
            if let app {
                PublishView(app: app, publishing: app.publishing)
                    .frame(height: fixedHeight, alignment: .top)
                .frame(maxHeight: maxHeight, alignment: .top)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(DashboardModel.Tab.allCases, id: \.self) { tab in
                ChipButton(title: tab.rawValue, isSelected: model.tab == tab) { model.tab = tab }
            }
            Spacer()
            if let exportStatus {
                Text(exportStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if showsUsage {
                Button("Export image") { exportImage() }
                    .buttonStyle(GlassButtonStyle())
                    .help("Saves the usage card (the same SVG the profile README uses) for all tools.")
            }
        }
    }

    /// Writes the SVG card in the current appearance.
    private func exportImage() {
        guard let svg = model.cardSVG(theme: colorScheme == .dark ? .dark : .light) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "agentdeck-usage.svg"
        panel.allowedContentTypes = [.svg]
        guard MenuBarPanel.runModal(panel) == .OK, let url = panel.url else { return }
        do {
            try Data(svg.utf8).write(to: url, options: .atomic)
            exportStatus = "Saved \(url.lastPathComponent)"
        } catch {
            exportStatus = "Could not save: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var filters: some View {
        HStack(spacing: 6) {
            Spacer()
            ForEach(DashboardModel.SourceFilter.allCases, id: \.self) { filter in
                ChipButton(title: filter.rawValue, isSelected: model.sourceFilter == filter, compact: true) {
                    model.sourceFilter = filter
                }
            }
            Divider().frame(height: 18).padding(.horizontal, 6)
            ForEach(DashboardRange.allCases, id: \.self) { range in
                ChipButton(title: range == .all ? "All" : range.rawValue, isSelected: model.range == range) {
                    model.range = range
                }
            }
        }
    }
}

// MARK: - Overview

private struct OverviewView: View {
    let model: DashboardModel

    /// `14,051`: English grouping like the rest of the UI, whatever the system language.
    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    var body: some View {
        let stats = model.stats
        VStack(alignment: .leading, spacing: 16) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    StatCard(label: "Sessions", value: Self.number(stats.sessions))
                    StatCard(label: "Messages", value: Self.number(stats.messages),
                             help: "Model responses, each counted once")
                    StatCard(label: "Total tokens", value: Formatting.compactTokens(stats.tokens.total),
                             help: "Input + output + cache, each response counted once. Claude Code's own stats count a response once per content block, so they show about twice as much.")
                }
                GridRow {
                    StatCard(label: "Active days", value: Self.number(stats.activeDays))
                    StatCard(label: "Peak hour", value: stats.peakHour.map(DashboardData.hourLabel) ?? "–",
                             help: "Local hour with the most responses")
                    StatCard(label: "Favorite model", value: stats.favoriteModel.map(DashboardData.displayName) ?? "–",
                             emphasized: false, help: "Model with the most tokens")
                }
            }
            if let heatmap = model.heatmap {
                HeatmapView(heatmap: heatmap)
            }
            if let line = DashboardData.funLine(totalTokens: stats.tokens.total) {
                Text(line)
                    .foregroundStyle(.secondary)
                    .help("The Hobbit ≈ 123,500 tokens: about 95,000 words at about 1.3 tokens per word.")
            }
        }
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    var emphasized = true
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(emphasized ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 10, padding: 10)
        .help(help ?? "")
    }
}

private struct HeatmapView: View {
    let heatmap: Heatmap

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(heatmap.weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 4) {
                    ForEach(week, id: \.day) { cell in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Palette.heat[cell.level])
                            .aspectRatio(1, contentMode: .fit)
                            .help(Self.tooltip(cell))
                    }
                    // Keep the partial current week aligned to the top.
                    ForEach(week.count..<7, id: \.self) { _ in
                        Color.clear.aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
    }

    static func tooltip(_ cell: HeatmapCell) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()
        style.locale = Locale(identifier: "en_GB")
        let date = LocalCalendar().start(of: cell.day).formatted(style)
        guard cell.tokens.total > 0 else { return "\(date): no usage" }
        var lines = ["\(date): \(Formatting.compactTokens(cell.tokens.total)) tokens"]
        for source in UsageSource.allCases {
            if let tokens = cell.bySource[source] {
                lines.append("\(source == .claudeCode ? "Claude Code" : "Codex"): \(Formatting.compactTokens(tokens))")
            }
        }
        lines.append(TokenKind.allCases.map { "\($0.rawValue) \(Formatting.compactTokens($0.amount(in: cell.tokens)))" }.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Models

private struct ModelsView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let total = max(1, model.models.reduce(0) { $0 + $1.tokens.total })
            VStack(spacing: 6) {
                ForEach(model.models, id: \.model) { usage in
                    ModelRow(usage: usage, share: Double(usage.tokens.total) / Double(total))
                }
            }
            HStack(spacing: 6) {
                Text("Daily tokens").font(.headline)
                Spacer()
                ChipButton(title: "All models", isSelected: model.chartModel == nil, compact: true) { model.chartModel = nil }
                ForEach(model.models.prefix(4), id: \.model) { usage in
                    ChipButton(title: DashboardData.displayName(forModel: usage.model), isSelected: model.chartModel == usage.model, compact: true) {
                        model.chartModel = usage.model
                    }
                }
                ChipButton(title: "Cache", isSelected: model.includeCache, compact: true) { model.includeCache.toggle() }
            }
            Chart(model.dailyBars.filter { model.includeCache || $0.kind != .cache }) { bar in
                BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Tokens", bar.tokens))
                    .foregroundStyle(by: .value("Kind", bar.kind.rawValue.capitalized))
            }
            .chartForegroundStyleScale(["Input": Palette.input, "Output": Palette.output, "Cache": Palette.cache])
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let tokens = value.as(Int.self) { Text(Formatting.compactTokens(tokens)) } }
                }
            }
            .frame(minHeight: 220)
        }
    }
}

private struct ModelRow: View {
    let usage: ModelUsage
    let share: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(DashboardData.displayName(forModel: usage.model)).frame(width: 150, alignment: .leading).lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.tile)
                    Capsule().fill(Palette.heat[3]).frame(width: max(2, geometry.size.width * share))
                }
            }
            .frame(height: 8)
            Text(Formatting.compactTokens(usage.tokens.total)).monospacedDigit().frame(width: 60, alignment: .trailing)
            Text("\(Int((share * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        .help("\(usage.responses.formatted(.number.locale(Locale(identifier: "en_US")))) responses · input \(Formatting.compactTokens(usage.tokens.input)) · output \(Formatting.compactTokens(usage.tokens.output)) · cache \(Formatting.compactTokens(usage.tokens.cacheRead + usage.tokens.cacheWrite))")
    }
}

// MARK: - Shared

private struct ChipButton: View {
    let title: String
    let isSelected: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Text(title)
            .font(compact ? .callout : .title3)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Palette.tile : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Colors taken from the reference screenshot, with dark-mode counterparts. Surfaces are
/// translucent so the glass behind them shows through.
enum Palette {
    /// Laid over the blur: decides how light or dark the glass is.
    static let glassTint = Color(light: 0xF7F7F5, dark: 0x18181A, lightAlpha: 0.62, darkAlpha: 0.66)
    /// Cards on the glass.
    static let card = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.66, darkAlpha: 0.06)
    static let hairline = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    /// Chips, bar tracks and empty heatmap days.
    static let tile = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.09)
    static let heat: [Color] = [
        tile,
        Color(light: 0x8FADE8, dark: 0x2F4C7E),
        Color(light: 0x6E95E0, dark: 0x3D66AE),
        Color(light: 0x4F7DD9, dark: 0x5583D6),
        Color(light: 0x3463CF, dark: 0x7EA6F0),
    ]
    static let input = Color(light: 0x4F7DD9, dark: 0x6E95E0)
    static let output = Color(light: 0xE08A3C, dark: 0xF0A060)
    static let cache = Color(light: 0xB8C4D6, dark: 0x4A5568)
    /// Warnings in text: darker than system orange in light mode so it reads on the glass.
    static let warning = Color(light: 0xB45309, dark: 0xF5A524)
}

extension Color {
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}

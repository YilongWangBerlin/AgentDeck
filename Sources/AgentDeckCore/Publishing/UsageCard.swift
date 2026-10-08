import Foundation

/// Renders the published stats as an SVG card for a GitHub profile README: the six stat cards and the
/// weekly heatmap. GitHub serves README images through a sanitizing proxy, so the SVG has no scripts,
/// no `<style>` block, no external fonts or images and no links: only shapes and text with inline
/// presentation attributes, in the system font stack.
public enum UsageCard {
    public enum Theme: String, CaseIterable, Sendable {
        case light, dark

        var palette: Palette {
            switch self {
            case .light:
                Palette(background: "#ffffff", border: "#e6e4df", tile: "#f1efea", ink: "#1d1d1f", muted: "#6a6c72",
                        heat: ["#ebe9e4", "#f2dcb2", "#e3b867", "#cc9134", "#a8691a"])
            case .dark:
                Palette(background: "#0d1117", border: "#30363d", tile: "#161b22", ink: "#e6edf3", muted: "#8b949e",
                        heat: ["#21262d", "#4a3c22", "#7a5a24", "#ad7c2c", "#e0a540"])
            }
        }
    }

    struct Palette {
        var background, border, tile, ink, muted: String
        var heat: [String]
    }

    static let font = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
    static let width = 840

    public static func svg(_ export: PublicExport, theme: Theme, range: String = "all", source: String = "all") -> String {
        let palette = theme.palette
        let stats = export.summaries[range]?[source]
        var body: [String] = []
        let pad = 24

        body.append(text("Coding agent usage", x: pad, y: 40, size: 18, weight: 600, fill: palette.ink))
        body.append(text("Updated \(export.generatedOn) · AgentDeck", x: width - pad, y: 40, size: 12, fill: palette.muted, anchor: "end"))

        // Stat tiles, 3 × 2.
        let tileWidth = (width - 2 * pad - 2 * 8) / 3, tileHeight = 54
        let cards: [(String, String, Bool)] = [
            ("Sessions", stats.map { number($0.sessions) } ?? "–", true),
            ("Messages", stats.map { number($0.messages) } ?? "–", true),
            ("Total tokens", stats.map { Formatting.compactTokens($0.tokens.total) } ?? "–", true),
            ("Active days", stats.map { number($0.activeDays) } ?? "–", true),
            ("Peak hour", stats?.peakHour.map(DashboardData.hourLabel) ?? "–", true),
            ("Favorite model", stats?.favoriteModel.map(DashboardData.displayName) ?? "–", false),
        ]
        for (index, card) in cards.enumerated() {
            let x = pad + (index % 3) * (tileWidth + 8), y = 60 + (index / 3) * (tileHeight + 8)
            body.append(#"<rect x="\#(x)" y="\#(y)" width="\#(tileWidth)" height="\#(tileHeight)" rx="8" fill="\#(palette.tile)"/>"#)
            body.append(text(card.0, x: x + 12, y: y + 21, size: 12, fill: palette.muted))
            body.append(text(card.1, x: x + 12, y: y + 43, size: 17, weight: card.2 ? 700 : 400, fill: palette.ink))
        }

        // Heatmap: weeks as columns, Sunday first, ending with the current week.
        let cells = heatmap(export, source: source)
        let cell = 12, gap = 3, top = 60 + 2 * tileHeight + 8 + 18
        for (week, column) in cells.enumerated() {
            for (row, level) in column.enumerated() {
                guard let level else { continue }
                let x = pad + week * (cell + gap), y = top + row * (cell + gap)
                body.append(#"<rect x="\#(x)" y="\#(y)" width="\#(cell)" height="\#(cell)" rx="3" fill="\#(palette.heat[level])"/>"#)
            }
        }
        let height = top + 7 * (cell + gap) - gap + pad

        let label = "Coding agent usage: " + (stats.map { "\(number($0.sessions)) sessions, \(Formatting.compactTokens($0.tokens.total)) tokens over \(number($0.activeDays)) active days" } ?? "no data")
        return """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)" role="img" aria-label="\(escape(label))">
            <title>\(escape(label))</title>
            <rect x="0.5" y="0.5" width="\(width - 1)" height="\(height - 1)" rx="12" fill="\(palette.background)" stroke="\(palette.border)"/>
            \(body.joined(separator: "\n"))
            </svg>

            """
    }

    /// Levels 0…4 per day, nil after today. Same quantile rule as the dashboard.
    static func heatmap(_ export: PublicExport, source: String, minimumWeeks: Int = 26) -> [[Int?]] {
        let utc = LocalCalendar(timeZone: TimeZone(identifier: "UTC")!)
        func day(_ text: String) -> LocalDay? {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? LocalDay(year: parts[0], month: parts[1], day: parts[2]) : nil
        }
        guard let today = day(export.generatedOn) else { return [] }
        var totals: [LocalDay: Int] = [:]
        for row in export.daily where source == "all" || row.source == source {
            if let date = day(row.date) { totals[date, default: 0] += row.tokens.total }
        }
        let thresholds = DashboardData.quantileThresholds(totals.values.filter { $0 > 0 })
        func weekStart(_ day: LocalDay) -> LocalDay { utc.adding(days: -(utc.weekday(of: day) - 1), to: day) }
        let current = weekStart(today)
        let earliest = weekStart(totals.keys.min() ?? today)
        let weeks = max(minimumWeeks, utc.days(from: earliest, to: current) / 7 + 1)
        let first = utc.adding(days: -7 * (weeks - 1), to: current)
        return (0..<weeks).map { week in
            (0..<7).map { weekday in
                let date = utc.adding(days: week * 7 + weekday, to: first)
                return date > today ? nil : DashboardData.level(totals[date] ?? 0, thresholds: thresholds)
            }
        }
    }

    private static func text(_ content: String, x: Int, y: Int, size: Int, weight: Int = 400, fill: String, anchor: String = "start") -> String {
        #"<text x="\#(x)" y="\#(y)" font-family="\#(font)" font-size="\#(size)" font-weight="\#(weight)" fill="\#(fill)" text-anchor="\#(anchor)">\#(escape(content))</text>"#
    }

    private static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

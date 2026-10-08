@testable import AgentDeckCore
import AgentDeckParsing
import Foundation
import Testing

@Suite struct UsageCardTests {
    private var export: PublicExport {
        let records = [
            UsageRecord(source: .claudeCode, messageID: "a", sessionID: "s", timestamp: date("2026-10-07T10:00:00Z"),
                        model: "claude-opus-5-5", tokens: TokenCounts(input: 1_000_000)),
            UsageRecord(source: .codex, messageID: "b", sessionID: "t", timestamp: date("2026-09-01T10:00:00Z"),
                        model: "gpt <&> \"x\"", tokens: TokenCounts(input: 5)),
        ]
        return PublicExporter.build(records: records, options: PublicExportOptions(), now: date("2026-10-08T10:00:00Z"),
                                    calendar: LocalCalendar(timeZone: TimeZone(identifier: "Europe/Berlin")!))
    }

    @Test(arguments: UsageCard.Theme.allCases)
    func survivesGitHubSanitization(theme: UsageCard.Theme) throws {
        let svg = UsageCard.svg(export, theme: theme)
        for forbidden in ["<script", "<style", "@import", "href", "url(", "<image", "<foreignObject", "onload", "javascript:"] {
            #expect(!svg.lowercased().contains(forbidden.lowercased()), "\(forbidden) in \(theme) card")
        }
        // Well-formed XML, so escaping held up.
        let parser = XMLParser(data: Data(svg.utf8))
        #expect(parser.parse(), "\(parser.parserError.map { "\($0)" } ?? "")")
    }

    @Test func showsTheStatsAndDiffersByTheme() {
        let light = UsageCard.svg(export, theme: .light)
        #expect(light.contains(">1M<") && light.contains(">Opus 5.5<") && light.contains(">Sessions<"))
        #expect(light.contains("Updated 2026-10-08"))
        #expect(light != UsageCard.svg(export, theme: .dark))
    }

    @Test func heatmapEndsWithTodayInTheLastColumn() {
        let weeks = UsageCard.heatmap(export, source: "all")
        #expect(weeks.count == 26)
        // 2026-10-08 is a Thursday: Sunday…Thursday drawn, Friday and Saturday not.
        #expect(weeks.last?.map { $0 != nil } == [true, true, true, true, true, false, false])
        // With two active days the busiest one sits on the 75th percentile: level 3 by the shared rule.
        #expect(weeks.last?[3] == 3)
    }
}

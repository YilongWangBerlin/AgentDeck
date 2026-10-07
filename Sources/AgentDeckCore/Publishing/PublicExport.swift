import AgentDeckParsing
import Foundation

/// What the user chose to publish. Everything else is never exported.
public struct PublicExportOptions: Codable, Equatable, Sendable {
    public var includeClaudeCode = true
    public var includeCodex = true
    /// When false, rows are summed per tool and no model name appears anywhere.
    public var includeModelNames = true

    public init(includeClaudeCode: Bool = true, includeCodex: Bool = true, includeModelNames: Bool = true) {
        self.includeClaudeCode = includeClaudeCode
        self.includeCodex = includeCodex
        self.includeModelNames = includeModelNames
    }
}

/// The public JSON (`agentdeck.usage/v1`). Aggregates only: no paths, project or repository names,
/// session or message IDs, prompts, or message content. `PublicExportTests` fails if a field outside
/// this schema appears, so any addition is a deliberate schema change.
public struct PublicExport: Codable, Equatable, Sendable {
    public static let schemaID = "agentdeck.usage/v1"

    public struct Tokens: Codable, Equatable, Sendable {
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int
        public var total: Int

        init(_ counts: TokenCounts) {
            input = counts.input
            output = counts.output
            cacheRead = counts.cacheRead
            cacheWrite = counts.cacheWrite
            total = counts.total
        }
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var sessions: Int
        public var messages: Int
        public var tokens: Tokens
        public var activeDays: Int
        /// Local hour 0–23.
        public var peakHour: Int?
        public var favoriteModel: String?
    }

    /// One local day for one tool (and model, when names are published).
    public struct Day: Codable, Equatable, Sendable {
        /// `YYYY-MM-DD` in the publisher's time zone.
        public var date: String
        public var source: String
        public var model: String?
        public var messages: Int
        public var tokens: Tokens
    }

    public var schema: String
    /// UTC, ISO 8601, to the minute.
    public var generatedAt: String
    /// The publisher's local date at generation (`YYYY-MM-DD`), so pages can place "today" without
    /// knowing the time zone.
    public var generatedOn: String
    public var sources: [String]
    /// Range (`all`, `30d`, `7d`) → tool filter (`all`, `claude_code`, `codex`) → stat cards.
    /// Precomputed because sessions cannot be summed across days.
    public var summaries: [String: [String: Summary]]
    public var daily: [Day]
}

public enum PublicExporter {
    public static func export(
        store: UsageStore, options: PublicExportOptions, now: Date = Date(), calendar: LocalCalendar = LocalCalendar()
    ) throws -> PublicExport {
        build(records: try store.usage(), options: options, now: now, calendar: calendar)
    }

    public static func build(
        records: [UsageRecord], options: PublicExportOptions, now: Date, calendar: LocalCalendar
    ) -> PublicExport {
        var sources: [UsageSource] = []
        if options.includeClaudeCode { sources.append(.claudeCode) }
        if options.includeCodex { sources.append(.codex) }
        let included = records.filter { sources.contains($0.source) && $0.timestamp <= now }

        var summaries: [String: [String: PublicExport.Summary]] = [:]
        for range in DashboardRange.allCases {
            let interval = range.interval(now: now, calendar: calendar)
            let inRange = interval.map { window in included.filter { window.contains($0.timestamp) } } ?? included
            var bySource: [String: PublicExport.Summary] = ["all": summary(inRange, options: options, calendar: calendar)]
            for source in sources {
                bySource[source.rawValue] = summary(inRange.filter { $0.source == source }, options: options, calendar: calendar)
            }
            summaries[range.rawValue] = bySource
        }

        struct DayKey: Hashable { var day: LocalDay; var source: UsageSource; var model: String? }
        var days: [DayKey: (messages: Int, tokens: TokenCounts)] = [:]
        for record in included {
            let key = DayKey(day: calendar.day(containing: record.timestamp), source: record.source,
                             model: options.includeModelNames ? record.model : nil)
            days[key, default: (0, TokenCounts())].messages += 1
            days[key]!.tokens += record.tokens
        }
        let daily = days.map { key, value in
            PublicExport.Day(date: key.day.description, source: key.source.rawValue, model: key.model,
                             messages: value.messages, tokens: .init(value.tokens))
        }.sorted { ($0.date, $0.source, $0.model ?? "") < ($1.date, $1.source, $1.model ?? "") }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let generatedAt = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)

        return PublicExport(
            schema: PublicExport.schemaID,
            generatedAt: formatter.string(from: generatedAt),
            generatedOn: calendar.day(containing: now).description,
            sources: sources.map(\.rawValue),
            summaries: summaries,
            daily: daily
        )
    }

    private static func summary(_ records: [UsageRecord], options: PublicExportOptions, calendar: LocalCalendar) -> PublicExport.Summary {
        let stats = DashboardData.stats(records, calendar: calendar)
        return PublicExport.Summary(
            sessions: stats.sessions,
            messages: stats.messages,
            tokens: .init(stats.tokens),
            activeDays: stats.activeDays,
            peakHour: stats.peakHour,
            favoriteModel: options.includeModelNames ? stats.favoriteModel : nil
        )
    }

    /// Pretty-printed, sorted keys, snake_case: stable output, so an unchanged export gives no diff.
    public static func encode(_ export: PublicExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(export)
    }
}

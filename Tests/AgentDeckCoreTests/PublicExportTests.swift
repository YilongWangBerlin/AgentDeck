@testable import AgentDeckCore
import AgentDeckParsing
import Foundation
import Testing

@Suite struct PublicExportTests {
    let berlin = LocalCalendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    let now = date("2026-10-08T10:00:00Z")

    /// Every key the v1 schema may contain. A new field fails this test until it is reviewed and added.
    static let allowedKeys: Set<String> = [
        "schema", "generated_at", "sources", "summaries", "daily",
        "all", "30d", "7d", "claude_code", "codex",
        "sessions", "messages", "tokens", "active_days", "peak_hour", "favorite_model",
        "input", "output", "cache_read", "cache_write", "total",
        "date", "source", "model",
    ]

    /// Rows carrying the kinds of private data that must never be published.
    private var records: [UsageRecord] {
        [
            UsageRecord(source: .claudeCode, messageID: "msg_SECRET_1:req_SECRET_1",
                        sessionID: "11111111-SECRET-SESSION", timestamp: date("2026-10-07T21:00:00Z"),
                        model: "claude-opus-5-5", tokens: TokenCounts(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, reasoning: 1)),
            UsageRecord(source: .codex, messageID: "resp_SECRET_2", sessionID: "/Users/someone/Desktop/SECRET-PROJECT",
                        timestamp: date("2026-09-01T12:00:00Z"), model: "gpt-6.1-sol", tokens: TokenCounts(input: 10)),
        ]
    }

    private func json(_ options: PublicExportOptions) throws -> (text: String, object: Any) {
        let data = try PublicExporter.encode(PublicExporter.build(records: records, options: options, now: now, calendar: berlin))
        return (String(decoding: data, as: UTF8.self), try JSONSerialization.jsonObject(with: data))
    }

    private func keys(in object: Any) -> Set<String> {
        if let dictionary = object as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) { $0.formUnion(keys(in: $1.value)) }
        }
        if let array = object as? [Any] {
            return array.reduce(into: []) { $0.formUnion(keys(in: $1)) }
        }
        return []
    }

    @Test func onlySchemaFieldsAppear() throws {
        let (_, object) = try json(PublicExportOptions())
        let unexpected = keys(in: object).subtracting(Self.allowedKeys)
        #expect(unexpected.isEmpty, "Fields outside the public schema: \(unexpected.sorted())")
    }

    @Test func noIdentifiersPathsOrContentLeak() throws {
        let (text, _) = try json(PublicExportOptions())
        for forbidden in ["SECRET", "/Users", "Desktop", "msg_", "req_", "resp_", "session_id", "message_id", "cwd", "path", "prompt"] {
            #expect(!text.contains(forbidden), "export contains \(forbidden)")
        }
    }

    @Test func aggregatesAreCorrect() throws {
        let export = PublicExporter.build(records: records, options: PublicExportOptions(), now: now, calendar: berlin)
        #expect(export.schema == "agentdeck.usage/v1")
        #expect(export.generatedAt == "2026-10-08T10:00:00Z")
        #expect(export.summaries["all"]?["all"]?.sessions == 2)
        #expect(export.summaries["all"]?["all"]?.tokens.total == 20)
        #expect(export.summaries["7d"]?["codex"]?.messages == 0)
        #expect(export.summaries["7d"]?["claude_code"]?.favoriteModel == "claude-opus-5-5")
        // 21:00 UTC on Oct 7 is Oct 7 23:00 in Berlin.
        #expect(export.daily.map(\.date) == ["2026-09-01", "2026-10-07"])
    }

    @Test func toggledOffDataIsAbsent() throws {
        let (noCodex, _) = try json(PublicExportOptions(includeCodex: false))
        #expect(!noCodex.contains("codex") && !noCodex.contains("gpt-"))

        let (noModels, _) = try json(PublicExportOptions(includeModelNames: false))
        #expect(!noModels.contains("claude-opus") && !noModels.contains("gpt-"))
        #expect(!noModels.contains("favorite_model") && !noModels.contains("\"model\""))
    }

    @Test func encodingIsStable() throws {
        let export = PublicExporter.build(records: records, options: PublicExportOptions(), now: now, calendar: berlin)
        #expect(try PublicExporter.encode(export) == PublicExporter.encode(export))
        #expect(try JSONDecoder.snakeCase.decode(PublicExport.self, from: PublicExporter.encode(export)) == export)
    }
}

extension JSONDecoder {
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

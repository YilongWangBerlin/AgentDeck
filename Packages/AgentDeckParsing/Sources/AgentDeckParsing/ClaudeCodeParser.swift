import Foundation

/// Parses Claude Code transcripts (`~/.claude/projects/**/*.jsonl`). See FORMATS.md section 1.
///
/// Parsing a line needs no context from earlier lines, so the parser keeps no per-file state.
public struct ClaudeCodeParser: Sendable {
    public init() {}

    public func parse(fileAt url: URL, from offset: UInt64 = 0) throws -> ParseResult {
        let chunk = try JSONLReader.readCompleteLines(from: url, startingAt: offset)
        var result = parse(lines: chunk.lines)
        result.endOffset = chunk.endOffset
        return result
    }

    func parse(lines: [Data]) -> ParseResult {
        var result = ParseResult()
        var usageByKey: [String: UsageRecord] = [:]
        var keyOrder: [String] = []
        let decoder = JSONDecoder()

        for line in lines {
            guard let entry = try? decoder.decode(Entry.self, from: line) else {
                result.malformedLineCount += 1
                continue
            }
            switch entry.type {
            case "assistant":
                if let observation = rateLimit(from: entry) {
                    result.rateLimits.append(observation)
                }
                if let record = usage(from: entry) {
                    if let existing = usageByKey[record.messageID] {
                        usageByKey[record.messageID] = existing.merged(with: record)
                    } else {
                        usageByKey[record.messageID] = record
                        keyOrder.append(record.messageID)
                    }
                }
            case "user":
                if let prompt = prompt(from: entry) {
                    result.prompts.append(prompt)
                }
            default:
                break
            }
        }
        result.usage = keyOrder.compactMap { usageByKey[$0] }
        return result
    }

    /// One line per content block shares `message.id` and `requestId`; the caller merges them.
    private func usage(from entry: Entry) -> UsageRecord? {
        guard let message = entry.message,
              let model = message.model, model != "<synthetic>",
              let id = message.id,
              let usage = message.usage,
              let sessionID = entry.sessionId,
              let timestamp = entry.timestamp.flatMap(Timestamp.parse)
        else { return nil }
        let key = entry.requestId.map { "\(id):\($0)" } ?? id
        return UsageRecord(
            source: .claudeCode,
            messageID: key,
            sessionID: sessionID,
            timestamp: timestamp,
            model: model,
            tokens: TokenCounts(
                input: usage.input,
                output: usage.output,
                cacheRead: usage.cacheRead,
                cacheWrite: usage.cacheWrite,
                reasoning: usage.thinking
            )
        )
    }

    /// Claude Code writes `quotaLimits` only on the synthetic line it adds when a request is refused.
    private func rateLimit(from entry: Entry) -> RateLimitObservation? {
        guard let quota = entry.quotaLimits,
              let resetsAt = quota.resetsAt,
              let observedAt = entry.timestamp.flatMap(Timestamp.parse)
        else { return nil }
        return RateLimitObservation(
            source: .claudeCode,
            observedAt: observedAt,
            windowMinutes: quota.rateLimitType == "five_hour" ? 300 : nil,
            usedPercent: nil,
            resetsAt: Date(timeIntervalSince1970: resetsAt),
            limitType: quota.rateLimitType,
            isRejection: quota.status == "rejected"
        )
    }

    /// A prompt the user typed: not a tool result, not injected metadata, not a subagent's input,
    /// and not a system notification.
    private func prompt(from entry: Entry) -> PromptEvent? {
        guard entry.isSidechain != true,
              entry.isMeta != true,
              !entry.hasToolUseResult,
              entry.originKind == nil || entry.originKind == "human",
              let content = entry.message?.content, !content.containsToolResult,
              let id = entry.uuid,
              let sessionID = entry.sessionId,
              let timestamp = entry.timestamp.flatMap(Timestamp.parse)
        else { return nil }
        return PromptEvent(source: .claudeCode, id: id, sessionID: sessionID, timestamp: timestamp)
    }
}

// MARK: - Line shapes

private struct Entry: Decodable {
    var type: String?
    var timestamp: String?
    var sessionId: String?
    var requestId: String?
    var uuid: String?
    var isSidechain: Bool?
    var isMeta: Bool?
    var hasToolUseResult: Bool
    var originKind: String?
    var message: Message?
    var quotaLimits: QuotaLimits?

    private enum CodingKeys: String, CodingKey {
        case type, timestamp, sessionId, requestId, uuid, isSidechain, isMeta, toolUseResult, origin, message, quotaLimits
    }

    private struct Origin: Decodable { var kind: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        timestamp = c.lenient(String.self, .timestamp)
        sessionId = c.lenient(String.self, .sessionId)
        requestId = c.lenient(String.self, .requestId)
        uuid = c.lenient(String.self, .uuid)
        isSidechain = c.lenient(Bool.self, .isSidechain)
        isMeta = c.lenient(Bool.self, .isMeta)
        hasToolUseResult = c.hasNonNullValue(.toolUseResult)
        originKind = c.lenient(Origin.self, .origin)?.kind
        message = c.lenient(Message.self, .message)
        quotaLimits = c.lenient(QuotaLimits.self, .quotaLimits)
    }
}

private struct Message: Decodable {
    var id: String?
    var model: String?
    var usage: Usage?
    var content: Content?

    private enum CodingKeys: String, CodingKey { case id, model, usage, content }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id)
        model = c.lenient(String.self, .model)
        usage = c.lenient(Usage.self, .usage)
        content = c.lenient(Content.self, .content)
    }
}

/// `message.content` is a plain string for typed prompts and an array of typed blocks otherwise.
private enum Content: Decodable {
    case text
    case blocks([String])

    private struct Block: Decodable { var type: String? }

    var containsToolResult: Bool {
        if case .blocks(let types) = self { return types.contains("tool_result") }
        return false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if (try? container.decode(String.self)) != nil {
            self = .text
        } else {
            self = .blocks(try container.decode([Block].self).map { $0.type ?? "" })
        }
    }
}

private struct Usage: Decodable {
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var thinking: Int

    private enum CodingKeys: String, CodingKey {
        case input = "input_tokens"
        case output = "output_tokens"
        case cacheRead = "cache_read_input_tokens"
        case cacheWrite = "cache_creation_input_tokens"
        case details = "output_tokens_details"
    }

    private struct Details: Decodable {
        var thinking_tokens: Int?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = c.lenient(Int.self, .input) ?? 0
        output = c.lenient(Int.self, .output) ?? 0
        cacheRead = c.lenient(Int.self, .cacheRead) ?? 0
        cacheWrite = c.lenient(Int.self, .cacheWrite) ?? 0
        thinking = c.lenient(Details.self, .details)?.thinking_tokens ?? 0
    }
}

private struct QuotaLimits: Decodable {
    var status: String?
    var resetsAt: Double?
    var rateLimitType: String?

    private enum CodingKeys: String, CodingKey { case status, resetsAt, rateLimitType }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lenient(String.self, .status)
        resetsAt = c.lenient(Double.self, .resetsAt)
        rateLimitType = c.lenient(String.self, .rateLimitType)
    }
}

import Foundation

/// What the Codex parser remembers about a file between incremental passes. The store saves it as
/// JSON next to the file's byte offset. Its contents are internal to the parser.
public struct CodexFileState: Codable, Equatable, Sendable {
    struct TurnModel: Codable, Equatable, Sendable {
        var turnID: String
        var model: String
    }

    static let rememberedTurns = 64

    /// The rollout's own thread id, taken from the file name or its `session_meta`.
    public internal(set) var threadID: String?
    /// The parent thread for subagents, otherwise the thread itself. Used for fallback rows only;
    /// `token_usage_record` carries its own `session_id`.
    var rootSessionID: String?
    var currentModel: String?
    /// Newest last, at most `rememberedTurns` entries.
    var recentTurnModels: [TurnModel] = []
    var sawTokenUsageRecord = false
    var sawTurnContext = false
    /// Fallback rows were returned by an earlier pass and may now be in the store.
    var emittedFallback = false
    var lastFallbackTotal: CodexUsage?
    var isImported = false

    public init() {}

    mutating func remember(turnID: String, model: String) {
        recentTurnModels.removeAll { $0.turnID == turnID }
        recentTurnModels.append(TurnModel(turnID: turnID, model: model))
        if recentTurnModels.count > Self.rememberedTurns {
            recentTurnModels.removeFirst(recentTurnModels.count - Self.rememberedTurns)
        }
    }

    func model(forTurn turnID: String?) -> String? {
        guard let turnID else { return nil }
        return recentTurnModels.last { $0.turnID == turnID }?.model
    }
}

/// Parses Codex rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`). See FORMATS.md section 2.
///
/// Usage comes from `token_usage_record` lines, one per API response. A file without them falls back
/// to `token_count.last_token_usage`. If a record later appears in that file, the parser asks the
/// caller to retract the fallback rows.
public struct CodexParser: Sendable {
    /// Threads Codex Desktop imported from other agents (`external_agent_session_imports.json`).
    /// Their usage already appears in the other agent's logs.
    public var importedThreadIDs: Set<String>

    public init(importedThreadIDs: Set<String> = []) {
        self.importedThreadIDs = importedThreadIDs
    }

    public func parse(fileAt url: URL, from offset: UInt64 = 0, state: inout CodexFileState) throws -> ParseResult {
        if state.threadID == nil {
            state.threadID = Self.threadID(fromFileName: url.lastPathComponent)
        }
        markImportedIfListed(&state)
        let chunk = try JSONLReader.readCompleteLines(from: url, startingAt: offset)
        var result = state.isImported ? ParseResult() : parse(lines: chunk.lines, state: &state)
        result.endOffset = chunk.endOffset
        return result
    }

    func parse(lines: [Data], state: inout CodexFileState) -> ParseResult {
        var result = ParseResult()
        let decoder = JSONDecoder()

        for line in lines {
            if CodexLineSniffer.canSkip(line) { continue }
            guard let entry = try? decoder.decode(Entry.self, from: line) else {
                result.malformedLineCount += 1
                continue
            }
            guard let payload = entry.payload else { continue }

            switch entry.type {
            case "session_meta":
                readSessionMeta(payload, state: &state)
                if state.isImported { return ParseResult() }

            case "turn_context":
                state.sawTurnContext = true
                if let model = payload.model, !model.isEmpty {
                    state.currentModel = model
                    if let turnID = payload.turnID {
                        state.remember(turnID: turnID, model: model)
                    }
                }

            case "token_usage_record":
                guard let responseID = payload.responseID,
                      let usage = payload.usage,
                      let timestamp = entry.timestamp.flatMap(Timestamp.parse)
                else { continue }
                if !state.sawTokenUsageRecord {
                    state.sawTokenUsageRecord = true
                    if state.emittedFallback || result.usage.contains(where: { $0.kind == .codexTokenCountFallback }) {
                        result.retractFallbackUsage = true
                        result.usage.removeAll { $0.kind == .codexTokenCountFallback }
                        state.emittedFallback = false
                    }
                }
                result.usage.append(UsageRecord(
                    source: .codex,
                    messageID: responseID,
                    sessionID: payload.sessionID ?? sessionFallback(state),
                    timestamp: timestamp,
                    model: state.model(forTurn: payload.turnID) ?? state.currentModel ?? UsageRecord.unknownModel,
                    tokens: usage.normalized
                ))

            case "event_msg" where payload.type == "token_count":
                guard let timestamp = entry.timestamp.flatMap(Timestamp.parse) else { continue }
                if let limits = payload.rateLimits {
                    result.rateLimits += observations(from: limits, at: timestamp)
                }
                if let record = fallbackUsage(from: payload, at: timestamp, state: &state) {
                    result.usage.append(record)
                }

            default:
                break
            }
        }
        if result.usage.contains(where: { $0.kind == .codexTokenCountFallback }) {
            state.emittedFallback = true
        }
        return result
    }

    // MARK: - Pieces

    private func markImportedIfListed(_ state: inout CodexFileState) {
        if let threadID = state.threadID, importedThreadIDs.contains(threadID) {
            state.isImported = true
        }
    }

    private func readSessionMeta(_ payload: Payload, state: inout CodexFileState) {
        guard let id = payload.id else { return }
        if state.threadID == nil {
            state.threadID = id
        }
        // A forked file can begin with its parent's metadata; only the file's own entry counts.
        if id == state.threadID, state.rootSessionID == nil {
            state.rootSessionID = payload.parentThreadID ?? payload.source?.parentThreadID ?? id
        }
        markImportedIfListed(&state)
    }

    private func sessionFallback(_ state: CodexFileState) -> String {
        state.rootSessionID ?? state.threadID ?? "unknown"
    }

    /// Only for files without `token_usage_record`. Imported copies of other agents' sessions carry a
    /// synthetic `token_count` with no `rate_limits` and have no `turn_context`, so they never qualify.
    private func fallbackUsage(from payload: Payload, at timestamp: Date, state: inout CodexFileState) -> UsageRecord? {
        guard !state.sawTokenUsageRecord,
              state.sawTurnContext || payload.rateLimits != nil,
              let total = payload.info?.total,
              let last = payload.info?.last,
              last.totalTokens > 0,
              total != state.lastFallbackTotal
        else { return nil }
        state.lastFallbackTotal = total

        let threadID = state.threadID ?? "unknown"
        let fingerprint = "\(timestamp.timeIntervalSince1970)|\(last.input)|\(last.cached)|\(last.cacheWrite)|\(last.output)|\(last.reasoning)|\(last.totalTokens)"
        return UsageRecord(
            source: .codex,
            messageID: "\(threadID):tc:\(StableHash.fnv1a64(fingerprint))",
            sessionID: sessionFallback(state),
            timestamp: timestamp,
            model: state.currentModel ?? UsageRecord.unknownModel,
            tokens: last.normalized,
            kind: .codexTokenCountFallback
        )
    }

    private func observations(from limits: RateLimits, at timestamp: Date) -> [RateLimitObservation] {
        [limits.primary, limits.secondary].compactMap { window in
            guard let window, let resetsAt = window.resetsAt else { return nil }
            return RateLimitObservation(
                source: .codex,
                observedAt: timestamp,
                windowMinutes: window.windowMinutes,
                usedPercent: window.usedPercent,
                resetsAt: Date(timeIntervalSince1970: resetsAt),
                limitID: limits.limitID,
                planType: limits.planType,
                isRejection: limits.limitReached
            )
        }
    }

    /// `rollout-2026-10-07T01-02-43-<uuid>.jsonl` → `<uuid>`.
    static func threadID(fromFileName name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = name.dropLast(".jsonl".count)
        guard stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        return UUID(uuidString: candidate) == nil ? nil : candidate
    }
}

// MARK: - Line shapes

struct CodexUsage: Codable, Equatable, Sendable {
    var input: Int
    var cached: Int
    var cacheWrite: Int
    var output: Int
    var reasoning: Int
    var totalTokens: Int

    private enum CodingKeys: String, CodingKey {
        case input = "input_tokens"
        case cached = "cached_input_tokens"
        case cacheWrite = "cache_write_input_tokens"
        case output = "output_tokens"
        case reasoning = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = c.lenient(Int.self, .input) ?? 0
        cached = c.lenient(Int.self, .cached) ?? 0
        cacheWrite = c.lenient(Int.self, .cacheWrite) ?? 0
        output = c.lenient(Int.self, .output) ?? 0
        reasoning = c.lenient(Int.self, .reasoning) ?? 0
        totalTokens = c.lenient(Int.self, .totalTokens) ?? 0
    }

    /// OpenAI's `input_tokens` includes cached tokens. Subtracting them makes `input` mean
    /// non-cached input, as it does for Claude.
    var normalized: TokenCounts {
        TokenCounts(
            input: max(0, input - cached),
            output: output,
            cacheRead: cached,
            cacheWrite: cacheWrite,
            reasoning: reasoning
        )
    }
}

private struct Entry: Decodable {
    var timestamp: String?
    var type: String?
    var payload: Payload?

    private enum CodingKeys: String, CodingKey { case timestamp, type, payload }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = c.lenient(String.self, .timestamp)
        type = c.lenient(String.self, .type)
        payload = c.lenient(Payload.self, .payload)
    }
}

/// The fields we read from every payload type, all optional.
private struct Payload: Decodable {
    var type: String?
    var id: String?
    var parentThreadID: String?
    var source: SessionSource?
    var turnID: String?
    var model: String?
    var responseID: String?
    var sessionID: String?
    var usage: CodexUsage?
    var info: Info?
    var rateLimits: RateLimits?

    private enum CodingKeys: String, CodingKey {
        case type, id, source, model, usage, info
        case parentThreadID = "parent_thread_id"
        case turnID = "turn_id"
        case responseID = "response_id"
        case sessionID = "session_id"
        case rateLimits = "rate_limits"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        id = c.lenient(String.self, .id)
        parentThreadID = c.lenient(String.self, .parentThreadID)
        source = c.lenient(SessionSource.self, .source)
        turnID = c.lenient(String.self, .turnID)
        model = c.lenient(String.self, .model)
        responseID = c.lenient(String.self, .responseID)
        sessionID = c.lenient(String.self, .sessionID)
        usage = c.lenient(CodexUsage.self, .usage)
        info = c.lenient(Info.self, .info)
        rateLimits = c.lenient(RateLimits.self, .rateLimits)
    }
}

/// `"vscode"`, `{"subagent": {"other": "guardian"}}`, or
/// `{"subagent": {"thread_spawn": {"parent_thread_id": …}}}`.
private struct SessionSource: Decodable {
    var parentThreadID: String?

    private enum Key: String, CodingKey {
        case subagent
        case threadSpawn = "thread_spawn"
        case parentThreadID = "parent_thread_id"
    }

    init(from decoder: Decoder) throws {
        let source = try? decoder.container(keyedBy: Key.self)
        let subagent = try? source?.nestedContainer(keyedBy: Key.self, forKey: .subagent)
        let spawn = try? subagent?.nestedContainer(keyedBy: Key.self, forKey: .threadSpawn)
        parentThreadID = spawn?.lenient(String.self, .parentThreadID)
    }
}

private struct Info: Decodable {
    var total: CodexUsage?
    var last: CodexUsage?

    private enum CodingKeys: String, CodingKey {
        case total = "total_token_usage"
        case last = "last_token_usage"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = c.lenient(CodexUsage.self, .total)
        last = c.lenient(CodexUsage.self, .last)
    }
}

private struct RateLimits: Decodable {
    struct Window: Decodable {
        var usedPercent: Double?
        var windowMinutes: Int?
        var resetsAt: Double?

        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = c.lenient(Double.self, .usedPercent)
            windowMinutes = c.lenient(Int.self, .windowMinutes)
            resetsAt = c.lenient(Double.self, .resetsAt)
        }
    }

    var limitID: String?
    var planType: String?
    var primary: Window?
    var secondary: Window?
    var limitReached: Bool

    private enum CodingKeys: String, CodingKey {
        case primary, secondary
        case limitID = "limit_id"
        case planType = "plan_type"
        case limitReached = "rate_limit_reached_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limitID = c.lenient(String.self, .limitID)
        planType = c.lenient(String.self, .planType)
        primary = c.lenient(Window.self, .primary)
        secondary = c.lenient(Window.self, .secondary)
        limitReached = c.hasNonNullValue(.limitReached)
    }
}

/// Skips the large line types that never carry usage or limits, without decoding them.
/// Anything it cannot recognize is decoded normally.
enum CodexLineSniffer {
    private static let skippedTypes: Set<String> = [
        "response_item", "world_state", "compacted", "inter_agent_communication_metadata",
    ]
    private static let typeKey = Array(#""type":""#.utf8)
    private static let window = 512

    static func canSkip(_ line: Data) -> Bool {
        line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let limit = min(raw.count, window)
            guard let outer = stringValue(afterTypeKeyIn: raw, from: 0, limit: limit) else { return false }
            if skippedTypes.contains(outer.value) { return true }
            guard outer.value == "event_msg",
                  let inner = stringValue(afterTypeKeyIn: raw, from: outer.end, limit: limit)
            else { return false }
            return inner.value != "token_count"
        }
    }

    private static func stringValue(
        afterTypeKeyIn raw: UnsafeRawBufferPointer, from start: Int, limit: Int
    ) -> (value: String, end: Int)? {
        let key = typeKey
        var i = start
        while i + key.count <= limit {
            if raw[i] == key[0], (0..<key.count).allSatisfy({ raw[i + $0] == key[$0] }) {
                let valueStart = i + key.count
                var j = valueStart
                while j < limit, raw[j] != UInt8(ascii: "\"") { j += 1 }
                guard j < limit else { return nil }
                let bytes = UnsafeRawBufferPointer(rebasing: raw[valueStart..<j])
                return (String(decoding: bytes, as: UTF8.self), j + 1)
            }
            i += 1
        }
        return nil
    }
}

enum StableHash {
    /// 64-bit FNV-1a as 16 hex digits. Stable across runs and machines, unlike `Hasher`.
    static func fnv1a64(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

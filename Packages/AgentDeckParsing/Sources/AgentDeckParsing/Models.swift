import Foundation

/// The tool a record came from. Raw values are the identifiers stored in the database.
public enum UsageSource: String, Sendable, Codable, CaseIterable {
    case claudeCode = "claude_code"
    case codex = "codex"
}

/// Token counts for one model response, normalized so both tools mean the same thing.
public struct TokenCounts: Equatable, Hashable, Sendable, Codable {
    /// Input tokens not served from cache. Codex logs include cached tokens in `input_tokens`;
    /// the parser subtracts them.
    public var input: Int
    /// Output tokens, including reasoning.
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    /// Reasoning or thinking tokens. Already counted in `output`.
    public var reasoning: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    /// Everything processed for the response. `reasoning` is left out because `output` contains it.
    public var total: Int { input + output + cacheRead + cacheWrite }

    public func fieldwiseMax(_ other: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: max(input, other.input),
            output: max(output, other.output),
            cacheRead: max(cacheRead, other.cacheRead),
            cacheWrite: max(cacheWrite, other.cacheWrite),
            reasoning: max(reasoning, other.reasoning)
        )
    }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }
}

public enum UsageRecordKind: String, Sendable, Codable {
    /// One model response.
    case response
    /// Derived from a Codex `token_count` event in a file that has no `token_usage_record` lines.
    /// Retracted if such a record later appears in the same file.
    case codexTokenCountFallback = "codex_token_count_fallback"
}

/// One deduplicated model response.
public struct UsageRecord: Equatable, Sendable {
    /// Model name used when a Codex response cannot be matched to any `turn_context`.
    public static let unknownModel = "unknown"

    public var source: UsageSource
    /// Dedup key, unique within `source`: `message.id:requestId` for Claude Code,
    /// `response_id` for Codex.
    public var messageID: String
    public var sessionID: String
    public var timestamp: Date
    public var model: String
    public var tokens: TokenCounts
    public var kind: UsageRecordKind

    public init(
        source: UsageSource,
        messageID: String,
        sessionID: String,
        timestamp: Date,
        model: String,
        tokens: TokenCounts,
        kind: UsageRecordKind = .response
    ) {
        self.source = source
        self.messageID = messageID
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
        self.kind = kind
    }

    /// Combines two sightings of the same response: the largest value of each token field and the
    /// earliest timestamp. Claude Code writes one line per content block, and earlier lines can carry a
    /// partial `output_tokens`, so the maximum is the final value.
    public func merged(with other: UsageRecord) -> UsageRecord {
        var result = self
        result.tokens = tokens.fieldwiseMax(other.tokens)
        result.timestamp = min(timestamp, other.timestamp)
        return result
    }
}

/// A prompt typed by the user (Claude Code only). Used to place the start of a 5-hour window.
public struct PromptEvent: Equatable, Sendable {
    public var source: UsageSource
    public var id: String
    public var sessionID: String
    public var timestamp: Date

    public init(source: UsageSource, id: String, sessionID: String, timestamp: Date) {
        self.source = source
        self.id = id
        self.sessionID = sessionID
        self.timestamp = timestamp
    }
}

/// A rate-limit value read from a log line.
public struct RateLimitObservation: Equatable, Sendable {
    public var source: UsageSource
    public var observedAt: Date
    /// Window length in minutes when the log states it (Codex `window_minutes`, or Claude
    /// `rateLimitType == "five_hour"`). Nil for a Claude limit type that has not been seen before.
    public var windowMinutes: Int?
    /// Percent of the window used, 0–100. Only Codex reports it.
    public var usedPercent: Double?
    public var resetsAt: Date
    /// Codex `limit_id`, e.g. "codex".
    public var limitID: String?
    /// Codex `plan_type`, e.g. "plus".
    public var planType: String?
    /// Claude `rateLimitType`, e.g. "five_hour".
    public var limitType: String?
    /// True when the request was refused: a Claude 429, or Codex `rate_limit_reached_type` set.
    public var isRejection: Bool

    public init(
        source: UsageSource,
        observedAt: Date,
        windowMinutes: Int?,
        usedPercent: Double?,
        resetsAt: Date,
        limitID: String? = nil,
        planType: String? = nil,
        limitType: String? = nil,
        isRejection: Bool
    ) {
        self.source = source
        self.observedAt = observedAt
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.limitID = limitID
        self.planType = planType
        self.limitType = limitType
        self.isRejection = isRejection
    }
}

/// What one pass over a log file produced.
public struct ParseResult: Sendable {
    public var usage: [UsageRecord] = []
    public var prompts: [PromptEvent] = []
    public var rateLimits: [RateLimitObservation] = []
    /// Codex only. When true, discard every fallback row previously stored for this file before
    /// storing `usage`.
    public var retractFallbackUsage = false
    /// Byte offset just past the last complete line. The next pass starts here.
    public var endOffset: UInt64 = 0
    /// Lines that were not valid JSON.
    public var malformedLineCount = 0

    public init() {}
}

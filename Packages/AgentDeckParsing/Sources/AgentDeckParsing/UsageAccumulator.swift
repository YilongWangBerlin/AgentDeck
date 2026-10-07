import Foundation

/// Applies parse results with the dedup rules the store will use, in memory. Used by `adparse` and by
/// tests that check incremental parsing gives the same answer as a single pass.
public struct UsageAccumulator: Sendable {
    public struct Key: Hashable, Sendable {
        public var source: UsageSource
        public var messageID: String
    }

    public private(set) var records: [Key: UsageRecord] = [:]
    private var fallbackKeysByFile: [String: Set<Key>] = [:]

    public init() {}

    /// `fileKey` identifies the log file the result came from (its path is fine).
    public mutating func apply(_ result: ParseResult, fileKey: String) {
        if result.retractFallbackUsage {
            for key in fallbackKeysByFile.removeValue(forKey: fileKey) ?? [] {
                records.removeValue(forKey: key)
            }
        }
        for record in result.usage {
            let key = Key(source: record.source, messageID: record.messageID)
            records[key] = records[key].map { $0.merged(with: record) } ?? record
            if record.kind == .codexTokenCountFallback {
                fallbackKeysByFile[fileKey, default: []].insert(key)
            }
        }
    }

    public func totals(for source: UsageSource? = nil) -> TokenCounts {
        records.values
            .filter { source == nil || $0.source == source }
            .reduce(TokenCounts()) { $0 + $1.tokens }
    }
}

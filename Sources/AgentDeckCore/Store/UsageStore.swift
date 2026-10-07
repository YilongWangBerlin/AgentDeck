import AgentDeckParsing
import Foundation
import GRDB

/// What the store remembers about one log file between scans.
public struct LogFileRecord: Equatable, Sendable {
    public var id: Int64
    public var source: UsageSource
    public var path: String
    /// Next byte to read. Everything before it is in the store.
    public var byteOffset: UInt64
    /// Size, modification time and inode at the last scan; a change in any of them triggers a parse.
    public var fileSize: UInt64
    public var modifiedAt: Double?
    public var inode: UInt64?
    /// Parser state to resume from `byteOffset` (Codex only).
    public var parserState: Data?
    /// Codex rollouts only: the thread id, used to drop sessions later found to be imports.
    public var threadID: String?
    /// The file is gone from disk. Its usage stays in the store.
    public var isMissing: Bool
}

public struct StoreCounts: Equatable, Sendable {
    public var usage: Int
    public var prompts: Int
    public var rateLimits: Int
    public var logFiles: Int

    public init(usage: Int, prompts: Int, rateLimits: Int, logFiles: Int) {
        self.usage = usage
        self.prompts = prompts
        self.rateLimits = rateLimits
        self.logFiles = logFiles
    }
}

/// The SQLite store. Usage history is permanent: rows are never deleted because a log file disappeared,
/// since Claude Code removes old transcripts on its own schedule.
///
/// Timestamps are stored as UTC milliseconds since 1970. Local days are computed when reading
/// (see `LocalCalendar`), never stored.
public final class UsageStore: Sendable {
    let writer: any DatabaseWriter

    /// Opens (and creates or migrates) the database file at `url`.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(writer: DatabasePool(path: url.path))
    }

    public static func inMemory() throws -> UsageStore {
        try UsageStore(writer: DatabaseQueue())
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE log_file (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source TEXT NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    byte_offset INTEGER NOT NULL DEFAULT 0,
                    file_size INTEGER NOT NULL DEFAULT 0,
                    modified_at REAL,
                    inode INTEGER,
                    parser_state BLOB,
                    thread_id TEXT,
                    malformed_lines INTEGER NOT NULL DEFAULT 0,
                    missing INTEGER NOT NULL DEFAULT 0,
                    last_ingested_at REAL
                );
                CREATE INDEX log_file_thread ON log_file(thread_id) WHERE thread_id IS NOT NULL;

                CREATE TABLE usage (
                    source TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    model TEXT NOT NULL,
                    input INTEGER NOT NULL,
                    output INTEGER NOT NULL,
                    cache_read INTEGER NOT NULL,
                    cache_write INTEGER NOT NULL,
                    reasoning INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    file_id INTEGER REFERENCES log_file(id),
                    PRIMARY KEY (source, message_id)
                ) WITHOUT ROWID;
                CREATE INDEX usage_timestamp ON usage(timestamp);
                CREATE INDEX usage_file ON usage(file_id);

                CREATE TABLE prompt (
                    source TEXT NOT NULL,
                    id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    PRIMARY KEY (source, id)
                ) WITHOUT ROWID;
                CREATE INDEX prompt_timestamp ON prompt(timestamp);

                CREATE TABLE rate_limit (
                    source TEXT NOT NULL,
                    observed_at INTEGER NOT NULL,
                    window_minutes INTEGER,
                    used_percent REAL,
                    resets_at INTEGER NOT NULL,
                    limit_id TEXT,
                    plan_type TEXT,
                    limit_type TEXT,
                    is_rejection INTEGER NOT NULL
                );
                CREATE UNIQUE INDEX rate_limit_unique ON rate_limit(
                    source, observed_at, IFNULL(window_minutes, -1), IFNULL(limit_id, ''), IFNULL(limit_type, '')
                );
                CREATE INDEX rate_limit_observed ON rate_limit(observed_at);
                """)
        }
        return migrator
    }

    // MARK: - Log files

    public func logFiles() throws -> [String: LogFileRecord] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM log_file").reduce(into: [:]) { files, row in
                let file = LogFileRecord(row: row)
                files[file.path] = file
            }
        }
    }

    /// Returns the record for `path`, creating an empty one the first time a file is seen.
    public func registerLogFile(path: String, source: UsageSource) throws -> LogFileRecord {
        try writer.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO log_file (source, path) VALUES (?, ?)",
                arguments: [source.rawValue, path]
            )
            let row = try Row.fetchOne(db, sql: "SELECT * FROM log_file WHERE path = ?", arguments: [path])
            return LogFileRecord(row: row!)
        }
    }

    /// File metadata recorded with each successful parse.
    public struct FileSnapshot: Equatable, Sendable {
        public var size: UInt64
        public var modifiedAt: Double?
        public var inode: UInt64?

        public init(size: UInt64, modifiedAt: Double?, inode: UInt64?) {
            self.size = size
            self.modifiedAt = modifiedAt
            self.inode = inode
        }
    }

    /// Stores one parse result and advances the file's offset in a single transaction, so the offset
    /// can never move past data that was not saved.
    ///
    /// - Parameter restartedFromBeginning: The file was reparsed from offset 0 (replaced or truncated).
    ///   Its stored fallback rows are dropped first, because the new pass re-derives whatever still holds.
    public func apply(
        _ result: ParseResult,
        to file: LogFileRecord,
        parserState: Data?,
        threadID: String?,
        snapshot: FileSnapshot,
        restartedFromBeginning: Bool = false,
        now: Date = Date()
    ) throws {
        try writer.write { db in
            if result.retractFallbackUsage || restartedFromBeginning {
                try db.execute(
                    sql: "DELETE FROM usage WHERE file_id = ? AND kind = ?",
                    arguments: [file.id, UsageRecordKind.codexTokenCountFallback.rawValue]
                )
            }

            let upsertUsage = try db.cachedStatement(sql: """
                INSERT INTO usage (source, message_id, session_id, timestamp, model,
                                   input, output, cache_read, cache_write, reasoning, kind, file_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (source, message_id) DO UPDATE SET
                    timestamp = MIN(timestamp, excluded.timestamp),
                    input = MAX(input, excluded.input),
                    output = MAX(output, excluded.output),
                    cache_read = MAX(cache_read, excluded.cache_read),
                    cache_write = MAX(cache_write, excluded.cache_write),
                    reasoning = MAX(reasoning, excluded.reasoning)
                """)
            for record in result.usage {
                try upsertUsage.execute(arguments: [
                    record.source.rawValue, record.messageID, record.sessionID, record.timestamp.millisecondsSince1970,
                    record.model, record.tokens.input, record.tokens.output, record.tokens.cacheRead,
                    record.tokens.cacheWrite, record.tokens.reasoning, record.kind.rawValue, file.id,
                ])
            }

            let insertPrompt = try db.cachedStatement(sql: """
                INSERT OR IGNORE INTO prompt (source, id, session_id, timestamp) VALUES (?, ?, ?, ?)
                """)
            for prompt in result.prompts {
                try insertPrompt.execute(arguments: [
                    prompt.source.rawValue, prompt.id, prompt.sessionID, prompt.timestamp.millisecondsSince1970,
                ])
            }

            let insertLimit = try db.cachedStatement(sql: """
                INSERT OR IGNORE INTO rate_limit (source, observed_at, window_minutes, used_percent, resets_at,
                                                  limit_id, plan_type, limit_type, is_rejection)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for limit in result.rateLimits {
                try insertLimit.execute(arguments: [
                    limit.source.rawValue, limit.observedAt.millisecondsSince1970, limit.windowMinutes,
                    limit.usedPercent, limit.resetsAt.millisecondsSince1970, limit.limitID, limit.planType,
                    limit.limitType, limit.isRejection,
                ])
            }

            try db.execute(
                sql: """
                    UPDATE log_file SET byte_offset = ?, file_size = ?, modified_at = ?, inode = ?,
                        parser_state = ?, thread_id = ?, malformed_lines = malformed_lines + ?,
                        missing = 0, last_ingested_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    Int64(result.endOffset), Int64(snapshot.size), snapshot.modifiedAt, snapshot.inode.map { Int64(bitPattern: $0) },
                    parserState, threadID, result.malformedLineCount, now.timeIntervalSince1970, file.id,
                ]
            )
        }
    }

    /// Marks files that are no longer on disk. Their usage is kept.
    @discardableResult
    public func markMissing(paths: some Collection<String>) throws -> Int {
        guard !paths.isEmpty else { return 0 }
        return try writer.write { db in
            let statement = try db.cachedStatement(sql: "UPDATE log_file SET missing = 1 WHERE path = ? AND missing = 0")
            var changed = 0
            for path in paths {
                try statement.execute(arguments: [path])
                changed += db.changesCount
            }
            return changed
        }
    }

    /// Deletes usage from Codex rollouts whose thread turned out to be an import of another agent's
    /// session. Returns the number of rows removed.
    @discardableResult
    public func purgeCodexThreads(_ threadIDs: Set<String>) throws -> Int {
        guard !threadIDs.isEmpty else { return 0 }
        return try writer.write { db in
            let statement = try db.cachedStatement(sql: """
                DELETE FROM usage WHERE file_id IN (SELECT id FROM log_file WHERE source = 'codex' AND thread_id = ?)
                """)
            var removed = 0
            for threadID in threadIDs {
                try statement.execute(arguments: [threadID])
                removed += db.changesCount
            }
            return removed
        }
    }

    // MARK: - Reading

    /// Usage rows with `interval.start <= timestamp < interval.end`, oldest first.
    public func usage(in interval: DateInterval? = nil, source: UsageSource? = nil) throws -> [UsageRecord] {
        var conditions: [String] = []
        var arguments: StatementArguments = []
        if let interval {
            conditions.append("timestamp >= ? AND timestamp < ?")
            arguments += [interval.start.millisecondsSince1970, interval.end.millisecondsSince1970]
        }
        if let source {
            conditions.append("source = ?")
            arguments += [source.rawValue]
        }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM usage \(filter) ORDER BY timestamp, message_id", arguments: arguments)
                .map(UsageRecord.init(row:))
        }
    }

    /// Summed tokens of rows with `interval.start <= timestamp < interval.end`.
    public func tokenTotals(in interval: DateInterval, source: UsageSource? = nil) throws -> TokenCounts {
        var arguments: StatementArguments = [interval.start.millisecondsSince1970, interval.end.millisecondsSince1970]
        var filter = "timestamp >= ? AND timestamp < ?"
        if let source {
            filter += " AND source = ?"
            arguments += [source.rawValue]
        }
        return try writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT IFNULL(SUM(input), 0) AS input, IFNULL(SUM(output), 0) AS output,
                       IFNULL(SUM(cache_read), 0) AS cache_read, IFNULL(SUM(cache_write), 0) AS cache_write,
                       IFNULL(SUM(reasoning), 0) AS reasoning
                FROM usage WHERE \(filter)
                """, arguments: arguments)!
            return TokenCounts(
                input: row["input"], output: row["output"], cacheRead: row["cache_read"],
                cacheWrite: row["cache_write"], reasoning: row["reasoning"]
            )
        }
    }

    /// Times of responses and typed prompts for `source` since `date`, oldest first. The input for
    /// estimating Claude's 5-hour windows.
    public func activityTimes(source: UsageSource, since date: Date) throws -> [Date] {
        try writer.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT timestamp FROM usage WHERE source = ? AND timestamp >= ?
                UNION ALL
                SELECT timestamp FROM prompt WHERE source = ? AND timestamp >= ?
                ORDER BY 1
                """, arguments: [source.rawValue, date.millisecondsSince1970, source.rawValue, date.millisecondsSince1970])
                .map(Date.init(millisecondsSince1970:))
        }
    }

    /// Prompt times with `interval.start <= timestamp < interval.end`, oldest first.
    public func prompts(in interval: DateInterval? = nil) throws -> [PromptEvent] {
        let (filter, arguments): (String, StatementArguments) = interval.map {
            ("WHERE timestamp >= ? AND timestamp < ?", [$0.start.millisecondsSince1970, $0.end.millisecondsSince1970])
        } ?? ("", [])
        return try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM prompt \(filter) ORDER BY timestamp", arguments: arguments).map { row in
                PromptEvent(
                    source: UsageSource(rawValue: row["source"]) ?? .claudeCode,
                    id: row["id"],
                    sessionID: row["session_id"],
                    timestamp: Date(millisecondsSince1970: row["timestamp"])
                )
            }
        }
    }

    /// Every rate-limit observation since `date` (all of them when nil), oldest first.
    public func rateLimits(since date: Date? = nil) throws -> [RateLimitObservation] {
        let (filter, arguments): (String, StatementArguments) = date.map {
            ("WHERE observed_at >= ?", [$0.millisecondsSince1970])
        } ?? ("", [])
        return try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM rate_limit \(filter) ORDER BY observed_at", arguments: arguments)
                .map(RateLimitObservation.init(row:))
        }
    }

    /// The newest observation for each distinct limit (source, limit id, window length, limit type).
    public func latestRateLimits() throws -> [RateLimitObservation] {
        try writer.read { db in
            // SQLite returns the other columns from the row holding MAX(observed_at).
            try Row.fetchAll(db, sql: """
                SELECT *, MAX(observed_at) FROM rate_limit
                GROUP BY source, IFNULL(limit_id, ''), IFNULL(window_minutes, -1), IFNULL(limit_type, '')
                ORDER BY source, window_minutes
                """).map(RateLimitObservation.init(row:))
        }
    }

    public func counts() throws -> StoreCounts {
        try writer.read { db in
            StoreCounts(
                usage: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage") ?? 0,
                prompts: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM prompt") ?? 0,
                rateLimits: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rate_limit") ?? 0,
                logFiles: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM log_file") ?? 0
            )
        }
    }
}

// MARK: - Row mapping

extension Date {
    var millisecondsSince1970: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(millisecondsSince1970 ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }
}

extension LogFileRecord {
    init(row: Row) {
        let offset: Int64 = row["byte_offset"]
        let size: Int64 = row["file_size"]
        let inode: Int64? = row["inode"]
        self.init(
            id: row["id"],
            source: UsageSource(rawValue: row["source"]) ?? .claudeCode,
            path: row["path"],
            byteOffset: UInt64(max(0, offset)),
            fileSize: UInt64(max(0, size)),
            modifiedAt: row["modified_at"],
            inode: inode.map { UInt64(bitPattern: $0) },
            parserState: row["parser_state"],
            threadID: row["thread_id"],
            isMissing: row["missing"]
        )
    }
}

extension UsageRecord {
    init(row: Row) {
        self.init(
            source: UsageSource(rawValue: row["source"]) ?? .claudeCode,
            messageID: row["message_id"],
            sessionID: row["session_id"],
            timestamp: Date(millisecondsSince1970: row["timestamp"]),
            model: row["model"],
            tokens: TokenCounts(
                input: row["input"],
                output: row["output"],
                cacheRead: row["cache_read"],
                cacheWrite: row["cache_write"],
                reasoning: row["reasoning"]
            ),
            kind: UsageRecordKind(rawValue: row["kind"]) ?? .response
        )
    }
}

extension RateLimitObservation {
    init(row: Row) {
        self.init(
            source: UsageSource(rawValue: row["source"]) ?? .codex,
            observedAt: Date(millisecondsSince1970: row["observed_at"]),
            windowMinutes: row["window_minutes"],
            usedPercent: row["used_percent"],
            resetsAt: Date(millisecondsSince1970: row["resets_at"]),
            limitID: row["limit_id"],
            planType: row["plan_type"],
            limitType: row["limit_type"],
            isRejection: row["is_rejection"]
        )
    }
}

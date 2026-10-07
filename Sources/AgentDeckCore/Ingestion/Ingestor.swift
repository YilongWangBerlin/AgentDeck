import AgentDeckParsing
import Foundation

public struct IngestReport: Equatable, Sendable {
    public var filesSeen = 0
    /// Files that had new bytes and were parsed.
    public var filesParsed = 0
    /// Files reparsed from the beginning because they were replaced or truncated.
    public var filesRestarted = 0
    /// Known files no longer on disk, newly noticed in this scan. Their history is kept.
    public var filesNewlyMissing = 0
    /// Rows returned by the parsers, before deduplication.
    public var usageRowsParsed = 0
    public var malformedLines = 0
    /// Rows removed because their Codex thread is listed as an import.
    public var importedRowsPurged = 0
    /// One entry per file (or the imports list) that could not be read. Other files still ingest.
    public var failures: [String] = []

    public init() {}
}

/// Brings the store up to date with the log files on disk, reading only bytes it has not seen.
///
/// Running two scans at once is harmless (rows merge, offsets end up the same), but the app runs them
/// one at a time anyway.
public struct Ingestor: Sendable {
    public var store: UsageStore
    public var locations: LogLocations

    public init(store: UsageStore, locations: LogLocations) {
        self.store = store
        self.locations = locations
    }

    public func ingest(now: Date = Date()) throws -> IngestReport {
        var report = IngestReport()

        var imported: Set<String> = []
        do {
            imported = try CodexImports.importedThreadIDs(from: locations.codexImportsFile)
        } catch {
            report.failures.append("\(locations.codexImportsFile.lastPathComponent): \(error)")
        }
        report.importedRowsPurged = try store.purgeCodexThreads(imported)

        let known = try store.logFiles()
        let claude = ClaudeCodeParser()
        let codex = CodexParser(importedThreadIDs: imported)
        let files = locations.claudeLogFiles().map { (UsageSource.claudeCode, $0) }
            + locations.codexLogFiles().map { (UsageSource.codex, $0) }

        var seen = Set<String>()
        for (source, url) in files {
            seen.insert(url.path)
            report.filesSeen += 1
            do {
                guard let snapshot = Self.snapshot(of: url) else { continue }
                let file = try known[url.path] ?? store.registerLogFile(path: url.path, source: source)
                if file.isUnchanged(comparedTo: snapshot) { continue }

                var restart = file.wasReplaced(by: snapshot)
                var outcome = try parse(url, source: source, file: file, restart: restart, claude: claude, codex: codex)
                if outcome == nil {
                    // The stored offset is past the end: the file was rewritten between stat and read.
                    restart = true
                    outcome = try parse(url, source: source, file: file, restart: true, claude: claude, codex: codex)
                }
                guard let outcome else { continue }
                let (result, state, threadID) = outcome

                try store.apply(
                    result, to: file, parserState: state, threadID: threadID, snapshot: snapshot,
                    restartedFromBeginning: restart, now: now
                )
                report.filesParsed += 1
                report.filesRestarted += restart ? 1 : 0
                report.usageRowsParsed += result.usage.count
                report.malformedLines += result.malformedLineCount
            } catch {
                report.failures.append("\(url.lastPathComponent): \(error)")
            }
        }

        let gone = known.values.filter { !$0.isMissing && !seen.contains($0.path) }.map(\.path)
        report.filesNewlyMissing = try store.markMissing(paths: gone)
        return report
    }

    /// Returns nil when the stored offset lies beyond the end of the file.
    private func parse(
        _ url: URL, source: UsageSource, file: LogFileRecord, restart: Bool,
        claude: ClaudeCodeParser, codex: CodexParser
    ) throws -> (ParseResult, Data?, String?)? {
        var offset = restart ? 0 : file.byteOffset
        do {
            switch source {
            case .claudeCode:
                return (try claude.parse(fileAt: url, from: offset), nil, nil)
            case .codex:
                var state = CodexFileState()
                if !restart, let saved = file.parserState {
                    if let decoded = try? JSONDecoder().decode(CodexFileState.self, from: saved) {
                        state = decoded
                    } else {
                        offset = 0 // Unreadable state: start over rather than lose turn context.
                    }
                }
                let result = try codex.parse(fileAt: url, from: offset, state: &state)
                return (result, try JSONEncoder().encode(state), state.threadID)
            }
        } catch JSONLReader.ReadError.offsetBeyondEndOfFile where !restart {
            return nil
        }
    }

    static func snapshot(of url: URL) -> UsageStore.FileSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return nil }
        return UsageStore.FileSnapshot(
            size: size,
            modifiedAt: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}

extension LogFileRecord {
    func isUnchanged(comparedTo snapshot: UsageStore.FileSnapshot) -> Bool {
        snapshot.size == fileSize && snapshot.modifiedAt == modifiedAt && snapshot.inode == inode
    }

    /// A different inode, or fewer bytes than were already read, means new content at old offsets.
    func wasReplaced(by snapshot: UsageStore.FileSnapshot) -> Bool {
        if let inode, let current = snapshot.inode, inode != current { return true }
        return snapshot.size < byteOffset
    }
}

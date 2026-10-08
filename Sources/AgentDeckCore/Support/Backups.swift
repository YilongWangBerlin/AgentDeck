import Foundation

/// Timestamped backups under `~/.agentdeck/backups`. Every file or folder AgentDeck changes is first
/// copied or moved here, mirrored under its original absolute path, and RESTORE.txt records how to
/// put it back.
public final class BackupSession {
    public let directory: URL
    private var log: [String] = []

    /// Creates `<root>/<yyyyMMdd-HHmmss>` (with a suffix if that already exists).
    public init(root: URL, now: Date = Date()) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var candidate = root.appendingPathComponent(formatter.string(from: now))
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(formatter.string(from: now))-\(suffix)")
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        directory = candidate
    }

    /// Where `original` is kept inside this backup.
    public func location(for original: URL) -> URL {
        directory.appendingPathComponent(String(original.standardizedFileURL.path.drop { $0 == "/" }))
    }

    /// Copies `original` (a file, folder or symlink, kept as a symlink) into the backup.
    @discardableResult
    public func copy(_ original: URL) throws -> URL {
        let destination = location(for: original)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: destination)
        record("copied \(original.path)\n    to \(destination.path)")
        return destination
    }

    /// Moves `original` into the backup. Used instead of deleting, so nothing is ever lost.
    @discardableResult
    public func move(_ original: URL) throws -> URL {
        let destination = location(for: original)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: destination)
        record("moved \(original.path)\n    to \(destination.path)\n    restore: mv \"\(destination.path)\" \"\(original.path)\"")
        return destination
    }

    public func note(_ line: String) {
        record(line)
    }

    private func record(_ line: String) {
        log.append(line)
        try? (["AgentDeck backup. Each entry says what was saved and how to put it back.", ""] + log)
            .joined(separator: "\n")
            .write(to: directory.appendingPathComponent("RESTORE.txt"), atomically: true, encoding: .utf8)
    }
}

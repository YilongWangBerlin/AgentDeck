import Foundation

/// Claude Code's own usage limits. Claude Code logs none, but it hands them to the status line
/// command as `rate_limits` (part of the documented status line input). When AgentDeck is that
/// command, it keeps only this part in `~/.agentdeck/claude-limits.json`.
public struct ClaudeReportedLimits: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var usedPercent: Double
        public var resetsAt: Date

        public init(usedPercent: Double, resetsAt: Date) {
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public var observedAt: Date
    public var fiveHour: Window?
    public var sevenDay: Window?

    public init(observedAt: Date, fiveHour: Window?, sevenDay: Window?) {
        self.observedAt = observedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// Reads `rate_limits.five_hour` and `rate_limits.seven_day` from the status line input. Nil when
    /// neither is there (API key users, or before the first response of a session).
    public static func extract(statusLineInput data: Data, now: Date) -> ClaudeReportedLimits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let entry = limits[key] as? [String: Any],
                  let percent = (entry["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (entry["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return Window(usedPercent: percent, resetsAt: Date(timeIntervalSince1970: resets))
        }
        let result = ClaudeReportedLimits(observedAt: now, fiveHour: window("five_hour"), sevenDay: window("seven_day"))
        return result.fiveHour == nil && result.sevenDay == nil ? nil : result
    }

    /// What the status line shows in Claude Code's terminal UI: `5h 67% · 7d 76%`.
    public var statusText: String {
        [fiveHour.map { "5h \(Int($0.usedPercent.rounded()))%" }, sevenDay.map { "7d \(Int($0.usedPercent.rounded()))%" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    public static var fileURL: URL { AgentDeckPaths.home.appendingPathComponent("claude-limits.json") }

    public static func load(from url: URL = fileURL) -> ClaudeReportedLimits? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? coder.decoder.decode(ClaudeReportedLimits.self, from: data)
    }

    public func write(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coder.encoder.encode(self).write(to: url, options: .atomic)
    }

    private static let coder: (encoder: JSONEncoder, decoder: JSONDecoder) = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }()
    private var coder: (encoder: JSONEncoder, decoder: JSONDecoder) { Self.coder }
}

/// Adds AgentDeck as Claude Code's status line in `settings.json`, or takes it out again. The file
/// is edited as text so the rest of it stays exactly as it was, and every change is previewed and
/// backed up first.
public struct StatusLineInstaller: Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled
        case installed
        /// Another status line is set; AgentDeck leaves it alone.
        case otherCommand(String)
        case unreadable(String)
    }

    public enum Failure: Error, CustomStringConvertible {
        case cannotEdit(String)
        case changedSincePreview

        public var description: String {
            switch self {
            case .cannotEdit(let reason): reason
            case .changedSincePreview: "settings.json changed since the preview. Look at the new preview and confirm again."
            }
        }
    }

    /// A change to apply after the user saw `diff`.
    public struct Plan: Equatable, Sendable {
        public var original: String
        public var updated: String
        public var diff: String { LineDiff.unified(from: original, to: updated) }
    }

    public let settingsURL: URL
    /// The command Claude Code runs: AgentDeck's executable with `--statusline`.
    public let command: String

    public init(settingsURL: URL, executablePath: String) {
        self.settingsURL = settingsURL
        self.command = "'\(executablePath.replacingOccurrences(of: "'", with: "'\\''"))' --statusline"
    }

    private func read() throws -> String {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return "" }
        return try String(contentsOf: settingsURL, encoding: .utf8)
    }

    private static func parse(_ text: String) throws -> [String: Any] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw Failure.cannotEdit("settings.json is not a JSON object.")
        }
        return object
    }

    public func state() -> State {
        do {
            let settings = try Self.parse(try read())
            guard let statusLine = settings["statusLine"] as? [String: Any] else { return .notInstalled }
            let existing = statusLine["command"] as? String ?? ""
            return existing == command ? .installed : .otherCommand(existing)
        } catch {
            return .unreadable("\(error)")
        }
    }

    private var block: String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \"\(escaped)\"\n  }"
    }

    /// Adds the `statusLine` key as the last key of the file.
    public func installPlan() throws -> Plan {
        let original = try read()
        let settings = try Self.parse(original)
        guard settings["statusLine"] == nil else { throw Failure.cannotEdit("A status line is already set in settings.json.") }
        let updated: String
        if settings.isEmpty {
            updated = "{\n\(block)\n}\n"
        } else {
            guard let close = original.lastIndex(of: "}") else { throw Failure.cannotEdit("settings.json has no closing brace.") }
            var head = String(original[..<close])
            while head.last?.isWhitespace == true { head.removeLast() }
            updated = head + ",\n" + block + "\n" + original[close...]
        }
        guard (try? Self.parse(updated))?["statusLine"] != nil else { throw Failure.cannotEdit("Could not add the key cleanly.") }
        return Plan(original: original, updated: updated)
    }

    /// Takes out exactly the block `installPlan` added.
    public func removePlan() throws -> Plan {
        let original = try read()
        let updated = original.replacingOccurrences(of: ",\n" + block, with: "")
        guard updated != original, let parsed = try? Self.parse(updated), parsed["statusLine"] == nil else {
            throw Failure.cannotEdit("The statusLine entry was edited by hand; remove it from settings.json yourself.")
        }
        return Plan(original: original, updated: updated)
    }

    /// Writes `plan` after backing up the current file. Refuses if the file changed since the plan.
    @discardableResult
    public func apply(_ plan: Plan, backupsRoot: URL) throws -> URL? {
        guard try read() == plan.original else { throw Failure.changedSincePreview }
        var backup: URL?
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let session = try BackupSession(root: backupsRoot)
            try session.copy(settingsURL)
            session.note("restore: cp \"\(session.location(for: settingsURL).path)\" \"\(settingsURL.path)\"")
            backup = session.directory
        }
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plan.updated.write(to: settingsURL, atomically: true, encoding: .utf8)
        return backup
    }
}

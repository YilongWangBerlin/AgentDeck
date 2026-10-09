import Foundation

/// Asks Claude Code itself: runs `claude -p /usage` and reads the percentages it prints. AgentDeck
/// never sees a credential this way, and running Claude Code renews an expired login as a side
/// effect, so the online check works again afterwards.
///
///     Current session: 94% used · resets Oct 9 at 5pm (Europe/Berlin)
///     Current week (all models): 46% used · resets Oct 15 at 9am (Europe/Berlin)
public enum ClaudeUsageProbe {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notInstalled
        case notSignedIn
        case timedOut
        case unreadable(String)

        public var description: String {
            switch self {
            case .notInstalled: "Claude Code is not installed, so AgentDeck cannot ask it either."
            case .notSignedIn: "Claude Code is not signed in. Use “Sign in to Claude Code…” in Settings."
            case .timedOut: "Claude Code did not answer /usage in time."
            case .unreadable(let line): "Claude Code's /usage answer could not be read" + (line.isEmpty ? "." : ": \(line)")
            }
        }
    }

    /// Where Claude Code's installers put the `claude` command. A GUI app does not see the shell's PATH.
    public static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".npm-global/bin/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs the probe. Blocks for up to `timeout` seconds, so call it off the main thread.
    public static func run(now: Date = Date(), timeout: TimeInterval = 45,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> ClaudeLiveUsage {
        guard let claude = executable(home: home) else { throw Failure.notInstalled }
        // A folder of its own, so Claude Code's per-project state stays out of real projects.
        let workdir = home.appendingPathComponent(".agentdeck/claude-probe")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = claude
        // No transcript (it would count as usage), no MCP servers, no project settings or hooks.
        process.arguments = ["-p", "/usage", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "user"]
        process.currentDirectoryURL = workdir
        process.environment = [
            "HOME": home.path,
            "USER": NSUserName(),
            "PATH": "\(claude.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "dumb",
            "LANG": "en_US.UTF-8",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        var data = Data()
        let reader = DispatchQueue(label: "agentdeck.claude-probe")
        reader.async { data = output.fileHandleForReading.readDataToEndOfFile() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw Failure.timedOut
        }
        reader.sync {}
        return try parse(String(decoding: data, as: UTF8.self), now: now)
    }

    public static func parse(_ text: String, now: Date) throws -> ClaudeLiveUsage {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        func window(_ prefix: String) -> ClaudeLiveUsage.Window? {
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
            return parseWindow(line, now: now)
        }
        let session = window("Current session")
        let week = window("Current week (all models)") ?? window("Current week")
        guard session != nil || week != nil else {
            let lower = text.lowercased()
            if lower.contains("login") || lower.contains("log in") || lower.contains("sign in") || lower.contains("not logged") {
                throw Failure.notSignedIn
            }
            throw Failure.unreadable(lines.first { !$0.isEmpty } ?? "")
        }
        return ClaudeLiveUsage(fiveHour: session, sevenDay: week, fetchedAt: now)
    }

    /// `Current session: 94% used · resets Oct 9 at 5pm (Europe/Berlin)`.
    static func parseWindow(_ line: String, now: Date) -> ClaudeLiveUsage.Window? {
        guard let percentRange = line.range(of: #"(\d+(?:\.\d+)?)%\s*used"#, options: .regularExpression),
              let percent = Double(line[percentRange].prefix { $0.isNumber || $0 == "." }) else { return nil }
        var resetsAt: Date?
        if let match = line.range(of: #"resets\s+(.+?)\s*\(([^)]+)\)"#, options: .regularExpression) {
            let body = String(line[match]).dropFirst("resets".count).trimmingCharacters(in: .whitespaces)
            if let open = body.lastIndex(of: "("), let zone = TimeZone(identifier: String(body[body.index(after: open)...].dropLast())) {
                resetsAt = parseReset(String(body[..<open]).trimmingCharacters(in: .whitespaces), zone: zone, now: now)
            }
        }
        return ClaudeLiveUsage.Window(utilization: percent, resetsAt: resetsAt)
    }

    /// `Oct 9 at 5pm`, `Oct 15 at 9:30am`, `5pm` (today, or tomorrow once past).
    static func parseReset(_ text: String, zone: TimeZone, now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = text.components(separatedBy: " at ")
        let timeText = (parts.last ?? text).lowercased().replacingOccurrences(of: " ", with: "")
        guard let time = timeText.range(of: #"^(\d{1,2})(?::(\d{2}))?(am|pm)$"#, options: .regularExpression).map({ String(timeText[$0]) }) else { return nil }
        let isPM = time.hasSuffix("pm")
        let digits = time.dropLast(2).split(separator: ":")
        guard var hour = Int(digits[0]) else { return nil }
        let minute = digits.count > 1 ? Int(digits[1]) ?? 0 : 0
        if hour == 12 { hour = 0 }
        if isPM { hour += 12 }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        if parts.count > 1 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = "MMM d"
            guard let day = formatter.date(from: parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")) else { return nil }
            let monthDay = calendar.dateComponents([.month, .day], from: day)
            components.month = monthDay.month
            components.day = monthDay.day
        }
        components.hour = hour
        components.minute = minute
        guard var date = calendar.date(from: components) else { return nil }
        // A reset is always ahead: a date that already passed belongs to the next day or year.
        if date < now.addingTimeInterval(-3600) {
            date = calendar.date(byAdding: parts.count > 1 ? .year : .day, value: 1, to: date) ?? date
        }
        return date
    }
}

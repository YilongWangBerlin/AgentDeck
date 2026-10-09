import Foundation

/// What the desktop widget shows. AgentDeck writes it to `~/.agentdeck/widget/snapshot.json`; the
/// widget is sandboxed and only reads this file, never the database or the logs.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Claude: Codable, Equatable, Sendable {
        public var tokensInWindow: Int
        /// Estimated end of the running 5-hour window; nil when none is running.
        public var windowEnd: Date?
        /// Claude's own percentage, else against a learned limit or the user's soft budget.
        public var windowFraction: Double?
        /// Tokens in Claude's weekly window when the Claude app showed when it began, else the last 7 days.
        public var tokensLast7Days: Int
        public var sevenDayFraction: Double?

        public init(tokensInWindow: Int, windowEnd: Date?, windowFraction: Double?, tokensLast7Days: Int, sevenDayFraction: Double?) {
            self.tokensInWindow = tokensInWindow
            self.windowEnd = windowEnd
            self.windowFraction = windowFraction
            self.tokensLast7Days = tokensLast7Days
            self.sevenDayFraction = sevenDayFraction
        }
    }

    /// A window as Codex reported it.
    public struct Window: Codable, Equatable, Sendable {
        public var usedPercent: Double
        public var resetsAt: Date

        public init(usedPercent: Double, resetsAt: Date) {
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }

        /// Nil once the window has reset: Codex reports nothing newer until it runs again.
        public func percent(at now: Date) -> Double? { now < resetsAt ? usedPercent : nil }
    }

    public struct Codex: Codable, Equatable, Sendable {
        public var fiveHour: Window?
        public var weekly: Window?
        public var reportedAt: Date?
        /// Codex tokens in each window, while it has not reset.
        public var fiveHourTokens: Int?
        public var weeklyTokens: Int?

        public init(fiveHour: Window?, weekly: Window?, reportedAt: Date?, fiveHourTokens: Int? = nil, weeklyTokens: Int? = nil) {
            self.fiveHour = fiveHour
            self.weekly = weekly
            self.reportedAt = reportedAt
            self.fiveHourTokens = fiveHourTokens
            self.weeklyTokens = weeklyTokens
        }
    }

    public struct Day: Codable, Equatable, Sendable {
        /// Local midnight.
        public var start: Date
        public var claude: Int
        public var codex: Int
        public var total: Int { claude + codex }

        public init(start: Date, claude: Int, codex: Int) {
            self.start = start
            self.claude = claude
            self.codex = codex
        }
    }

    public var generatedAt: Date
    public var claude: Claude
    public var codex: Codex
    /// Daily tokens, oldest first, ending today.
    public var days: [Day]

    public init(generatedAt: Date, claude: Claude, codex: Codex, days: [Day]) {
        self.generatedAt = generatedAt
        self.claude = claude
        self.codex = codex
        self.days = days
    }

    /// The real home folder. Inside the widget's sandbox `homeDirectoryForCurrentUser` is the
    /// container, so it is looked up from the user database instead.
    public static var realHome: URL {
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var fileURL: URL { realHome.appendingPathComponent(".agentdeck/widget/snapshot.json") }

    public static func load(from url: URL = fileURL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func write(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

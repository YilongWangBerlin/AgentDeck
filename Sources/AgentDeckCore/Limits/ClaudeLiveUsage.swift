import Foundation

/// Claude's own usage percentages, fetched online the way Claude Code's `/usage` does. This is the
/// only source that is current: the Claude app writes its record only now and then, and local logs
/// miss use on claude.ai, in cloud sessions and on other devices.
public struct ClaudeLiveUsage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// Percent used, 0–100.
        public var utilization: Double
        /// Nil while no window is running.
        public var resetsAt: Date?

        public init(utilization: Double, resetsAt: Date?) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    public var fetchedAt: Date

    public init(fiveHour: Window?, sevenDay: Window?, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }

    /// Decodes the response of `GET /api/oauth/usage`, ignoring fields it does not know.
    public static func decode(_ data: Data, fetchedAt: Date) throws -> ClaudeLiveUsage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageClient.Failure.malformed
        }
        func window(_ key: String) -> Window? {
            guard let entry = object[key] as? [String: Any],
                  let utilization = (entry["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return Window(utilization: utilization, resetsAt: (entry["resets_at"] as? String).flatMap(parseDate))
        }
        return ClaudeLiveUsage(fiveHour: window("five_hour"), sevenDay: window("seven_day"), fetchedAt: fetchedAt)
    }

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Fetches `ClaudeLiveUsage` with the login Claude Code keeps in the keychain. It only reads that
/// login and never refreshes it: refreshing would rotate the token and sign Claude Code out. When
/// the login has expired, the next Claude Code request renews it.
public enum ClaudeUsageClient {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noLogin
        /// `security` failed: its exit status and the first line it printed to stderr.
        case keychain(status: Int32, message: String)
        case unreadableLogin
        case expired
        case http(Int)
        case malformed

        public var description: String {
            switch self {
            case .noLogin: "Claude Code has no saved login in the keychain (the Claude desktop app keeps its own). Sign in once with `claude` in Terminal to turn this on."
            case .keychain(let status, let message):
                "The keychain refused (security exit \(status)\(message.isEmpty ? "" : ": " + message))."
            case .unreadableLogin: "Claude Code's login in the keychain is not in a format AgentDeck knows."
            case .expired: "Claude Code's login has expired; it renews on Claude Code's next request."
            case .http(let status): "Claude answered HTTP \(status)."
            case .malformed: "Claude's answer could not be read."
            }
        }
    }

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    public static func fetch(now: Date = Date()) async throws -> ClaudeLiveUsage {
        let token = try accessToken(now: now)
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AgentDeck", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status) }
        return try ClaudeLiveUsage.decode(data, fetchedAt: now)
    }

    /// Claude Code keeps its login in `~/.claude/.credentials.json` on some setups and in the
    /// keychain on others; the file wins when it holds a login.
    static func accessToken(now: Date) throws -> String {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let token = try? token(fromCredentials: data, now: now) {
            return token
        }
        return try keychainToken(now: now)
    }

    /// Reads the access token through `/usr/bin/security`, the tool Claude Code itself uses, so the
    /// keychain item's access list already allows it.
    static func keychainToken(now: Date) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // stderr names the problem (item not found, user canceled), never the secret.
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").first.map(String.init) ?? ""
            throw process.terminationStatus == 44 ? Failure.noLogin : Failure.keychain(status: process.terminationStatus, message: message)
        }
        return try token(fromCredentials: data, now: now)
    }

    static func token(fromCredentials data: Data, now: Date) throws -> String {
        // `security -w` prints the secret as hex when it is not plain text.
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let json = trimmed.hasPrefix("{") ? Data(trimmed.utf8) : hexDecoded(trimmed) ?? data
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw Failure.unreadableLogin }
        guard let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw Failure.noLogin }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue, expires > 0,
           Date(timeIntervalSince1970: expires / 1000) <= now {
            throw Failure.expired
        }
        return token
    }

    static func hexDecoded(_ string: String) -> Data? {
        guard string.count % 2 == 0, string.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

@testable import AgentDeckCore
import Foundation
import Testing

@Suite struct ClaudeStatusLineTests {
    let now = Date(timeIntervalSince1970: 1_791_450_000)

    @Test func readsRateLimitsFromTheStatusLineInput() throws {
        let input = """
        {"session_id":"x","model":{"id":"claude-opus-5-5"},"cwd":"/private/path",
         "rate_limits":{"five_hour":{"used_percentage":67.4,"resets_at":1791453600},
                        "seven_day":{"used_percentage":76,"resets_at":1791460800}}}
        """
        let limits = try #require(ClaudeReportedLimits.extract(statusLineInput: Data(input.utf8), now: now))
        #expect(limits.fiveHour == .init(usedPercent: 67.4, resetsAt: Date(timeIntervalSince1970: 1_791_453_600)))
        #expect(limits.sevenDay?.usedPercent == 76)
        #expect(limits.statusText == "5h 67% · 7d 76%")
        // Only the limits are kept: nothing about the session, model or paths.
        let url = try temporaryDirectory().appendingPathComponent("claude-limits.json")
        try limits.write(to: url)
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(!stored.contains("private") && !stored.contains("session"))
        #expect(ClaudeReportedLimits.load(from: url) == limits)
    }

    @Test func inputWithoutLimitsGivesNothing() {
        #expect(ClaudeReportedLimits.extract(statusLineInput: Data(#"{"session_id":"x"}"#.utf8), now: now) == nil)
        #expect(ClaudeReportedLimits.extract(statusLineInput: Data("not json".utf8), now: now) == nil)
        #expect(ClaudeReportedLimits.extract(statusLineInput: Data(#"{"rate_limits":{}}"#.utf8), now: now) == nil)
    }

    @Test func reportedPercentagesWinOverBudgets() {
        let reported = ClaudeReportedLimits(observedAt: now, fiveHour: .init(usedPercent: 40, resetsAt: now.addingTimeInterval(600)),
                                            sevenDay: .init(usedPercent: 70, resetsAt: now.addingTimeInterval(-1)))
        let snapshot = LimitsSnapshot(
            computedAt: now,
            claude: .init(window: EstimatedWindow(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600), isConfirmedByRefusal: false),
                          tokensInWindow: 500, tokensLast7Days: 900, lastActivity: nil, lastRefusal: nil,
                          reportedFiveHour: ReportedWindow(reported.fiveHour!, minutes: 300, observedAt: now),
                          reportedWeekly: ReportedWindow(reported.sevenDay!, minutes: 10_080, observedAt: now)),
            codex: .init(fiveHour: nil, weekly: nil, planType: nil)
        )
        let gauges = LimitGauge.gauges(for: snapshot, budgets: SoftBudgets(claudeFiveHourTokens: 1_000, claudeSevenDayTokens: 1_000))
        let fiveHour = gauges.first { $0.kind == .claudeFiveHour }
        #expect(fiveHour?.fraction == 0.4 && fiveHour?.basis == .reported)
        // The weekly report has expired, so the budget applies again.
        let weekly = gauges.first { $0.kind == .claudeSevenDay }
        #expect(weekly?.basis == .softBudget(tokens: 1_000) && weekly?.fraction == 0.9)
    }
}

@Suite struct StatusLineInstallerTests {
    let original = """
    {
      "model": "opus",
      "hooks": {
        "Stop": []
      },
      "theme": "dark"
    }

    """

    private func installer(_ text: String?) throws -> (StatusLineInstaller, URL) {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent(".claude/settings.json")
        if let text {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return (StatusLineInstaller(settingsURL: url, executablePath: "/Applications/AgentDeck.app/Contents/MacOS/AgentDeck"), root)
    }

    @Test func addsOneKeyAndLeavesTheRestAsItWas() throws {
        let (installer, root) = try installer(original)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(installer.state() == .notInstalled)
        let plan = try installer.installPlan()
        // Only the old last line changes (it gains a comma).
        let removed = plan.diff.components(separatedBy: "\n").filter { $0.hasPrefix("-") }
        #expect(removed.count == 1 && removed[0].hasSuffix(#""theme": "dark""#))
        #expect(plan.updated.hasPrefix(original.components(separatedBy: "\n  \"theme\"")[0]))

        let backup = try #require(try installer.apply(plan, backupsRoot: root.appendingPathComponent("backups")))
        #expect(installer.state() == .installed)
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("RESTORE.txt").path))

        // Taking it out restores the original text exactly.
        try installer.apply(try installer.removePlan(), backupsRoot: root.appendingPathComponent("backups"))
        #expect(try String(contentsOf: installer.settingsURL, encoding: .utf8) == original)
    }

    @Test func leavesAnotherStatusLineAlone() throws {
        let (installer, root) = try installer(#"{"statusLine": {"type": "command", "command": "~/bin/mine"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(installer.state() == .otherCommand("~/bin/mine"))
        #expect(throws: StatusLineInstaller.Failure.self) { try installer.installPlan() }
    }

    @Test func refusesAPlanIfTheFileChangedMeanwhile() throws {
        let (installer, root) = try installer(original)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try installer.installPlan()
        try (original + " ").write(to: installer.settingsURL, atomically: true, encoding: .utf8)
        #expect(throws: StatusLineInstaller.Failure.self) { try installer.apply(plan, backupsRoot: root) }
    }

    @Test func createsTheFileWhenThereIsNone() throws {
        let (installer, root) = try installer(nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try installer.installPlan()
        #expect(try installer.apply(plan, backupsRoot: root) == nil)
        #expect(installer.state() == .installed)
    }
}

import AgentDeckCore
import AgentDeckParsing
import Foundation

// Ingests the real logs on this machine into the database given with --db and prints what changed.
// Read-only towards the logs. Run it twice to see that the second scan finds nothing new.
//
//   adingest --db /tmp/agentdeck-test.sqlite

guard let flag = CommandLine.arguments.firstIndex(of: "--db"), CommandLine.arguments.indices.contains(flag + 1) else {
    print("usage: adingest --db PATH")
    exit(2)
}
let store = try UsageStore(url: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
let ingestor = Ingestor(store: store, locations: .standard())

let clock = ContinuousClock()
let started = clock.now
let report = try ingestor.ingest()
let elapsed = clock.now - started

print("scan: \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])))  files seen \(report.filesSeen), parsed \(report.filesParsed), restarted \(report.filesRestarted), newly missing \(report.filesNewlyMissing)")
print("rows parsed \(report.usageRowsParsed), malformed lines \(report.malformedLines), imported rows purged \(report.importedRowsPurged)")
for failure in report.failures { print("  failed: \(failure)") }

let counts = try store.counts()
print("store: usage \(counts.usage), prompts \(counts.prompts), rate limits \(counts.rateLimits), files \(counts.logFiles)")
for source in UsageSource.allCases {
    let rows = try store.usage(source: source)
    let total = rows.reduce(TokenCounts()) { $0 + $1.tokens }
    print("[\(source.rawValue)] responses \(rows.count)  sessions \(Set(rows.map(\.sessionID)).count)  total \(total.total)")
}

let calendar = LocalCalendar()
let days = UsageAggregation.daily(try store.usage(), calendar: calendar)
print("local days with usage (\(calendar.timeZone.identifier)): \(days.count); last 3:")
for day in days.suffix(3) { print("  \(day.day): \(day.tokens.total) tokens, \(day.responses) responses") }

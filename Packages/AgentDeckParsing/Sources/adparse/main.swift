import AgentDeckParsing
import Foundation

// Parses the real logs on this machine and prints deduplicated totals. Read-only.
//
//   adparse            one pass over every file
//   adparse --split    parse each file in two passes, cut at an arbitrary byte in the middle, to check
//                      that incremental parsing matches a single pass

let split = CommandLine.arguments.contains("--split")
let locations = LogLocations.standard()
let clock = ContinuousClock()
let started = clock.now

struct Scan {
    var accumulator = UsageAccumulator()
    var prompts = 0
    var rateLimits: [RateLimitObservation] = []
    var malformed = 0
    var files = 0

    mutating func add(_ result: ParseResult, file: URL) {
        accumulator.apply(result, fileKey: file.path)
        prompts += result.prompts.count
        rateLimits += result.rateLimits
        malformed += result.malformedLineCount
    }
}

/// Runs `body` on a temporary copy of the first half of a file (cut mid-line on purpose, same file
/// name), then deletes the copy. One file at a time, so the copies never add up on disk.
func withFirstHalf<T>(of url: URL, _ body: (URL) throws -> T) throws -> T {
    let data = try Data(contentsOf: url)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("adparse-split-\(getpid())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let copy = directory.appendingPathComponent(url.lastPathComponent)
    try data.prefix(data.count / 2).write(to: copy)
    return try body(copy)
}

var scan = Scan()

let claude = ClaudeCodeParser()
for url in locations.claudeLogFiles() {
    scan.files += 1
    if split {
        let first = try withFirstHalf(of: url) { try claude.parse(fileAt: $0) }
        scan.add(first, file: url)
        scan.add(try claude.parse(fileAt: url, from: first.endOffset), file: url)
    } else {
        scan.add(try claude.parse(fileAt: url), file: url)
    }
}

let codex = CodexParser(importedThreadIDs: try CodexImports.importedThreadIDs(from: locations.codexImportsFile))
for url in locations.codexLogFiles() {
    scan.files += 1
    var state = CodexFileState()
    if split {
        let first = try withFirstHalf(of: url) { try codex.parse(fileAt: $0, state: &state) }
        scan.add(first, file: url)
        scan.add(try codex.parse(fileAt: url, from: first.endOffset, state: &state), file: url)
    } else {
        scan.add(try codex.parse(fileAt: url, state: &state), file: url)
    }
}

let elapsed = clock.now - started

// MARK: - Report

func compact(_ n: Int) -> String {
    switch n {
    case 1_000_000_000...: return String(format: "%.3fB", Double(n) / 1e9)
    case 1_000_000...: return String(format: "%.2fM", Double(n) / 1e6)
    case 1_000...: return String(format: "%.1fK", Double(n) / 1e3)
    default: return "\(n)"
    }
}

let iso = ISO8601DateFormatter()
print("files: \(scan.files)  malformed lines: \(scan.malformed)  time: \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])))\(split ? "  (split mode)" : "")")

for source in UsageSource.allCases {
    let records = scan.accumulator.records.values.filter { $0.source == source }
    let t = scan.accumulator.totals(for: source)
    let sessions = Set(records.map(\.sessionID)).count
    print("\n[\(source.rawValue)] responses \(records.count)  sessions \(sessions)  total \(compact(t.total)) (\(t.total))")
    print("  input \(compact(t.input))  output \(compact(t.output))  cache_read \(compact(t.cacheRead))  cache_write \(compact(t.cacheWrite))  reasoning \(compact(t.reasoning))")
    let fallback = records.filter { $0.kind == .codexTokenCountFallback }.count
    if fallback > 0 { print("  fallback rows from token_count: \(fallback)") }
    let byModel = Dictionary(grouping: records, by: \.model)
        .mapValues { $0.reduce(0) { $0 + $1.tokens.total } }
        .sorted { $0.value > $1.value }
    for (model, total) in byModel { print("  \(model): \(compact(total))") }
}
print("\nclaude prompts: \(scan.prompts)")

print("\nlatest Codex rate limits (limit_id codex):")
let codexLimits = scan.rateLimits.filter { $0.source == .codex && $0.limitID == "codex" }
for minutes in Set(codexLimits.compactMap(\.windowMinutes)).sorted() {
    if let latest = codexLimits.filter({ $0.windowMinutes == minutes }).max(by: { $0.observedAt < $1.observedAt }) {
        print("  \(minutes) min: \(latest.usedPercent.map { "\($0)%" } ?? "?") resets \(iso.string(from: latest.resetsAt)) (seen \(iso.string(from: latest.observedAt)))")
    }
}
print("Claude refusals with a reset time:")
for observation in scan.rateLimits.filter({ $0.source == .claudeCode }).sorted(by: { $0.observedAt < $1.observedAt }) {
    print("  \(iso.string(from: observation.observedAt)) \(observation.limitType ?? "?") resets \(iso.string(from: observation.resetsAt))")
}

import AgentDeckCore
import Foundation

// Writes the public aggregate JSON (agentdeck.usage/v1) from an AgentDeck database. Prints a summary of
// what the file contains so it can be checked before it is published anywhere.
//
//   adexport --db ~/.agentdeck/agentdeck.sqlite --out data.json [--no-models] [--no-codex] [--no-claude]
//            [--card-light card-light.svg] [--card-dark card-dark.svg]

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}
guard let db = value(after: "--db"), let out = value(after: "--out") else {
    print("usage: adexport --db PATH --out FILE [--no-models] [--no-codex] [--no-claude]")
    exit(2)
}
let options = PublicExportOptions(
    includeClaudeCode: !arguments.contains("--no-claude"),
    includeCodex: !arguments.contains("--no-codex"),
    includeModelNames: !arguments.contains("--no-models")
)
let store = try UsageStore(url: URL(fileURLWithPath: (db as NSString).expandingTildeInPath))
let export = try PublicExporter.export(store: store, options: options)
let data = try PublicExporter.encode(export)
try data.write(to: URL(fileURLWithPath: out), options: .atomic)
for theme in UsageCard.Theme.allCases {
    if let path = value(after: "--card-\(theme.rawValue)") {
        try Data(UsageCard.svg(export, theme: theme).utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        print("wrote \(path)")
    }
}

let all = export.summaries["all"]?["all"]
print("wrote \(out): \(data.count) bytes, schema \(export.schema), generated \(export.generatedAt)")
print("tools: \(export.sources.joined(separator: ", ")); day rows: \(export.daily.count); models: \(Set(export.daily.compactMap(\.model)).sorted().joined(separator: ", "))")
if let all {
    print("all time: \(all.sessions) sessions, \(all.messages) messages, \(Formatting.compactTokens(all.tokens.total)) tokens, \(all.activeDays) active days")
}

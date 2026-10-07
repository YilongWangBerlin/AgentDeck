# AgentDeckParsing

Reads Claude Code transcripts and Codex rollouts, read-only, and turns them into deduplicated usage
rows, rate-limit observations and prompt times. It has no dependencies. FORMATS.md (repo root)
documents the formats, and DECISIONS.md the counting rules.

- `ClaudeCodeParser`: one row per `message.id:requestId`, keeping the largest value of each token field.
- `CodexParser`: one row per `token_usage_record`, with a `token_count` fallback for older files.
  Skips sessions Codex imported from other agents. Carries `CodexFileState` between incremental passes.
- `JSONLReader`: reads complete lines from a byte offset and leaves a half-written last line for later.
- `UsageAccumulator`: the dedup rules in memory, mirrored by the store.

```bash
swift test
```

`adparse` prints totals for the real logs on this machine, and `--split` checks that parsing every file
in two passes gives the same result as one pass:

```bash
swift run -c release adparse --split
```

Test fixtures are synthetic. Real logs never go into the repository.

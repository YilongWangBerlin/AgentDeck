# Decisions

Settled choices, with the reason for each. FORMATS.md has the underlying evidence.

## Confirmed 2026-10-08

| Topic | Decision | Why |
|---|---|---|
| Claude dedup | Key `message.id:requestId`; keep the max of each token field per key | One response is written as N lines, and earlier lines can hold partial `output_tokens` (FORMATS 1.6) |
| Codex counting | One row per `token_usage_record`, keyed by `response_id`. Fall back to `token_count.last_token_usage` only in files with no records | Cumulative totals reset and get inherited by subagents (FORMATS 2.6) |
| Codex imports | Skip threads listed in `external_agent_session_imports.json`. Fallback rows also need a `turn_context` or `rate_limits` in the file | Imports are copies of Claude Code transcripts (FORMATS 2.7) |
| Token normalization | `input` = non-cached input for both tools. `reasoning` is a subset of `output` and never added to totals | OpenAI's `input_tokens` includes cached tokens |
| Claude 5h estimate | Window start = first activity after the previous window ends, floored to 10 minutes; reset = start + 5h. A logged `quotaLimits.resetsAt` overrides it. Always labeled "estimate" | Matches all 3 real resets (FORMATS 3.3) |
| Codex skills target | Symlink into `~/.codex/skills` (honors `$CODEX_HOME`). `~/.agents/skills` is an import source only | Codex loads both, so linking into both would list each skill twice |
| GitHub Pages | Separate repo served at `yilongwangberlin.github.io/<repo>/`; normal commits; never force-push | Keeps the hand-built user site and its history untouched |
| Publishing clones | AgentDeck publishes from its own clones in `~/.agentdeck/publish/`, never from your working copies | The Pages working copy has uncommitted changes |
| Build | SwiftPM only (no Xcode), swift-testing, and a script that assembles an ad-hoc signed `.app` | Only Command Line Tools are installed; XCTest is unavailable |
| Source repo | `github.com/YilongWangBerlin/AgentDeck` (public) | Test fixtures are synthetic. Real logs never go into the repo |
| Database | `~/.agentdeck/agentdeck.sqlite`, GRDB 7.8 in WAL mode | Everything AgentDeck owns lives in one folder |
| Stored times | UTC milliseconds. Local days and hours are computed at read time by `LocalCalendar`, with an explicit time zone | Changing time zones never rewrites history |
| History | Usage rows are never deleted when a log file disappears; the file is only flagged missing | Claude Code deletes transcripts after 30 days |
| Ingestion | Per file: byte offset, size, mtime and inode. One transaction per file. A replaced or truncated file is reparsed from 0. Re-running a scan is harmless | A crash can't advance an offset past unsaved data |

## Dashboard stat definitions

The reference screenshot is Claude Code's own stats card. I matched each of its numbers against the raw
logs to work out how it counts, then chose AgentDeck's definitions.

| Stat | Claude Code's card (reverse-engineered) | AgentDeck |
|---|---|---|
| Sessions (47) | Distinct `sessionId` over all record types | Distinct `session_id` with at least one usage row. For Codex that is the root thread, so subagents don't add sessions |
| Messages (14,051) | Raw non-sidechain `user` + `assistant` JSONL lines: every content block and every tool result counts | **Deduplicated model responses** (one per API call). About 4.6K for Claude today. Comparable across both tools |
| Total tokens (2.4B) | Sum over **every line**, so each response is counted once per content block (2.420B) | Deduplicated sum: **about 1.19B** for Claude today. That figure matches Claude Code's own per-session `cost-state` totals exactly where those exist |
| Active days (42) | Local days with any `user`/`assistant` line | Local days with at least one usage row |
| Peak hour (11 PM) | Local hour in which the most **sessions started** (9 sessions at 23:00) | Local hour with the most model responses. More stable than counting session starts |
| Favorite model (Opus 5.5) | Not determined | Model with the most tokens in the selected range and source |
| Heatmap | Rows Sun→Sat, columns = weeks ending with the current partial week, 26 columns, local timezone | Same layout. Intensity uses quantile buckets of daily tokens: 4 levels plus empty |

AgentDeck will therefore show about half the token total that Claude Code's own card shows. The
difference is entirely duplicate counting, and the dashboard will say so in a tooltip.

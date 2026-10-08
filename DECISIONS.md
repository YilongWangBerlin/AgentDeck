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
| How tools get library skills | **Changed 2026-10-08:** Claude Code gets a real copy in `~/.claude/skills/<name>` with a `.agentdeck-managed.json` marker; Codex gets a symlink. Copies follow the library (`adskills sync`, or Update in the Skills tab); a copy edited in place is reported, never overwritten | Parts of the Claude app skip symlinked skill folders, so a new desktop session lost every linked skill. Codex follows links (checked with `codex debug prompt-input`) |
| Built-in skills | Codex's bundled skills, Claude Code and Codex plugins and the Claude app's skills are listed in a collapsed "Built-in and plugin skills" section and never imported, moved or linked over. Enabling a library skill under a name a built-in already uses warns that the tool will list both | Your call on 2026-10-08: each tool keeps managing its own skills, and AgentDeck manages only the ones you installed |
| Claude percentages | Learned from refusals: when Claude Code refuses a request it logs the window's reset time, so that window was at 100%. The limit is the median of the tokens used up to the last 5 refusals (30 days); a soft budget in Settings applies only where none was learned. Tested and dropped on 2026-10-08: the status line (`rate_limits`) never runs in the Claude app's Code tab, and typing percentages from Claude's usage card was a chore | Claude Code logs no limits, AgentDeck uses no undocumented APIs, and you asked for nothing to type |
| Window tokens | Shown next to each percentage. A window with a reported reset time runs from that time back by its length (5 hours, 7 days); Claude Code's 7-day figure stays a rolling sum unless Claude reported its weekly window | Percentage and tokens then describe the same window |
| GitHub Pages | **Changed 2026-10-08 at your request:** the `agentdeck/` folder of the user site repo (`yilongwangberlin.github.io/agentdeck/`). AgentDeck writes only inside that folder, commits normally and never force-pushes; the first push waits for your OK | You asked for the dashboard on your own site. Staying in one folder leaves the rest of the site untouched |
| Homepage section | "Coding agent usage" sits at the bottom of the homepage (`agentdeck/usage.js`, `usage.css`): one stat line, the heatmap and an All/30d/7d toggle. The fuller page stays at `/agentdeck/` without a link from the homepage | Your layout requests on 2026-10-08 |
| Publishing defaults | Off until enabled. Profile card: `assets/agentdeck/` in `YilongWangBerlin/YilongWangBerlin`, amending AgentDeck's own commit. Pages: `agentdeck/data.json` in the site repo, a new commit per change | Amend for the profile repo as you asked. New commits for the site, because rewriting history there would make your local copy diverge from the remote |
| Review before push | "Publish now" always previews first and needs a click on Push. The daily run only prepares and notifies, unless you turn on "Push scheduled updates without asking me" | Meets "preview before every push" by default, while still allowing a fully automatic daily update if you opt in |
| Web page | Plain HTML, CSS and JS in `Web/agentdeck/`, reading `data.json` (schema v1). The homepage's look: white paper, Lato, amber accent, rounded corners, soft shadows, English copy | No build step, and it fits the site |
| Publishing clones | AgentDeck publishes from its own blobless clones in `~/.agentdeck/publish/` (full history, current files only: 12 MB instead of 1 GB for the site), never from your working copies. It never amends a commit whose parent is missing | The Pages working copy has uncommitted changes |
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

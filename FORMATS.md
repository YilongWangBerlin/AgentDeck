# FORMATS.md: AgentDeck Step 0 findings

Inspected on 2026-10-08 on this Mac, read-only. Every sample below is a real line from disk with
content redacted: free text becomes `<redacted:N chars>`, IDs are cut to 8 characters, paths and
prompts are removed. Samples are pretty-printed here; on disk each one is a single JSONL line.

Contents: [0 Environment](#0-environment) · [1 Claude Code usage](#1-claude-code-usage) ·
[2 Codex usage](#2-codex-usage) · [3 Rate limits](#3-rate-limits) · [4 Skills](#4-skills) ·
[5 GitHub](#5-github) · [6 Normalized usage row](#6-normalized-usage-row) ·
[7 Not found / not verified](#7-not-found--not-verified)

---

## 0. Environment

| Item | Found |
|---|---|
| macOS | 15.7.2 (24G325), arm64 |
| Local timezone | `Europe/Berlin` (CEST, UTC+2 today; CET, UTC+1 in winter) |
| Claude Code | CLI 2.1.251 at `~/.local/bin/claude`; the desktop app bundles 2.1.288 and 2.1.289. Transcripts were written by 2.1.197 through 2.1.289, with `entrypoint` `claude-desktop` (9,030 lines) or `sdk-cli` (16 lines) |
| Codex | **Not on PATH.** It ships inside `ChatGPT.app` (26.930.51102) as `codex-cli 0.160.0`. Rollouts were written by 0.153.4 through 0.160.0, with `originator` `codex_work_desktop` |
| `$CLAUDE_CONFIG_DIR`, `$CODEX_HOME` | Both unset. `~/.config/claude` does not exist |
| Swift toolchain | Swift 6.0.3, **Command Line Tools only (no Xcode)** |
| XCTest | **Not available** (`no such module 'XCTest'`) |
| swift-testing (`import Testing`) | Works |
| SwiftUI `MenuBarExtra`, Swift Charts, `SQLite3`, FSEvents | All compile for a macOS 14 target with the Command Line Tools |
| `gh` | **Not installed** |
| git | 2.44.0. `credential.helper=osxkeychain` (set in `/opt/homebrew/etc/gitconfig`); Keychain holds a `github.com` entry |

---

## 1. Claude Code usage

### 1.1 Files

| Path pattern | Count | Notes |
|---|---|---|
| `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` | 47 | Main sessions |
| `~/.claude/projects/<cwd-slug>/<sessionId>/subagents/agent-<id>.jsonl` | 3 | Subagent sidechains: `isSidechain: true`, `agentId` set, `sessionId` = the **parent** session |
| `…/<sessionId>/tool-results/*.txt`, `custom-title.json`, `memory/*.md` | | Not usage data. Only `*.jsonl` gets parsed |

- 50 JSONL files, 430 MB, **0 malformed lines**. Records run from 2026-07-08 to today.
- `~/.claude/settings.json` has no `cleanupPeriodDays`, so the 30-day default applies.
  `~/.claude/.last-cleanup` = `2026-10-07T21:59:55Z`. Storing parsed history permanently is required.

### 1.2 Record types (line counts across all files)

`assistant` 9,043 · `user` 5,245 · `attachment` 4,577 · `last-prompt` 1,724 · `custom-title` 1,565 ·
`queue-operation` 1,468 · `atis-latch` 1,302 · `agent-name` 709 · `system` 518 · `bridge-session` 503 ·
`ai-title` 499 · `mode` 166 · `file-history-snapshot` 87 · `file-history-delta` 65 · `cost-state` 13

We use `assistant` (usage) and `user` (prompt counts, activity times). Everything else is ignored.

### 1.3 Sample: `assistant`

Omitted for brevity: `container`, `context_management`, `diagnostics`, `input_transformations`,
`stop_details`. Content blocks are reduced to their `type`.

```json
{
  "parentUuid": "3285b48f…",
  "isSidechain": false,
  "message": {
    "model": "claude-opus-5-5",
    "id": "msg_011C…",
    "type": "message",
    "role": "assistant",
    "content": [
      {
        "type": "thinking",
        "thinking": "<redacted>"
      }
    ],
    "stop_reason": "tool_use",
    "stop_sequence": null,
    "usage": {
      "input_tokens": 2,
      "cache_creation_input_tokens": 33621,
      "cache_read_input_tokens": 41283,
      "output_tokens": 385,
      "output_tokens_details": {
        "thinking_tokens": 200
      },
      "server_tool_use": {
        "web_search_requests": 0,
        "web_fetch_requests": 0
      },
      "service_tier": "standard",
      "cache_creation": {
        "ephemeral_1h_input_tokens": 33621,
        "ephemeral_5m_input_tokens": 0
      },
      "inference_geo": "not_available",
      "iterations": [
        {
          "input_tokens": 2,
          "output_tokens": 385,
          "cache_read_input_tokens": 41283,
          "cache_creation_input_tokens": 33621,
          "cache_creation": {
            "ephemeral_5m_input_tokens": 0,
            "ephemeral_1h_input_tokens": 33621
          },
          "type": "message"
        }
      ],
      "speed": "standard",
      "fallback_credit": null
    }
  },
  "thinkingDurationMs": 1937,
  "apiBlockIndex": 0,
  "requestId": "req_011C…",
  "type": "assistant",
  "uuid": "b998e33a…",
  "timestamp": "2026-10-07T21:39:43.351Z",
  "advisorModel": "<redacted:15 chars>",
  "effort": "high",
  "perTurnEffort": "<redacted:4 chars>",
  "userType": "external",
  "entrypoint": "claude-desktop",
  "cwd": "<redacted>",
  "sessionId": "38053ea7…",
  "version": "2.1.289",
  "gitBranch": "<redacted>"
}
```

### 1.4 Sample: `user` (a human prompt, not a tool result)

```json
{
  "parentUuid": null,
  "isSidechain": false,
  "promptId": "fa797e58…",
  "type": "user",
  "message": {
    "role": "user",
    "content": "<redacted:10 chars>"
  },
  "uuid": "bcb623ee…",
  "timestamp": "2026-10-07T21:39:40.125Z",
  "permissionMode": "<redacted:4 chars>",
  "origin": {
    "kind": "<redacted:5 chars>"
  },
  "promptSource": "<redacted:3 chars>",
  "turnOrigin": "<redacted:5 chars>",
  "turnPosition": {
    "promptIndex": 1,
    "turnIndex": 1
  },
  "userType": "external",
  "entrypoint": "claude-desktop",
  "cwd": "<redacted>",
  "sessionId": "38053ea7…",
  "version": "2.1.289",
  "gitBranch": "<redacted>"
}
```

### 1.5 Fields we use

| JSON path | Column | Notes |
|---|---|---|
| `timestamp` | `timestamp` | ISO-8601 UTC with milliseconds and a trailing `Z` |
| `sessionId` | `session_id` | Subagent lines carry the parent's `sessionId`, so they don't inflate session counts |
| `message.id` + `requestId` | `message_id` | Dedup key (1.6). `requestId` is missing only on `<synthetic>` lines |
| `message.model` | `model` | Lines with `<synthetic>` (local error/notice lines, all-zero usage) are skipped |
| `message.usage.input_tokens` | `input` | Excludes cache tokens |
| `message.usage.output_tokens` | `output` | **Includes** thinking tokens |
| `message.usage.cache_read_input_tokens` | `cache_read` | |
| `message.usage.cache_creation_input_tokens` | `cache_write` | Equals `cache_creation.ephemeral_5m_input_tokens` + `ephemeral_1h_input_tokens` |
| `message.usage.output_tokens_details.thinking_tokens` | `reasoning` | A **subset of `output`** and never added to totals. Present on 6,109 of 9,043 lines |
| `message.stop_reason` | (dedup only) | |
| `user` lines with no `toolUseResult` and `isMeta != true` | (prompt count, activity) | The other `user` lines are tool results |

Checks:
- `thinking_tokens <= output_tokens` on every final line (0 violations).
- `usage.iterations` always has length 1 and equals the top-level usage (8,725 of 8,725), so it's ignored.

### 1.6 How duplicates appear, and the dedup key

1. **One line per content block.** One API response is written as N lines (thinking, text, tool_use, …)
   that share `message.id` and `requestId`. 9,046 assistant lines reduce to **4,531 unique keys**, and
   group sizes reach 14. Summing every line counts roughly 2–2.5× too much.
2. **Partial usage on earlier lines.** In 29 groups the earlier lines hold a mid-stream snapshot
   (`output_tokens` 2–7, `stop_reason: null`). Only the last line has the final `output_tokens`.
   Keeping the first occurrence would **undercount output**.
3. **Copies across files.** 189 keys appear in two files. A resumed or forked session's new file repeats
   earlier lines with the original `sessionId` and `uuid`. 8 more keys repeat across subagent files.
4. 129 keys have no line with a `stop_reason` (interrupted streams).

**Proposed key:** `message_id = "<message.id>:<requestId>"`.
**Rule:** upsert per key and keep the **maximum of each token field**. On this data, the line with a
non-null `stop_reason` (or, failing that, the largest `output_tokens`) is ≥ every other line on all four
fields for 4,531 of 4,531 keys, so "max per field" equals "final line". The rule is also order-independent,
so it holds when lines arrive across separate incremental scans.

### 1.7 Cross-check against `cost-state`, and a caveat

`cost-state` lines (13, written now and then) hold per-session cumulative `modelUsage` with
`inputTokens`, `outputTokens`, `thinkingTokens`, `cacheReadInputTokens`, `cacheCreationInputTokens`,
and `costUSD`.

- For 4 sessions, the deduped transcript sums match `cost-state` **exactly**.
- For the other sessions, `cost-state` is higher:
  - **Haiku 4.5 calls** (background work such as titles and web-fetch summaries) appear in
    `cost-state` but **never** as `assistant` lines.
  - Opus totals are also higher: 2–4% more cache reads, and in two sessions much more (one shows 454K
    output in `cost-state` against 261K in the transcript). Likely causes are compaction and other
    background requests, or usage carried over when a session was resumed. I could not tell which.
- **Consequence:** transcript-based Claude totals are a **lower bound** on what was billed.
- **Proposal:** don't ingest `cost-state`. It is sparse, cumulative per session, and only sometimes
  written. The UI will carry a short note saying background requests aren't included.

### 1.8 Current totals under these rules

4,606 API responses · 46 sessions · **1.19B tokens**: input 50K, output 5.16M (thinking 1.55M of that),
cache read 1.155B, cache write 27.8M.

By model: `claude-opus-5` 516M · `claude-opus-5-5` 511M · `claude-sonnet-5` 83M · `claude-opus-4-8` 77M ·
`claude-haiku-4-5-20251001` 0.16M · `claude-opus-4-6` 0.12M.

---

## 2. Codex usage

### 2.1 Files

- `~/.codex/sessions/YYYY/MM/DD/rollout-<local time>-<thread uuid>.jsonl`: 175 files from 2026-09-07 to
  2026-10-07, 871 MB, 0 malformed lines. The folder date and the filename time are **local** time;
  record timestamps are UTC.
- There is no `archived_sessions/` directory.
- Codex also keeps SQLite databases (`state_5.sqlite`, `thread_history_1.sqlite`). These are undocumented
  internals. I opened them read-only once to cross-check, and the app will **not** use them.

### 2.2 Record types

`event_msg` 28,150 · `response_item` 23,562 · **`token_usage_record` 3,832** · `turn_context` 720 ·
`world_state` 241 · `session_meta` 191 · `inter_agent_communication_metadata` 77 · `compacted` 52

`event_msg` subtypes: `item_completed` 19,303 · `token_count` 3,957 · `agent_message` 1,631 ·
`task_started` 1,256 · `task_complete` 1,218 · `thread_settings_applied` 724 · `user_message` 38 ·
`turn_aborted` 22

### 2.3 New since your notes: `token_usage_record`

Every API response writes one `token_usage_record` with a **globally unique `response_id`** (every
native rollout with usage has them except one). It holds that response's `usage` plus running `turn_token_usage` and `thread_token_usage`.

```json
{
  "timestamp": "2026-10-06T23:02:54.678Z",
  "ordinal": 16,
  "type": "token_usage_record",
  "payload": {
    "thread_id": "0199aaaa…",
    "turn_id": "0199aaaa…",
    "session_id": "0199aaaa…",
    "root_turn_id": "0199aaaa…",
    "response_id": "resp_0d0…",
    "usage": {
      "input_tokens": 36237,
      "cached_input_tokens": 22144,
      "cache_write_input_tokens": 0,
      "output_tokens": 365,
      "reasoning_output_tokens": 0,
      "total_tokens": 36602
    },
    "turn_token_usage": {
      "input_tokens": 36237,
      "cached_input_tokens": 22144,
      "cache_write_input_tokens": 0,
      "output_tokens": 365,
      "reasoning_output_tokens": 0,
      "total_tokens": 36602
    },
    "thread_token_usage": {
      "input_tokens": 36237,
      "cached_input_tokens": 22144,
      "cache_write_input_tokens": 0,
      "output_tokens": 365,
      "reasoning_output_tokens": 0,
      "total_tokens": 36602
    }
  }
}
```

### 2.4 `token_count` (matches your description, plus `rate_limits`)

```json
{
  "timestamp": "2026-10-06T23:02:55.678Z",
  "ordinal": 22,
  "type": "event_msg",
  "payload": {
    "type": "token_count",
    "info": {
      "total_token_usage": {
        "input_tokens": 36237,
        "cached_input_tokens": 22144,
        "cache_write_input_tokens": 0,
        "output_tokens": 365,
        "reasoning_output_tokens": 0,
        "total_tokens": 36602
      },
      "last_token_usage": {
        "input_tokens": 36237,
        "cached_input_tokens": 22144,
        "cache_write_input_tokens": 0,
        "output_tokens": 365,
        "reasoning_output_tokens": 0,
        "total_tokens": 36602
      },
      "model_context_window": 354350
    },
    "rate_limits": {
      "limit_id": "codex",
      "limit_name": null,
      "primary": {
        "used_percent": 0.0,
        "window_minutes": 300,
        "resets_at": 1791345766
      },
      "secondary": {
        "used_percent": 51.0,
        "window_minutes": 10080,
        "resets_at": 1791584839
      },
      "credits": {
        "has_credits": false,
        "unlimited": false,
        "balance": "<redacted:1 chars>"
      },
      "individual_limit": null,
      "spend_control_reached": null,
      "plan_type": "plus",
      "rate_limit_reached_type": null
    }
  }
}
```

### 2.5 Where the model name lives

The model is **not** in `session_meta` and **not** in either token record. It is only in
`turn_context.payload.model`.

- **Join:** `token_usage_record.payload.turn_id` → the `turn_context` with the same `turn_id`.
- **Fallback:** the most recent `turn_context` earlier in the same file (needed for 6 records).

Models seen: `gpt-6.1-sol`, `gpt-6-astra`, `gpt-5.6-sol`, `gpt-6-sol`, and `codex-auto-review` (the
"guardian" auto-review subagent).

```json
{
  "timestamp": "2026-10-06T23:02:46.129Z",
  "ordinal": 7,
  "type": "turn_context",
  "payload": {
    "turn_id": "0199aaaa…",
    "root_turn_id": "0199aaaa…",
    "disabled_plugin_ids": "<redacted:10 chars>",
    "cwd": "<redacted>",
    "workspace_roots": "<redacted:10 chars>",
    "current_date": "2026-10-07",
    "timezone": "Europe/Berlin",
    "approval_policy": "on-request",
    "approvals_reviewer": "<redacted:11 chars>",
    "sandbox_policy": "<redacted:10 chars>",
    "permission_profile": "<redacted:10 chars>",
    "active_permission_profile": "<redacted:10 chars>",
    "file_system_sandbox_policy": "<redacted:10 chars>",
    "model": "gpt-6.1-sol",
    "comp_hash": "<redacted:10 chars>",
    "personality": "friendly",
    "collaboration_mode": "<redacted:10 chars>",
    "multi_agent_version": "<redacted:2 chars>",
    "realtime_active": false,
    "cyber_access_program": "<redacted:8 chars>",
    "effort": "xhigh",
    "summary": "detailed"
  }
}
```

`session_meta` from a native session (it carries no model):

```json
{
  "timestamp": "2026-10-06T23:02:44.490Z",
  "type": "session_meta",
  "payload": {
    "creator_user_id": "<redacted>",
    "creator_account_id": "<redacted>",
    "session_id": "0199aaaa…",
    "id": "0199aaaa…",
    "timestamp": "2026-10-06T23:02:43.856Z",
    "cwd": "<redacted>",
    "runtime_workspace_roots": "<redacted>",
    "originator": "codex_work_desktop",
    "cli_version": "0.160.0",
    "source": "vscode",
    "thread_source": "user",
    "model_provider": "openai",
    "base_instructions": "<redacted>",
    "history_mode": "paginated",
    "context_window": "<redacted>"
  }
}
```

### 2.6 Counting without double counting

What the data shows:

- **`total_token_usage` is not a safe base.** It decreases 14 times within files (after compaction).
  Subagent files can also start from the **parent's** cumulative total: one subagent file whose own
  responses sum to 233K reports a cumulative 18.8M. Codex's own `threads.tokens_used`
  equals this cumulative value, so it doesn't measure consumption either.
- **`last_token_usage` misses some responses.** 50 `token_usage_record`s have no matching `token_count`
  (two responses, one event), so Σ`last_token_usage` < Σrecords in about 30 files. `token_count` is
  also sometimes emitted twice with identical totals.
- **`response_id` never repeats** across files (3,832 records, 0 repeats), so forks and subagents don't
  replay usage.

**Proposed rule:**
1. **Files with at least one `token_usage_record`:** one usage row per record, keyed by `response_id`.
   `token_count` is read only for `rate_limits`.
2. **Files with none** (older CLI; 1 native file here): fall back to `token_count.info.last_token_usage`,
   skipping any event whose `total_token_usage` equals the previous event's. The key is
   `<thread_id>:tc:<sha1(timestamp + last_token_usage)>`.
3. **Skip imported sessions** (2.7).

| JSON path (`token_usage_record.payload`) | Column | Notes |
|---|---|---|
| `usage.input_tokens` − `usage.cached_input_tokens` | `input` | OpenAI's `input_tokens` **includes** cached tokens (cached ≤ input on all 3,832 records). Subtracting puts `input` on the same footing as Claude's: non-cached only |
| `usage.cached_input_tokens` | `cache_read` | |
| `usage.cache_write_input_tokens` | `cache_write` | The field exists but is always 0 here |
| `usage.output_tokens` | `output` | Includes reasoning |
| `usage.reasoning_output_tokens` | `reasoning` | A subset of `output` |
| `usage.total_tokens` | (sanity check) | Equals `input_tokens + output_tokens` on every record |
| `session_id` | `session_id` | Always the **root** thread. For guardian and spawned subagents it is the parent's id (552 of 553), so subagents don't inflate session counts |
| `response_id` | `message_id` | |
| top-level `timestamp` | `timestamp` | |
| (joined) `turn_context.model` | `model` | |

### 2.7 Imported sessions: these must be skipped

**45 rollout files are copies of Claude Code transcripts.** Codex Desktop imported them
(`~/.codex/external_agent_session_imports.json`; every `records[].source_path` is under
`~/.claude/projects`).

- All lines in these files are stamped at import time.
- Each holds a single synthetic `token_count` with no `rate_limits`, and no `turn_context`.
- Counting them would record Claude usage as Codex usage, on the wrong day.

**Detection:**
- (a) The thread id is listed in `records[].imported_thread_id`.
- (b) Fallback: the file has no `turn_context`, no `token_usage_record`, and no `token_count` with
  `rate_limits`.

Both methods flag exactly the same 45 files here.

### 2.8 Usage not visible locally

22 guardian (auto-review) rollouts contain no token events at all.

### 2.9 Current totals under these rules

107 threads with usage (45 imports skipped) · **478M tokens**: non-cached input 29.9M, cache read 445.3M,
cache write 0, output 2.68M (reasoning 0.80M of that).

By model: `gpt-5.6-sol` 164M · `gpt-6.1-sol` 145M · `gpt-6-astra` 110M · `gpt-6-sol` 40M ·
`codex-auto-review` 19M.

---

## 3. Rate limits

### 3.1 Codex: real values exist

`event_msg/token_count.payload.rate_limits` appears on 3,911 events (2026-09-07 to 2026-10-07 01:16Z).

| Field | Meaning | Observed |
|---|---|---|
| `limit_id` | Which limit | `"codex"` (3,896 events), or `"premium"` (15 events, both windows null). Only `"codex"` is used |
| `plan_type` | | `"plus"` or null |
| `primary.window_minutes` | 5-hour window | Always 300 |
| `primary.used_percent` | Percent used, 0–100 | A float; whole numbers in practice |
| `primary.resets_at` | Reset time | Unix seconds |
| `secondary.window_minutes` | Weekly window | Always 10,080 |
| `secondary.used_percent`, `secondary.resets_at` | Same as primary | |
| `credits` | `{has_credits, unlimited, balance}` | `false`, `false`, `"0"` |
| `rate_limit_reached_type`, `spend_control_reached`, `individual_limit`, `limit_name` | | Always null here |

How to read it:

- **Jitter.** `resets_at` varies by a few seconds between events (e.g. 18:14:42, :47, :48). Values
  within ±120 s count as the same window.
- **Non-monotonic percentages.** In 22 windows `used_percent` dips and rises across events, because
  parallel threads interleave. Use the **newest event by timestamp across all files**, not per file.
- **Staleness.** The newest value right now is from 2026-10-07T01:16Z (5h: 88%, weekly: 65%), about
  21 hours old. Once `resets_at` has passed, the UI shows "reset since last update" instead of the
  old percentage.

### 3.2 Claude Code: a real reset time, but only when a limit is hit

No transcript has a usage percentage or remaining quota. What does exist is this: when a request is
rejected, Claude Code writes a synthetic assistant line with `quotaLimits`.

```json
{
  "parentUuid": "9a572e86…",
  "isSidechain": false,
  "type": "assistant",
  "uuid": "3f07a038…",
  "timestamp": "2026-10-07T03:48:20.753Z",
  "message": {
    "id": "7d3b5b06…",
    "model": "<synthetic>",
    "role": "assistant",
    "stop_reason": "stop_sequence",
    "stop_sequence": "<redacted:0 chars>",
    "type": "message",
    "usage": {
      "output_tokens_details": null,
      "input_tokens": 0,
      "output_tokens": 0,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 0,
      "server_tool_use": {
        "web_search_requests": 0,
        "web_fetch_requests": 0
      },
      "service_tier": null,
      "cache_creation": {
        "ephemeral_1h_input_tokens": 0,
        "ephemeral_5m_input_tokens": 0
      },
      "inference_geo": null,
      "iterations": null,
      "speed": null,
      "fallback_credit": null
    },
    "content": [
      {
        "type": "text",
        "text": "<redacted: \"You've hit your session limit · resets H:MMam (Europe/Berlin)\">"
      }
    ]
  },
  "requestId": "req_011C…",
  "quotaLimits": {
    "status": "rejected",
    "resetsAt": 1791353400,
    "unifiedRateLimitFallbackAvailable": false,
    "rateLimitType": "five_hour",
    "overageStatus": "rejected",
    "overageDisabledReason": "out_of_credits",
    "upgradePaths": [
      "upgrade_plan"
    ],
    "isUsingOverage": false
  },
  "error": "rate_limit",
  "isApiErrorMessage": true,
  "apiErrorStatus": 429,
  "perTurnEffort": "<redacted:6 chars>",
  "userType": "external",
  "entrypoint": "claude-desktop",
  "cwd": "<redacted>",
  "sessionId": "18622ff9…",
  "version": "2.1.289",
  "gitBranch": "<redacted>"
}
```

- 4 such lines, covering 2 distinct windows (Oct 5 and Oct 7). The only `rateLimitType` seen is
  `"five_hour"`; no weekly type was ever recorded.
- A 3rd limit hit (Aug 3, older Claude Code) has only the message text ("resets 8pm (Europe/Berlin)"),
  with no `quotaLimits`.
- `cost-state` and `system` lines contain no limit information. **There is no weekly-limit data for
  Claude Code anywhere locally.**

### 3.3 Testing the 5-hour estimate against the 3 real resets

| Real window (UTC) | First local activity | ccusage (floor to hour) | Exact first message | Floor to 10 min |
|---|---|---|---|---|
| Oct 5, 09:30–14:30 | 09:32:57 | no window found | 2m57s late | **exact** |
| Oct 7, 01:10–06:10 | 01:17:55 | 4h50m late (wrong window) | 7m55s late | **exact** |
| Aug 3, 13:00–18:00 (from "8pm" text) | 13:03:06 | exact | 3m late | **exact** |

Flooring to 5 or 15 minutes fails the Oct 7 case; 10 minutes matches all three.

**Proposed estimate:**
- `start = floor_10min(first user/assistant event at or after the previous window's end)`.
- `reset = start + 5h`.
- When a `quotaLimits.resetsAt` exists, it is ground truth for that window (`start = resetsAt − 5h`).
- Always labeled "estimate". There are only 3 samples, and claude.ai chat shares the same limit without
  appearing in local logs, so a real window can start before any local activity.

**A miss, observed 2026-10-08.** The Claude desktop app's usage card reported a window from 21:10 to
02:10 UTC. The estimate gave 21:30 (first local Claude Code activity at 21:3x UTC, floored), so it was
20 minutes late. The real reset time is still a multiple of 10 minutes. Something outside
`~/.claude/projects` started the window, such as claude.ai or the desktop app's chat. The usage card's
percentages turned out to be recorded locally (section 3.4), though without reset times.

### 3.4 The Claude desktop app's usage record

`~/Library/Application Support/Claude/plan-usage-history.json` (474 samples from 2026-09-09 to
2026-10-09 on this machine). Undocumented, written by the Claude desktop app.

```json
{"version":2,"samples":[
  {"t":1791499740000,"org":"<uuid>","u":{"fh":0,"sd":32,"xu":0}}
]}
```

| Field | Meaning |
|---|---|
| `t` | When the sample was recorded, Unix milliseconds |
| `org` | Organization UUID; one value here |
| `u.fh` | 5-hour window, percent used (whole numbers, as on the usage card) |
| `u.sd` | Weekly ("seven day") window, percent used |
| `u.xu` | Present on some samples, always 0 here; probably extra usage. Ignored |

How to read it:

- **No reset times.** The 5-hour reset comes from the local estimate (3.3). A weekly reset shows as
  `sd` falling (e.g. 80 at 2026-10-08 06:57 local, 0 at 09:10; the usage card then said "Resets Thu
  9:00 AM"), so the window runs 7 days from the first sample after the fall. Weekly resets were not
  always 7 days apart (2026-10-01, 10-06, 10-08), so later ones still need that sample.
- **Irregular sampling.** About every 15 minutes while the app is open, with gaps of hours otherwise.
  The newest sample on 2026-10-09 01:37 local was from 00:49, so the UI shows its age.
- **`fh` of 0 outside a window.** It is rounded down, so 0 can also mean under 1%.
- **Tokens do not map to percent.** On 2026-10-08, 82.8M Claude Code tokens moved `sd` by 9 points in
  one window, and 164.8M tokens since the weekly reset gave 32%: cache reads count far less, and
  claude.ai use counts too.

---

## 4. Skills

### 4.1 Where each tool loads skills from (verified)

**Claude Code**
- `~/.claude/skills/<name>/SKILL.md`, **one level only**, following symlinks.
  - Evidence: this session's loaded skill list has the 5 top-level entries (`anti-defensive-writing`,
    `paper-poster`, `research-paper-writing`, plus the symlinks `literature-review` and
    `surveying-literature`).
  - It has none of the 9 nested `claude-skills-research/*` skills.
- Project-level `.claude/skills/`: none found under `~/Desktop` (depth ≤ 4). They will still be
  discovered per project at runtime.
- `~/.claude/skills/research-co-pilot/` is a **git-cloned plugin repo** (it has
  `.claude-plugin/plugin.json`, v0.11.4), not a skill folder. `claude-skills-research/` is a git-cloned
  bundle of 9 nested skills.
- `~/.claude/plugins/marketplaces/claude-plugins-official/` holds 31 SKILL.md files, but it is a
  marketplace **catalog clone**. `settings.json` has no `enabledPlugins`, so none of them are installed.
- Skills managed by the desktop app live in
  `~/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/…/skills/` (23).
  They are app-owned: show them read-only.

**Codex 0.160.0** (verified from the skill list Codex injected into a real session on Oct 7)

| Alias in the log | Root |
|---|---|
| r0 | `~/.codex/skills` |
| r1 | `~/.agents/skills` |
| r2 | `~/.codex/skills/.system` (bundled: imagegen, openai-docs, review-agent, skill-creator, skill-installer) |
| r3–r10 | `~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/skills` |

- **Loading is recursive.** Nested skills such as `~/.agents/skills/claude-skills-research/comparing-papers/SKILL.md`
  and `research-co-pilot/skills/*/SKILL.md` were loaded.
- **The same name in two roots is listed twice:** `anti-defensive-writing` (r0 and r1), `survey-writing`
  (r0 and r10).
- **SKILL.md skills are supported** in your installed version.

### 4.2 Frontmatter requirements

**Codex.** These rules come from the bundled skill-creator validator (`quick_validate.py`, embedded in
the 0.160.0 binary):
- Required: `name`, `description`.
- Allowed keys: `name`, `description`, `license`, `allowed-tools`, `metadata`.
- `name`: `^[a-z0-9-]+$`, no leading, trailing, or doubled hyphen, at most 64 characters.
- `description`: a string of at most 1024 characters, with no `<` or `>`, not starting with `[TODO:`.
- The **runtime is more lenient** than this validator: skills with `argument-hint` and other extra keys
  were still loaded.

**Claude Code.** I found these keys together next to the skill-frontmatter parser in the 2.1.251 binary:
`name`, `description`, `allowed-tools`, `argument-hint`, `disable-model-invocation`, `user-invocable`,
`when_to_use`, `model`, `effort`, `context`, `agent`, `hooks`, `paths`, `shell`, `version`, `license`,
`metadata`. I did not find a hard charset or length rule for `name` or `description` in the binary.

**Proposed checks:**
- **Error (both tools):** frontmatter missing or unparseable; `name` or `description` missing.
- **Warning (Codex):** keys outside Codex's allowed set; `description` over 1024 characters or containing
  `<` or `>`; `name` not hyphen-case or longer than 64.
- **Warning (both):** directory name differs from `name`.
- **Info:** Claude-only keys (`argument-hint`, `disable-model-invocation`, `user-invocable`, …) do nothing
  in Codex.

### 4.3 Current inventory (SKILL.md files)

| Root | Count | Notes |
|---|---|---|
| `~/.claude/skills` | 27 (5 loaded by Claude Code) | 3 symlinks; 2 git repos |
| `~/.agents/skills` | 27 | Edited copies of the Claude ones, plus a stray `.zip` and `.DS_Store` |
| `~/.codex/skills` | 5, plus 5 in `.system` | |
| `~/.claude/plugins` (catalog only) | 31 | Not installed |
| `~/.codex/plugins/cache` | 50 | Provided by plugins |

What import will run into:
- **Identical across roots:** `anti-defensive-writing` (3 copies), `paper-poster`, `research-paper-writing`,
  `running-cluster-experiments`, and `survey-writing` (Codex root plus a personal plugin).
- **Same name, different content: 23.** All 15 `research-co-pilot` skills, plus 8 of the 9
  `claude-skills-research` skills, differ between `~/.claude/skills` and `~/.agents/skills`. Import asks
  you about each one, as specified.
- **Plugin skills that fail Codex's own name rule:** `Presentations` and `Spreadsheets` (capitalized),
  and `writing-hookify-rules` (its directory is named `writing-rules`). These are read-only; they will
  just show a flag.

---

## 5. GitHub

- **`gh` is not installed.** Pushing doesn't need it: git over HTTPS uses `osxkeychain`, which already
  holds a `github.com` credential. I made **no network calls**, so the credential is unverified.
- **Profile repo:** `YilongWangBerlin/YilongWangBerlin`, branch `main`, 2 commits.
  - The file is named **`readme.md` (lowercase)**, so AgentDeck must find the README case-insensitively.
  - No `agentdeck` markers exist yet.
- **Pages:** `YilongWangBerlin/yilongwangberlin.github.io` (user site), plain static HTML, no Actions
  workflows, branch `main`.
  - Its working copy has **12 uncommitted changes**.
  - So AgentDeck will **never push from your working copies**. It will keep its own clones under
    `~/.agentdeck/publish/<repo>/`.

---

## 6. Normalized usage row

| Column | Claude Code | Codex |
|---|---|---|
| `source` | `claude_code` | `codex` |
| `session_id` | `sessionId` | `token_usage_record.session_id` (root thread) |
| `timestamp` (UTC) | line `timestamp` | line `timestamp` |
| `model` | `message.model` | `turn_context.model` (joined by `turn_id`) |
| `input` (non-cached) | `usage.input_tokens` | `input_tokens − cached_input_tokens` |
| `output` | `usage.output_tokens` | `output_tokens` |
| `cache_read` | `usage.cache_read_input_tokens` | `cached_input_tokens` |
| `cache_write` | `usage.cache_creation_input_tokens` | `cache_write_input_tokens` |
| `reasoning` (subset of output) | `usage.output_tokens_details.thinking_tokens` | `reasoning_output_tokens` |
| `message_id` (dedup) | `message.id:requestId` | `response_id` |

`total = input + output + cache_read + cache_write`. `reasoning` is never added a second time.

Local-day aggregation: convert each UTC timestamp to `TimeZone.current` (now `Europe/Berlin`) when
querying, never when storing. No DST change falls inside the current history, but the next one is
2026-10-25, so tests will cover both directions (23-hour and 25-hour days).

---

## 7. Not found / not verified

- **Claude Code weekly limit:** Claude Code's logs have none; the Claude app's record (3.4) does.
- **Claude reset times:** the Claude app's record has none, so they are inferred (3.4).
- **The 10-minute floor** is inferred from 3 samples. Each new `quotaLimits` line will be logged so the
  rule can be re-checked.
- **Claude Code's handling of unknown frontmatter keys** was not tested at runtime.
- **The GitHub credential** was not tested. Testing it needs a network call, and I made none.

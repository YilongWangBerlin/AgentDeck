# AgentDeck

A local macOS companion for Claude Code and OpenAI Codex: token usage, rate-limit windows in the menu
bar, shared skills, and opt-in publishing of aggregate stats to GitHub.

AgentDeck reads the tools' logs read-only and stores what it parsed in `~/.agentdeck/agentdeck.sqlite`,
so history survives Claude Code's 30-day transcript cleanup. It sends no telemetry and uses no
undocumented APIs. The only network traffic will be git pushes for publishing, and only once you turn
that on.

## Status

| Step | | |
|---|---|---|
| 0 | Real log formats, documented in [FORMATS.md](FORMATS.md) | done |
| 2 | Parser package with tests ([Packages/AgentDeckParsing](Packages/AgentDeckParsing)) | done |
| 3 | SQLite store, incremental ingestion, FSEvents | done |
| 4 | Menu bar with 5-hour and weekly windows | done |
| 5 | Dashboard (export image comes with step 7) | done |
| 6 | Skills management: library, import with backups, per-tool links | done |
| 7 | GitHub publishing: profile card, Pages data, schedule, preview | done |

Counting rules and other choices are in [DECISIONS.md](DECISIONS.md).

## Build

Needs macOS 14+ and Swift 6 (the Command Line Tools are enough; Xcode is not required).

```bash
scripts/build-app.sh
```

```bash
open dist/AgentDeck.app
```

```bash
swift test
```

## Menu bar

`CC ~54M 2h47  CX 88% 3h05` means:
- Claude Code has used about 54M tokens in its current 5-hour window, which resets in 2 h 47 min.
- Codex reports 88% of its 5-hour window used, resetting in 3 h 05 min.

Claude Code logs no limits, so its window is an estimate (marked `~`). Its percentage comes from the
times Claude Code stopped you: each refusal marks 100%, and the median of the tokens used up to the
recent refusals is taken as the limit. Nothing to set up, and it stays an estimate. Codex values are exactly what Codex logged, with the time of its
last report.

## Window and widget

- **Window:** the window button next to "Scanned" in the dropdown, or opening AgentDeck again from
  Finder or Spotlight, shows the same tabs in a resizable window. AgentDeck appears in the Dock
  while it is open.
- **Desktop widget:** right-click the desktop, choose Edit Widgets, and search for AgentDeck. Small,
  medium and large sizes show both tools' windows and two weeks of daily tokens. The widget is
  sandboxed and reads only `~/.agentdeck/widget/snapshot.json`, which the app keeps up to date.

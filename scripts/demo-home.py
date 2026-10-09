#!/usr/bin/env python3
"""Builds a stand-in home directory full of made-up usage, for screenshots.

    scripts/demo-home.py /tmp/agentdeck-demo
    .build/debug/AgentDeck --render-menu out.png --db /tmp/demo.sqlite --home /tmp/agentdeck-demo \
        --now 2026-10-09T13:30:00Z --limits

Writes Claude Code transcripts, Codex rollouts (with rate limits), the Claude app's usage record and a
small skill library, in the same formats as the real files (FORMATS.md). Nothing here comes from a
real machine: projects, sessions and numbers are generated from a fixed seed, so every run is the same.
"""

import hashlib
import json
import random
import shutil
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

NOW = datetime(2026, 10, 9, 13, 30, tzinfo=timezone.utc)
DAYS = 200
rng = random.Random(20261009)

PROJECTS = ["aurora", "tidepool", "lumen-api", "field-notes", "orbit-cli", "paper-trail"]
CLAUDE_MODELS = [  # (model, first day it appears, weight)
    ("claude-opus-5-5", 40, 5.0),
    ("claude-opus-5", 200, 2.5),
    ("claude-sonnet-5", 200, 1.5),
    ("claude-haiku-4-5", 200, 0.3),
]
CODEX_MODELS = [("gpt-6.1-sol", 60, 3.0), ("gpt-6-sol", 200, 1.5), ("gpt-6-astra", 120, 1.0)]


def iso(t):
    return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def pick(models, days_ago):
    choices = [(m, w) for m, first, w in models if days_ago <= first]
    total = sum(w for _, w in choices)
    r = rng.uniform(0, total)
    for m, w in choices:
        r -= w
        if r <= 0:
            return m
    return choices[-1][0]


def uid():
    return str(uuid.UUID(int=rng.getrandbits(128), version=4))


def day_intensity(day):
    """0 on days off; otherwise grows over the months, lighter at weekends."""
    days_ago = (NOW.date() - day).days
    weekend = day.weekday() >= 5
    if rng.random() < (0.55 if weekend else 0.18):
        return 0
    growth = 0.35 + 0.65 * (1 - days_ago / DAYS) ** 1.6
    return growth * (0.45 if weekend else 1) * rng.uniform(0.5, 1.4)


def session_start(day, intensity):
    hour = rng.choice([9, 10, 10, 11, 11, 14, 15, 16, 20, 21, 22, 22, 23])
    return datetime(day.year, day.month, day.day, hour, rng.randrange(60), rng.randrange(60), tzinfo=timezone.utc)


# --- Claude Code -----------------------------------------------------------------------------------

def claude_session(root, start, responses, days_ago):
    project = rng.choice(PROJECTS)
    cwd = f"/Users/demo/projects/{project}"
    folder = root / ".claude" / "projects" / cwd.replace("/", "-")
    folder.mkdir(parents=True, exist_ok=True)
    session = uid()
    model = pick(CLAUDE_MODELS, days_ago)
    lines, t, context, parent = [], start, rng.randint(18_000, 40_000), None
    for i in range(responses):
        if i == 0 or rng.random() < 0.18:
            user = uid()
            lines.append({"parentUuid": parent, "isSidechain": False, "type": "user",
                          "message": {"role": "user", "content": "demo prompt"}, "origin": {"kind": "human"},
                          "uuid": user, "timestamp": iso(t), "cwd": cwd, "sessionId": session, "version": "2.1.290"})
            parent = user
            t += timedelta(seconds=rng.randint(2, 6))
        written = rng.randint(200, 6000)
        context = min(context + written, 600_000)
        line = uid()
        lines.append({"parentUuid": parent, "isSidechain": False, "type": "assistant",
                      "message": {"model": model, "id": f"msg_{uid()}", "type": "message", "role": "assistant",
                                  "content": [{"type": "text", "text": "demo"}], "stop_reason": "end_turn",
                                  "usage": {"input_tokens": rng.randint(1, 8), "cache_creation_input_tokens": written,
                                            "cache_read_input_tokens": context, "output_tokens": rng.randint(80, 2400)}},
                      "requestId": f"req_{uid()}", "uuid": line, "timestamp": iso(t), "cwd": cwd,
                      "sessionId": session, "version": "2.1.290"})
        parent = line
        t += timedelta(seconds=rng.randint(4, 40))
    with open(folder / f"{session}.jsonl", "w") as f:
        f.writelines(json.dumps(l) + "\n" for l in lines)
    return t


# --- Codex -----------------------------------------------------------------------------------------

def codex_session(root, start, responses, days_ago, limits=None):
    thread = uid()
    folder = root / ".codex" / "sessions" / start.strftime("%Y/%m/%d")
    folder.mkdir(parents=True, exist_ok=True)
    model = pick(CODEX_MODELS, days_ago)
    cwd = f"/Users/demo/projects/{rng.choice(PROJECTS)}"
    lines = [{"timestamp": iso(start), "type": "session_meta",
              "payload": {"id": thread, "session_id": thread, "timestamp": iso(start), "cwd": cwd,
                          "originator": "codex_cli", "cli_version": "0.161.0", "source": "cli", "model_provider": "openai"}},
             {"timestamp": iso(start), "type": "turn_context",
              "payload": {"turn_id": "turn-1", "cwd": cwd, "model": model, "effort": "high"}}]
    t, context, total = start + timedelta(seconds=3), rng.randint(15_000, 30_000), 0
    for i in range(responses):
        context = min(context + rng.randint(500, 5000), 350_000)
        output = rng.randint(100, 1800)
        usage = {"input_tokens": context, "cached_input_tokens": int(context * rng.uniform(0.6, 0.92)),
                 "cache_write_input_tokens": 0, "output_tokens": output,
                 "reasoning_output_tokens": int(output * 0.4), "total_tokens": context + output}
        total += context + output
        lines.append({"timestamp": iso(t), "type": "token_usage_record",
                      "payload": {"thread_id": thread, "turn_id": "turn-1", "session_id": thread,
                                  "response_id": f"resp_{uid()}", "usage": usage}})
        t += timedelta(seconds=rng.randint(5, 50))
    event = {"type": "token_count", "info": {"last_token_usage": usage}}
    if limits:
        event["rate_limits"] = limits
    lines.append({"timestamp": iso(t), "type": "event_msg", "payload": event})
    name = f"rollout-{start.strftime('%Y-%m-%dT%H-%M-%S')}-{thread}.jsonl"
    with open(folder / name, "w") as f:
        f.writelines(json.dumps(l) + "\n" for l in lines)
    return t


# --- The Claude app's usage record and the skill library ------------------------------------------

def plan_usage(root):
    samples = []

    def add(t, fh, sd):
        samples.append({"t": int(t.timestamp() * 1000), "org": "00000000-0000-4000-8000-000000000000",
                        "u": {"fh": fh, "sd": sd}})

    reset = datetime(2026, 10, 8, 7, 0, tzinfo=timezone.utc)
    add(reset - timedelta(hours=3), 64, 88)
    add(reset + timedelta(minutes=10), 0, 0)
    for minutes, fh, sd in [(240, 22, 6), (420, 71, 14), (660, 0, 15), (900, 38, 19)]:
        add(reset + timedelta(minutes=minutes), fh, sd)
    window = datetime(2026, 10, 9, 11, 40, tzinfo=timezone.utc)
    for i, fh in enumerate([6, 15, 24, 31, 37, 42, 46]):
        add(window + timedelta(minutes=15 * i + 5), fh, 22 + i)
    path = root / "Library" / "Application Support" / "Claude"
    path.mkdir(parents=True, exist_ok=True)
    (path / "plan-usage-history.json").write_text(json.dumps({"version": 2, "samples": samples}))


SKILLS = {
    "commit-message": "Write a commit message from the staged diff.",
    "pr-review": "Review a pull request for correctness and clarity.",
    "release-notes": "Draft release notes from merged pull requests.",
    "test-writer": "Write focused tests for a function or module.",
    "api-docs": "Document an HTTP API from its handlers.",
    "sql-explain": "Explain a slow SQL query and suggest indexes.",
    "ui-polish": "Tighten spacing, type and color in a UI.",
    "changelog": "Keep CHANGELOG.md in Keep a Changelog format.",
}
ENABLED = {"commit-message": "both", "pr-review": "both", "release-notes": "claude", "test-writer": "both",
           "api-docs": "codex", "sql-explain": "claude", "ui-polish": "both"}


def content_hash(folder):
    """SkillScanner.contentHash: SHA-256 over each file's relative path and bytes, in path order."""
    digest = hashlib.sha256()
    for path in sorted(p for p in folder.rglob("*") if p.is_file() and p.name not in (".DS_Store", ".agentdeck-managed.json")):
        digest.update(("/" + str(path.relative_to(folder))).encode() + b"\0")
        digest.update(path.read_bytes() + b"\0")
    return digest.hexdigest()


def skills(root):
    library = root / ".agentdeck" / "skills"
    for name, description in SKILLS.items():
        folder = library / name
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "SKILL.md").write_text(f"---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n\n{description}\n")
    # Claude Code gets a marked copy and Codex a link, as AgentDeck itself sets them up.
    for name, where in ENABLED.items():
        if where in ("claude", "both"):
            copy = root / ".claude" / "skills" / name
            shutil.copytree(library / name, copy)
            (copy / ".agentdeck-managed.json").write_text(json.dumps({"name": name, "hash": content_hash(copy)}))
        if where in ("codex", "both"):
            (root / ".codex" / "skills").mkdir(parents=True, exist_ok=True)
            (root / ".codex" / "skills" / name).symlink_to(library / name)
    subprocess.run(["git", "init", "-q", str(library)], check=True)
    subprocess.run(["git", "-C", str(library), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(library), "-c", "user.name=demo", "-c", "user.email=demo@example.com",
                    "commit", "-q", "-m", "Demo skills"], check=True)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = Path(sys.argv[1])
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)

    for days_ago in range(DAYS, 0, -1):
        day = (NOW - timedelta(days=days_ago)).date()
        intensity = day_intensity(day)
        if not intensity:
            continue
        for _ in range(max(1, round(intensity * rng.uniform(2, 5)))):
            claude_session(root, session_start(day, intensity), int(intensity * rng.randint(30, 140)) + 5, days_ago)
        for _ in range(round(intensity * rng.uniform(0, 3))):
            codex_session(root, session_start(day, intensity), int(intensity * rng.randint(20, 90)) + 5, days_ago)

    # Today: a Claude window that began at 11:40 and Codex limits reported a few minutes ago.
    t = datetime(2026, 10, 9, 11, 41, 12, tzinfo=timezone.utc)
    while t < NOW - timedelta(minutes=8):
        t = claude_session(root, t, rng.randint(40, 90), 0) + timedelta(minutes=rng.randint(2, 9))
    limits = {"limit_id": "codex", "plan_type": "plus",
              "primary": {"used_percent": 38.0, "window_minutes": 300, "resets_at": int(datetime(2026, 10, 9, 15, 20, tzinfo=timezone.utc).timestamp())},
              "secondary": {"used_percent": 41.0, "window_minutes": 10080, "resets_at": int(datetime(2026, 10, 14, 8, 5, tzinfo=timezone.utc).timestamp())}}
    codex_session(root, datetime(2026, 10, 9, 10, 25, tzinfo=timezone.utc), 70, 0)
    codex_session(root, datetime(2026, 10, 9, 12, 52, tzinfo=timezone.utc), 40, 0, limits)

    plan_usage(root)
    skills(root)
    print(f"demo home ready: {root}")


if __name__ == "__main__":
    main()

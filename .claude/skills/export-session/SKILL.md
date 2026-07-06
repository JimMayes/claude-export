---
name: export-session
description: Export the current (or any past) Claude Code session transcript to a file. Defaults to clean, readable Markdown (safe to share); an opt-in --full flag produces the complete text transcript with every command and tool output. Use when the user asks to export, save, or archive the session/conversation, or when another skill or workflow needs the transcript written to disk.
---

# Export session

Scriptable replacement for the native `/export` command. Reads the session's
JSONL transcript from `~/.claude/projects/` directly, so it can run
non-interactively (from a skill, a workflow, or Claude mid-session) and write
anywhere. Requires **Ruby 3.4+** (tested on 3.4 and 4.0); stdlib only.

## How to run

```bash
ruby <path-to-this-skill>/scripts/export_session.rb [options]
```

(`<path-to-this-skill>` is wherever this SKILL.md lives —
`.claude/skills/export-session` in a project, or
`~/.claude/skills/export-session` if installed globally.)

**Ruby version:** the script needs **Ruby 3.4+**. Before running, check
`ruby --version` — macOS's default `ruby` is 2.6 and will fail with parse
errors (a version guard can't help, since Ruby parses the whole file before
running). If the default is too old, invoke through the user's version
manager instead, e.g. `mise x ruby@3.4 -- ruby …`, `rbenv exec ruby …`, or an
absolute Homebrew path like `/opt/homebrew/opt/ruby/bin/ruby …`.

The script prints the absolute path of the written file to stdout — always
report that path back (or pass it to the next step of a workflow).

## Two modes

- **Default (no flag): clean Markdown (`.md`).** Prose is kept as real
  Markdown (renders in Obsidian etc.); tool calls collapse to a one-line
  summary like `*Ran 4 shell commands.*`; tool **output** and thinking are
  dropped. Because it contains no command lines or command output, it does
  **not** surface credentials — safe for notes and sharing. This is the
  right default for almost every request.
- **`--full`: complete transcript (`.txt`).** Every message, every tool call
  **with its arguments**, and full tool output. This CAN contain secrets
  (env dumps, tokens in commands, `.env` contents). The script prints a
  warning to stderr when `--full` is used.

**When you run `--full` on the user's behalf, tell them the export contains
full command output and may include credentials, so they should review it
before sharing or syncing it** (e.g. into a git repo or cloud-synced vault).

## Options

- (no args) — clean Markdown of the **current session** (via
  `$CLAUDE_CODE_SESSION_ID`) to the configured destination (see below).
- `--full` — complete `.txt` transcript instead of clean Markdown.
- `--out <dir>/` — write into that directory, auto-named. Created if missing.
- `--out <file>` — exact output path (extension is yours to choose).
- `--session <uuid|path>` — export a different session (id or `.jsonl` path).
- `--no-thinking` — omit thinking blocks (`--full` only).
- `--max-result-lines N` — truncate each tool result to N lines (`--full` only).
- `--stdout` — print instead of writing a file.
- `--force` — overwrite an existing `--out` file (refused otherwise;
  auto-named exports never collide, they get a `-2`, `-3`, … suffix).

## Default destination

When `--out` is omitted, the script resolves the destination itself:
`$CLAUDE_EXPORT_DIR` env var, then `env.CLAUDE_EXPORT_DIR` from the project's
`.claude/settings.local.json` / `.claude/settings.json`, then cwd. Relative
paths resolve against the project root.

**First-run flow — when no destination is given or configured:** if the user
didn't specify a destination AND `$CLAUDE_EXPORT_DIR` is unset AND neither
settings file has `env.CLAUDE_EXPORT_DIR`, don't just export to cwd. Ask the
user (AskUserQuestion) whether to set a project default, recommending
`claude-sessions`; let them accept, name a different directory, or decline.
If they accept, merge into `.claude/settings.json` (preserve all existing
keys; only add/update `env.CLAUDE_EXPORT_DIR`):

```json
{"env": {"CLAUDE_EXPORT_DIR": "claude-sessions"}}
```

Then run the export (the script reads the setting from settings.json
immediately; Claude Code injects it as a real env var from the next session
on). If they decline, export to cwd without asking again this session.

## Notes

- If the user gave a destination, pass it as `--out`. Otherwise run with no
  `--out` so the configured default applies. To change the default, update
  `env.CLAUDE_EXPORT_DIR` in `.claude/settings.json`.
- The export covers the conversation up to the moment the script runs — so
  everything except the turn currently being generated.
- Subagent (sidechain) messages are excluded, matching the native view.
- For composite workflows (e.g. distill-then-export), run the script first to
  get the path, then reference that path in generated documents.

---
name: export-session
description: Export the current (or any past) Claude Code session transcript to a text file, replicating the native /export format and filename convention. Use when the user asks to export, save, or archive the session/conversation to a file, or when another skill or workflow needs the session transcript written to disk.
---

# Export session

Scriptable replacement for the native `/export` command. Reads the session's
JSONL transcript from `~/.claude/projects/` and writes a readable text file in
the native export style (`> ` user, `⏺ ` assistant/tools, `⎿` results) with
the native filename convention (`YYYY-MM-DD-HHMMSS-<first-prompt-slug>.txt`).

## How to run

```bash
python3 <path-to-this-skill>/scripts/export_session.py [options]
```

(`<path-to-this-skill>` is wherever this SKILL.md lives —
`.claude/skills/export-session` in a project, or
`~/.claude/skills/export-session` if installed globally.)

The script prints the absolute path of the written file — always report that
path back (or pass it on to the next step of a larger workflow).

## Options

- (no args) — exports the **current session** (via `$CLAUDE_CODE_SESSION_ID`)
  to the current directory with the native-style auto-generated filename.
- `--out <dir>/` — write into that directory, auto-named. Directory is created
  if missing. Use this when the user or a calling workflow names a destination
  directory (e.g. `docs/sessions/`).
- `--out <file>.txt` — exact output file.
- `--session <uuid|path>` — export a different session (a session id, or a
  direct path to a `.jsonl` transcript).
- `--no-thinking` — omit thinking blocks.
- `--max-result-lines N` — truncate each tool result to N lines (default:
  keep everything).
- `--stdout` — print the transcript instead of writing a file.
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
keys; only add/update the `env.CLAUDE_EXPORT_DIR` entry):

```json
{"env": {"CLAUDE_EXPORT_DIR": "claude-sessions"}}
```

Then run the export (the script reads the setting from settings.json
immediately; Claude Code injects it as a real env var from the next session
on). If they decline, export to cwd without asking again this session.

## Notes

- If the user gave a destination in their request, pass it as `--out`.
  Otherwise run with no `--out` so the configured default applies. If the
  user asks to change the default destination, update `env.CLAUDE_EXPORT_DIR`
  in `.claude/settings.json`.
- The export includes the conversation up to the moment the script runs, so
  it will contain everything except the turn currently being generated.
- Subagent (sidechain) messages are excluded, matching the native transcript
  view.
- For composite workflows (e.g. distill-then-export), run this script first to
  get the transcript path, then reference that path in generated documents.

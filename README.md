# claude-export

A scriptable `/export` for Claude Code. Exports any session transcript to a
readable text file — from a slash command, a script, another skill, or Claude
itself mid-conversation.

## Why

Claude Code's native `/export` is UI-only: Claude can't invoke it, headless
mode (`claude -p`) refuses it, and scripts can't reach it. That makes it a
dead end for automation — you can't build a workflow that, say, distills a
session into notes and archives the full transcript alongside them.

This skill removes that limitation. As a bonus, its exports are more complete
than the native ones: `/export` renders the terminal UI, which collapses all
tool activity into placeholders like `Ran 4 shell commands (ctrl+o to
expand)`. This exporter works from the raw session data, so tool commands and
their full output are preserved.

## Install

Requires `python3` (preinstalled on macOS and virtually all Linux distros).

**For one project** — copy the skill into the project:

```bash
mkdir -p .claude/skills
cp -r <this-repo>/.claude/skills/export-session .claude/skills/
```

**For every project** — install it globally instead:

```bash
cp -r <this-repo>/.claude/skills/export-session ~/.claude/skills/
```

New skills are picked up when a session starts, so restart Claude Code
(`claude --continue` resumes your conversation) after installing.

## Use

In Claude Code:

```
/export-session                 # export this session to the configured location
/export-session to docs/logs/   # or just describe where you want it
```

Plain language works too ("export this session before we wrap up").

From the shell or a script:

```bash
python3 .claude/skills/export-session/scripts/export_session.py [options]
```

| Option | Effect |
|---|---|
| *(none)* | current session, configured default destination |
| `--out <dir>/` | write into a directory, auto-named |
| `--out <file>.txt` | exact output file |
| `--session <uuid\|path>` | export a different session |
| `--no-thinking` | omit thinking blocks |
| `--max-result-lines N` | truncate each tool result to N lines |
| `--stdout` | print instead of writing |
| `--force` | overwrite an existing `--out` file |

The script prints the absolute path of the written file, so workflows can
capture it: `path=$(python3 .../export_session.py)`.

Filenames follow the native `/export` convention:
`YYYY-MM-DD-HHMMSS-<first-user-message-slug>.txt`.

## Configure a default destination

Set `CLAUDE_EXPORT_DIR` in the `env` block of your project's
`.claude/settings.json`:

```json
{"env": {"CLAUDE_EXPORT_DIR": "claude-sessions"}}
```

Relative paths resolve against the project root, so exports land in the same
place from any subdirectory. Resolution order: `--out` argument →
`$CLAUDE_EXPORT_DIR` → `env.CLAUDE_EXPORT_DIR` read from
`.claude/settings.local.json` / `.claude/settings.json` → current directory.

If nothing is configured, the skill offers to set this up the first time you
invoke it (suggesting `claude-sessions/`).

## Output format

The native transcript style, unwrapped and complete:

```
> the user's message

⏺ the assistant's reply

⏺ Bash(ls -la)
  ⎿  total 56
     drwxr-xr-x  4 user staff  128 Jul  5 14:18 .
```

Tool output is scrubbed of ANSI escapes and control characters, so exports
are always clean UTF-8 text.

## How it works

Claude Code persists every session as JSONL under
`~/.claude/projects/<munged-cwd>/<session-id>.jsonl` and exports the current
session's id to shell subprocesses as `$CLAUDE_CODE_SESSION_ID`. The script
reads that JSONL, reconstructs the active conversation branch (edits and
regenerations create dead branches, which are skipped), and renders it.
Subagent sidechains are excluded, matching the native transcript view.

## Caveats

- The JSONL transcript format is Claude Code internal and could change
  between versions. Built and verified against Claude Code 2.1.201.
- An export taken mid-turn contains everything up to the last completed
  message.
- Windows: `python3` isn't guaranteed there; install Python or run under WSL.

# claude-export

A scriptable `/export` for Claude Code. Exports any session transcript to a
file — from a slash command, a script, another skill, or Claude itself
mid-conversation.

## Why

Claude Code's native `/export` is UI-only: Claude can't invoke it, headless
mode (`claude -p`) refuses it, and scripts can't reach it. That blocks any
workflow that needs the transcript on disk as a step — for example, distilling
a session into notes and archiving the full transcript alongside them.

This skill removes that limitation, and produces two purpose-built formats:
a clean Markdown view for reading and sharing, and a complete text transcript
for archival.

## Install

Requires **Ruby 3.4 or newer** (tested on 3.4 and 4.0). macOS ships an older
system Ruby (2.6); install a current one with `brew install ruby`, `mise`,
`rbenv`, or `asdf`. The script uses only the standard library.

**For one project** — copy the skill in:

```bash
mkdir -p .claude/skills
cp -r <this-repo>/.claude/skills/export-session .claude/skills/
```

**For every project** — install it globally:

```bash
cp -r <this-repo>/.claude/skills/export-session ~/.claude/skills/
```

New skills are picked up when a session starts, so restart Claude Code
(`claude --continue` resumes your conversation) after installing.

## Use

In Claude Code, `/export-session` — or just ask ("export this session",
"save the full transcript to docs/").

From the shell:

```bash
ruby .claude/skills/export-session/scripts/export_session.rb [options]
```

The script prints the absolute path of the written file, so workflows can
capture it: `path=$(ruby .../export_session.rb)`.

## Two formats

**Clean Markdown (default).** Readable and shareable — drop it into an
Obsidian vault or a PR description.

- Assistant and user text kept as real Markdown (headings, code, lists render).
- Tool calls collapse to a one-line summary: `*Ran 4 shell commands.*`,
  `*Ran 5 shell commands, wrote 2 files.*`
- Tool **output** and thinking are omitted.
- YAML frontmatter (title, date, session id).

**Complete transcript (`--full`, `.txt`).** Every message, every tool call
with arguments, and full tool output, in the native `/export` visual style
(`> ` user, `⏺ ` assistant/tools, `  ⎿  ` results).

```bash
ruby .../export_session.rb              # clean Markdown -> configured default
ruby .../export_session.rb --full       # complete .txt transcript
ruby .../export_session.rb --out docs/  # into a directory (auto-named)
ruby .../export_session.rb --session <uuid|path> --stdout
```

| Option | Effect |
|---|---|
| *(none)* | clean Markdown of the current session |
| `--full` | complete `.txt` transcript (all commands + output) |
| `--out <dir>/` | write into a directory, auto-named |
| `--out <file>` | exact output path |
| `--session <uuid\|path>` | export a different session |
| `--no-thinking` | omit thinking blocks (`--full` only) |
| `--max-result-lines N` | truncate each tool result to N lines (`--full` only) |
| `--stdout` | print instead of writing |
| `--force` | overwrite an existing `--out` file |

## Credentials & safety

Session transcripts can contain secrets — an `env` dump, a token on a command
line, the contents of a `.env` file. The two formats handle this differently:

- **Clean Markdown (default) is safe by omission.** It never writes command
  lines or tool output, so there is nothing for a secret to hide in — the same
  reason the native `/export` doesn't leak them (native collapses tool activity
  to placeholders). This is *structural*, not pattern-matching, so it has no
  false negatives.
- **`--full` can contain secrets.** It deliberately includes full commands and
  output. The script prints a warning to stderr when you use it. Treat full
  exports as sensitive: review before committing to a repo or syncing to the
  cloud.

Note the underlying JSONL in `~/.claude/projects/` already holds everything
unredacted; the risk an export adds is *relocation* to a more shareable place.

## Configuring the default destination

When `--out` is omitted, the destination is resolved in order:

1. `$CLAUDE_EXPORT_DIR` — set per-project via the `env` block of
   `.claude/settings.json`, which Claude Code injects into every session:

   ```json
   {"env": {"CLAUDE_EXPORT_DIR": "claude-sessions"}}
   ```

2. `env.CLAUDE_EXPORT_DIR` read directly from `.claude/settings.local.json` /
   `.claude/settings.json` — so a just-written setting takes effect in the same
   session, before Claude Code's env injection kicks in next start.
3. The current directory.

Relative paths resolve against the project root (nearest ancestor with
`.claude` or `.git`). Invoked with nothing configured, the skill offers to set
this up for you (suggesting `claude-sessions`).

## How it works

Claude Code persists every session as JSONL under
`~/.claude/projects/<munged-cwd>/<session-id>.jsonl` and exports the current
session's id to shell subprocesses as `$CLAUDE_CODE_SESSION_ID`. The script
reads that JSONL, reconstructs the active conversation branch (edits and
regenerations leave dead branches, which are skipped), and renders it. Tool
output is scrubbed of ANSI escapes and control characters so exports are always
clean UTF-8 text.

## Caveats

- The JSONL transcript format is Claude Code internal and could change between
  versions. Built and verified against Claude Code 2.1.201.
- An export taken mid-turn contains everything up to the last completed message.

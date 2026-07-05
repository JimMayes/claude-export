#!/usr/bin/env python3
"""Export a Claude Code session transcript to a readable text file.

Replicates the native /export command's conventions:
  - filename: YYYY-MM-DD-HHMMSS-<first-user-message-slug>.txt
  - format:   `> ` user messages, `⏺ ` assistant text / tool calls,
              `  ⎿  ` tool results (the terminal transcript look)

Unlike native /export it is scriptable: it reads the session's JSONL
transcript from ~/.claude/projects/ directly, so it can run from inside
a session (via $CLAUDE_CODE_SESSION_ID), target any past session, and
write to any destination.

Usage:
  export_session.py                          # current session -> ./<native-style-name>.txt
  export_session.py --out exports/           # into a directory (auto-named)
  export_session.py --out exports/foo.txt    # exact file
  export_session.py --session <uuid>         # a specific session id
  export_session.py --session path/to/x.jsonl
  export_session.py --stdout                 # print transcript instead of writing

Prints the absolute path of the written file on success.
"""

import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime

CLAUDE_PROJECTS_DIR = os.path.expanduser("~/.claude/projects")

USER_PREFIX = "> "
ASSISTANT_PREFIX = "⏺ "      # ⏺
RESULT_PREFIX = "  ⎿  "      # ⎿
RESULT_CONT = "     "
THINKING_HEADER = "✻ Thinking…"  # ✻ Thinking…


# ---------------------------------------------------------------------------
# Transcript location
# ---------------------------------------------------------------------------

SESSION_ID_RE = re.compile(r"[0-9a-fA-F-]{8,}")


def find_transcript(session):
    """Resolve a session id / path / None (current session) to a JSONL path."""
    if session and os.path.isfile(session):
        return session
    session_id = session or os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not session_id:
        sys.exit(
            "error: no session given and $CLAUDE_CODE_SESSION_ID is not set. "
            "Pass --session <uuid|path>."
        )
    if not SESSION_ID_RE.fullmatch(session_id):
        sys.exit(f"error: {session_id!r} is not a session id or an existing transcript path")
    matches = glob.glob(os.path.join(CLAUDE_PROJECTS_DIR, "*",
                                     glob.escape(session_id) + ".jsonl"))
    if not matches:
        sys.exit(f"error: no transcript found for session {session_id} under {CLAUDE_PROJECTS_DIR}")
    # If the same session id somehow exists in several project dirs, take newest.
    return max(matches, key=os.path.getmtime)


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def load_records(path: str):
    records = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return records


def is_main_message(rec):
    return rec.get("type") in ("user", "assistant") and not rec.get("isSidechain")


def conversation_chain(records: list[dict]):
    """Reconstruct the active conversation branch.

    Records form a tree via parentUuid (message edits create dead branches).
    Walk back from the last main-conversation message to the root, then
    reverse. Falls back to file order if the chain looks broken.
    """
    by_uuid: dict[str, dict] = {}
    order: list[str] = []
    for r in records:
        uid = r.get("uuid")
        if not uid:
            continue
        if uid not in by_uuid:
            order.append(uid)
        by_uuid[uid] = r  # a re-written uuid keeps its position, newest content

    messages_in_file = [by_uuid[u] for u in order if is_main_message(by_uuid[u])]
    if not messages_in_file:
        return []

    # Walk from the last MAIN message: the file's literal last record can be
    # a subagent sidechain, which belongs to a different branch of the tree.
    chain, seen = [], set()
    node = messages_in_file[-1]
    while node is not None:
        uid = node.get("uuid")
        if uid in seen:
            break
        seen.add(uid)
        chain.append(node)
        parent = node.get("parentUuid")
        node = by_uuid.get(parent) if parent else None
    chain.reverse()

    chain_msgs = [r for r in chain if is_main_message(r)]
    # If the walk lost more than half the messages, the chain metadata is
    # unreliable (e.g. resumed/compacted sessions) - use file order instead.
    if len(chain_msgs) < len(messages_in_file) // 2:
        print("warning: conversation chain incomplete; exporting in file order "
              "(may include edited-away branches)", file=sys.stderr)
        return messages_in_file
    return chain_msgs


def is_renderable(rec: dict):
    if not is_main_message(rec):
        return False
    if rec.get("isMeta"):
        return False
    if not isinstance(rec.get("message"), dict):
        return False
    return True


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

SYSTEM_TAG_RE = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
CAVEAT_RE = re.compile(r"<local-command-caveat>.*?</local-command-caveat>", re.S)
COMMAND_RE = re.compile(
    r"<command-name>(?P<name>.*?)</command-name>\s*"
    r"(?:<command-message>.*?</command-message>\s*)?"
    r"(?:<command-args>(?P<args>.*?)</command-args>)?",
    re.S,
)
STDOUT_RE = re.compile(r"<local-command-stdout>(.*?)</local-command-stdout>", re.S)


def strip_system_tags(text: str):
    return SYSTEM_TAG_RE.sub("", text).strip()


def parse_command(text: str):
    """Split a slash-command message into (command line or None, remainder).

    Only a message that OPENS with the command tags is a command message;
    prose that merely quotes the tags must render untouched as prose.
    """
    text = CAVEAT_RE.sub("", text)
    if not text.lstrip().startswith("<command-name>"):
        return None, text
    m = COMMAND_RE.search(text)
    cmd = m.group("name").strip()
    args = m.group("args")
    if args and args.strip():
        cmd += " " + args.strip()
    return cmd or None, text[:m.start()] + text[m.end():]


def prefixed(prefix: str, cont: str, text: str):
    lines = text.split("\n")
    out = [prefix + lines[0]]
    out.extend(cont + ln for ln in lines[1:])
    return "\n".join(out)


TOOL_SUMMARY_KEYS = (
    "command", "file_path", "path", "pattern", "query", "url",
    "description", "skill", "prompt", "notebook_path",
)


def tool_use_summary(name: str, tool_input: dict):
    display_name = name
    m = re.match(r"mcp__(.+?)__(.+)", name)
    if m:
        display_name = f"{m.group(1)} - {m.group(2)}"
    summary = ""
    if isinstance(tool_input, dict):
        for key in TOOL_SUMMARY_KEYS:
            val = tool_input.get(key)
            if isinstance(val, str) and val.strip():
                summary = val.strip().split("\n")[0]
                break
        else:
            if tool_input:
                summary = json.dumps(tool_input, ensure_ascii=False)
    if len(summary) > 200:
        summary = summary[:199] + "…"
    return f"{ASSISTANT_PREFIX}{display_name}({summary})"


def tool_result_text(block: dict):
    content = block.get("content")
    if isinstance(content, str):
        return content
    parts = []
    if isinstance(content, list):
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                parts.append(item.get("text", ""))
            elif isinstance(item, dict) and item.get("type") == "image":
                parts.append("[image]")
    return "\n".join(parts)


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?")
CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def scrub(text: str):
    """Strip ANSI escapes and non-printable control chars (keeps \\n, \\t).

    Tool output can contain raw binary bytes and terminal color codes; a
    text export must stay a text file (and not trip binary detection).
    """
    text = ANSI_RE.sub("", text)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return CONTROL_RE.sub("", text)


def render_result(text: str, max_lines: int):
    text = scrub(text).rstrip("\n")
    if not text.strip():
        text = "(no output)"
    lines = text.split("\n")
    if max_lines and len(lines) > max_lines:
        hidden = len(lines) - max_lines
        lines = lines[:max_lines] + [f"… +{hidden} lines"]
    out = [RESULT_PREFIX + lines[0]]
    out.extend(RESULT_CONT + ln for ln in lines[1:])
    return "\n".join(out)


def render(chain: list[dict], include_thinking: bool, max_result_lines: int):
    # Map tool_use_id -> result block so results print right under the call.
    results: dict[str, dict] = {}
    for rec in chain:
        if rec.get("type") != "user":
            continue
        content = rec.get("message", {}).get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    results[block.get("tool_use_id")] = block

    blocks: list[str] = []
    for rec in chain:
        if not is_renderable(rec):
            continue
        msg = rec.get("message", {})
        content = msg.get("content")

        if rec["type"] == "user":
            texts = []
            if isinstance(content, str):
                texts = [content]
            elif isinstance(content, list):
                texts = [b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text"]
            for text in texts:
                # a command turn can carry a command, its stdout, AND user
                # prose - render each part, losing none of them
                cmd, text = parse_command(text)
                if cmd:
                    blocks.append(prefixed(USER_PREFIX, "  ", cmd))
                stdout = STDOUT_RE.search(text)
                if stdout is not None and text.lstrip().startswith("<local-command-stdout>"):
                    out = stdout.group(1).strip()
                    if out:
                        blocks.append(render_result(out, max_result_lines))
                    text = text[:stdout.start()] + text[stdout.end():]
                text = strip_system_tags(text)
                if text:
                    blocks.append(prefixed(USER_PREFIX, "  ", text))

        else:  # assistant
            if not isinstance(content, list):
                if isinstance(content, str) and content.strip():
                    blocks.append(prefixed(ASSISTANT_PREFIX, "  ", content.strip()))
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                if btype == "text":
                    text = block.get("text", "").strip()
                    if text:
                        blocks.append(prefixed(ASSISTANT_PREFIX, "  ", text))
                elif btype == "thinking" and include_thinking:
                    text = block.get("thinking", "").strip()
                    if text:
                        blocks.append(THINKING_HEADER + "\n\n" + prefixed("  ", "  ", text))
                elif btype == "tool_use":
                    piece = tool_use_summary(block.get("name", "?"), block.get("input", {}))
                    result = results.get(block.get("id"))
                    if result is not None:
                        piece += "\n" + render_result(tool_result_text(result), max_result_lines)
                    blocks.append(piece)

    return scrub("\n\n".join(blocks)) + "\n"


# ---------------------------------------------------------------------------
# Filename (replicates the native /export implementation)
# ---------------------------------------------------------------------------

def native_timestamp(dt: datetime):
    return dt.strftime("%Y-%m-%d-%H%M%S")


def first_prompt(chain: list[dict]):
    for rec in chain:
        if rec.get("type") != "user" or rec.get("isMeta") or rec.get("isSidechain"):
            continue
        content = rec.get("message", {}).get("content")
        text = ""
        if isinstance(content, str):
            text = content.strip()
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    text = block.get("text", "").strip()
                    break
        cmd, remainder = parse_command(text)
        text = cmd if cmd else strip_system_tags(remainder)
        text = re.sub(r"\s+", " ", text)
        if not text:
            continue
        if len(text) > 50:
            text = text[:49] + "…"
        return text
    return ""


def sanitize_filename(text: str):
    text = text.lower()
    text = re.sub(r"[^a-z0-9\s-]", "", text)
    text = re.sub(r"\s+", "-", text)
    text = re.sub(r"-+", "-", text)
    return text.strip("-")


def default_filename(chain: list[dict]):
    slug = sanitize_filename(first_prompt(chain))
    ts = native_timestamp(datetime.now())
    return f"{ts}-{slug}.txt" if slug else f"{ts}.txt"


# ---------------------------------------------------------------------------
# Destination configuration
#
# Output destination resolution order (most specific wins):
#   1. --out argument
#   2. $CLAUDE_EXPORT_DIR environment variable
#   3. env.CLAUDE_EXPORT_DIR in <project>/.claude/settings.local.json or
#      settings.json (Claude Code's own settings; the env block is injected
#      as real environment at session start, so this fallback only matters
#      in the session that just wrote the setting)
#   4. current directory (native /export behavior)
#
# Relative paths resolve against the project root (nearest ancestor with a
# .claude or .git directory).
# ---------------------------------------------------------------------------

def find_project_root():
    d = os.getcwd()
    while True:
        if os.path.isdir(os.path.join(d, ".claude")) or os.path.isdir(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def settings_export_dir(root):
    """Read env.CLAUDE_EXPORT_DIR from the project's Claude Code settings."""
    if not root:
        return None
    for name in ("settings.local.json", "settings.json"):
        path = os.path.join(root, ".claude", name)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8") as f:
                settings = json.load(f)
            val = settings.get("env", {}).get("CLAUDE_EXPORT_DIR")
        except (OSError, json.JSONDecodeError, AttributeError):
            continue
        if isinstance(val, str) and val.strip():
            return val.strip()
    return None


def resolve_out(arg_out):
    """Apply the destination resolution order; returns a file or dir path."""
    if arg_out is not None:
        return arg_out
    root = find_project_root()
    out_dir = os.environ.get("CLAUDE_EXPORT_DIR") or settings_export_dir(root)
    if not out_dir:
        return "."
    out_dir = os.path.expanduser(out_dir)
    if not os.path.isabs(out_dir):
        out_dir = os.path.join(root or os.getcwd(), out_dir)
    # always a directory; the trailing separator keeps a not-yet-existing
    # directory from being mistaken for a file path
    return os.path.join(out_dir, "")


def unique_path(path):
    """Append -2, -3, ... so auto-named exports never overwrite each other."""
    if not os.path.exists(path):
        return path
    base, ext = os.path.splitext(path)
    n = 2
    while os.path.exists(f"{base}-{n}{ext}"):
        n += 1
    return f"{base}-{n}{ext}"


def is_dir_target(out):
    return os.path.isdir(out) or out.endswith("/") or out.endswith(os.sep)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--session", help="session uuid or path to a .jsonl transcript "
                                      "(default: $CLAUDE_CODE_SESSION_ID)")
    ap.add_argument("--out", default=None,
                    help="output file or directory (default: $CLAUDE_EXPORT_DIR / "
                         "env.CLAUDE_EXPORT_DIR in .claude/settings.json, then cwd)")
    ap.add_argument("--stdout", action="store_true", help="print transcript to stdout")
    ap.add_argument("--no-thinking", action="store_true", help="omit thinking blocks")
    ap.add_argument("--max-result-lines", type=int, default=0,
                    help="truncate tool results to N lines (default: 0 = keep all)")
    ap.add_argument("--force", action="store_true",
                    help="overwrite an existing --out file")
    args = ap.parse_args()
    if args.max_result_lines < 0:
        ap.error("--max-result-lines must be >= 0")
    if args.out is not None and not args.out.strip():
        ap.error("--out must not be empty")

    transcript = find_transcript(args.session)
    records = load_records(transcript)
    chain = conversation_chain(records)
    if not chain:
        sys.exit(f"error: no messages found in {transcript}")

    text = render(chain, include_thinking=not args.no_thinking,
                  max_result_lines=args.max_result_lines)

    if args.stdout:
        sys.stdout.write(text)
        return

    out = resolve_out(args.out)
    if is_dir_target(out):
        os.makedirs(out, exist_ok=True)
        out = unique_path(os.path.join(out, default_filename(chain)))
    else:
        if os.path.exists(out) and not args.force:
            sys.exit(f"error: {out} exists; pass --force to overwrite")
        parent = os.path.dirname(os.path.abspath(out))
        os.makedirs(parent, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)
    print(os.path.abspath(out))


if __name__ == "__main__":
    main()

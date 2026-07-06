#!/usr/bin/env ruby
# frozen_string_literal: true

# Export a Claude Code session transcript to a readable file.
#
# Requires Ruby 3.4+ (uses the `it` block parameter; everything else is
# Ruby 3.0+). Stdlib only.
#
# Two output modes:
#   (default)  clean Markdown (.md) for reading/notes (e.g. an Obsidian
#              vault): prose kept as real Markdown, tool calls collapsed to
#              a one-line summary, tool OUTPUT and thinking dropped, YAML
#              frontmatter. Contains no command lines or command output, so
#              - like the native /export - it does not surface credentials.
#   --full     complete transcript (.txt): every message, every tool call
#              with its arguments, and full tool output. This CAN contain
#              secrets (env dumps, tokens in commands, .env contents); it is
#              an explicit opt-in for archival/analysis, not casual sharing.
#
# Usage:
#   export_session.rb                       # clean Markdown -> configured default
#   export_session.rb --full                # complete .txt transcript
#   export_session.rb --out exports/        # into a directory (auto-named)
#   export_session.rb --out notes/foo.md    # exact file
#   export_session.rb --session <uuid|path> # a specific session
#   export_session.rb --stdout              # print instead of writing
#
# Prints the absolute path of the written file on success.

require "json"
require "optparse"
require "fileutils"
require "set"

CLAUDE_PROJECTS_DIR = File.expand_path("~/.claude/projects")

USER_PREFIX = "> "
ASSISTANT_PREFIX = "⏺ "
RESULT_PREFIX = "  ⎿  "
RESULT_CONT = "     "
THINKING_HEADER = "✻ Thinking…"

SESSION_ID_RE = /\A[0-9a-fA-F-]{8,}\z/
SYSTEM_TAG_RE = /<system-reminder>.*?<\/system-reminder>/m
CAVEAT_RE = /<local-command-caveat>.*?<\/local-command-caveat>/m
COMMAND_RE = /<command-name>(?<name>.*?)<\/command-name>\s*
              (?:<command-message>.*?<\/command-message>\s*)?
              (?:<command-args>(?<args>.*?)<\/command-args>)?/xm
STDOUT_RE = /<local-command-stdout>(.*?)<\/local-command-stdout>/m
ANSI_RE = /\e\[[0-9;?]*[A-Za-z]|\e\][^\a\e]*(?:\a|\e\\)?/
CONTROL_RE = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/

TOOL_SUMMARY_KEYS = %i[
  command file_path path pattern query url description skill prompt notebook_path
].freeze

# For the clean Markdown view: collapse each tool call to a verb + noun,
# never its arguments. [verb, singular, plural]. Unknown/MCP tools fall
# back to a generic "used <name>".
TOOL_VERBS = {
  "Bash" => ["ran", "shell command", "shell commands"],
  "Read" => ["read", "file", "files"],
  "Edit" => ["edited", "file", "files"],
  "MultiEdit" => ["edited", "file", "files"],
  "Write" => ["wrote", "file", "files"],
  "NotebookEdit" => ["edited", "notebook", "notebooks"],
  "LS" => ["listed", "directory", "directories"],
  "Glob" => ["searched", "pattern", "patterns"],
  "Grep" => ["searched", "pattern", "patterns"],
  "Task" => ["ran", "agent", "agents"],
  "WebFetch" => ["fetched", "URL", "URLs"],
  "WebSearch" => ["ran", "web search", "web searches"],
  "TodoWrite" => ["updated", "todo list", "todo lists"],
}.freeze

# One rendered element of the conversation. `text` carries the payload for
# prose/command/output kinds; `sig` and `result` carry the tool call's
# signature and raw output. Renderers turn a stream of these into txt or md.
Event = Data.define(:kind, :text, :sig, :result)

# --------------------------------------------------------------------------
# Transcript location
# --------------------------------------------------------------------------

def find_transcript(session)
  return session if session && File.file?(session)

  session_id = session || ENV["CLAUDE_CODE_SESSION_ID"]
  abort "error: no session given and $CLAUDE_CODE_SESSION_ID is not set. " \
        "Pass --session <uuid|path>." if session_id.nil? || session_id.empty?
  abort "error: #{session_id.inspect} is not a session id or an existing transcript path" \
    unless session_id.match?(SESSION_ID_RE)
  matches = Dir.glob(File.join(CLAUDE_PROJECTS_DIR, "*", "#{session_id}.jsonl"))
  abort "error: no transcript found for session #{session_id} under #{CLAUDE_PROJECTS_DIR}" \
    if matches.empty?
  # If the same session id somehow exists in several project dirs, take newest.
  matches.max_by { File.mtime(it) }
end

# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------

def load_records(path)
  File.foreach(path, encoding: "utf-8").filter_map do |line|
    JSON.parse(line, symbolize_names: true) unless line.strip.empty?
  rescue JSON::ParserError
    nil # skip partial/corrupt lines
  end
end

def main_message?(rec) = (rec in { type: "user" | "assistant" }) && !rec[:isSidechain]

def renderable?(rec) = main_message?(rec) && !rec[:isMeta] && rec[:message].is_a?(Hash)

# Reconstruct the active conversation branch. Records form a tree via
# parentUuid (message edits create dead branches). Walk back from the last
# main-conversation message to the root, then reverse. Falls back to file
# order if the chain looks broken.
def conversation_chain(records)
  by_uuid = records.filter_map { [it[:uuid], it] if it[:uuid] }.to_h
  # ^ Hash keeps first-insert order; a re-written uuid keeps newest content

  messages_in_file = by_uuid.values.select { main_message?(it) }
  return [] if messages_in_file.empty?

  # Walk from the last MAIN message: the file's literal last record can be
  # a subagent sidechain, which belongs to a different branch of the tree.
  chain = []
  seen = Set.new
  node = messages_in_file.last
  while node && seen.add?(node[:uuid])
    chain << node
    node = node[:parentUuid]&.then { by_uuid[it] }
  end
  chain.reverse!

  chain_msgs = chain.select { main_message?(it) }
  # If the walk lost more than half the messages, the chain metadata is
  # unreliable (e.g. resumed/compacted sessions) - use file order instead.
  if chain_msgs.length < messages_in_file.length / 2
    warn "warning: conversation chain incomplete; exporting in file order " \
         "(may include edited-away branches)"
    return messages_in_file
  end
  chain_msgs
end

# --------------------------------------------------------------------------
# Shared text helpers
# --------------------------------------------------------------------------

def strip_system_tags(text) = text.gsub(SYSTEM_TAG_RE, "").strip

# Split a slash-command message into [command line or nil, remainder].
# Only a message that OPENS with the command tags is a command message;
# prose that merely quotes the tags must render untouched as prose.
def parse_command(text)
  text = text.gsub(CAVEAT_RE, "")
  return [nil, text] unless text.lstrip.start_with?("<command-name>")

  m = COMMAND_RE.match(text)
  cmd = [m[:name].strip, m[:args]&.strip].compact.reject(&:empty?).join(" ")
  [cmd.empty? ? nil : cmd, m.pre_match + m.post_match]
end

# "name(one-line summary)" for a tool call, without any leading marker.
def tool_signature(name, tool_input)
  display_name = case name
                 in /\Amcp__(?<server>.+?)__(?<tool>.+)\z/m then "#{$~[:server]} - #{$~[:tool]}"
                 else name
                 end
  summary = case tool_input
            in Hash if (key = TOOL_SUMMARY_KEYS.find { tool_input[it].is_a?(String) && !tool_input[it].strip.empty? })
              tool_input[key].strip.split("\n").first
            in Hash => h unless h.empty?
              JSON.generate(h)
            else ""
            end
  summary = summary[0, 199] + "…" if summary.length > 200
  "#{display_name}(#{summary})"
end

def tool_result_text(block)
  case block[:content]
  in String => s then s
  in Array => items
    items.filter_map do |item|
      case item
      in { type: "text" }  then item[:text] || ""
      in { type: "image" } then "[image]"
      else nil
      end
    end.join("\n")
  else ""
  end
end

# Strip ANSI escapes and non-printable control chars (keeps \n, \t).
# Tool output can contain raw binary bytes and terminal color codes; a
# text export must stay a text file (and not trip binary detection).
def scrub(text)
  text.gsub(ANSI_RE, "")
      .gsub("\r\n", "\n").tr("\r", "\n")
      .gsub(CONTROL_RE, "")
end

# --------------------------------------------------------------------------
# Chain -> Event stream (format-independent)
# --------------------------------------------------------------------------

def collect_user_events(text, into)
  # a command turn can carry a command, its stdout, AND user prose -
  # emit each part, losing none of them
  cmd, text = parse_command(text)
  into << Event.new(:command, cmd, nil, nil) if cmd
  if (stdout = STDOUT_RE.match(text)) && text.lstrip.start_with?("<local-command-stdout>")
    out = stdout[1].strip
    into << Event.new(:stdout, out, nil, nil) unless out.empty?
    text = stdout.pre_match + stdout.post_match
  end
  text = strip_system_tags(text)
  into << Event.new(:user, text, nil, nil) unless text.empty?
end

def walk(chain, include_thinking:)
  # Map tool_use_id -> result block so results attach to their call.
  results = chain.each_with_object({}) do |rec, acc|
    next unless rec in { type: "user", message: { content: Array => content } }
    content.each { acc[it[:tool_use_id]] = it if it in { type: "tool_result" } }
  end

  events = []
  chain.select { renderable?(it) }.each do |rec|
    case rec
    in { type: "user", message: { content: String => text } }
      collect_user_events(text, events)
    in { type: "user", message: { content: Array => content } }
      content.each { collect_user_events(it[:text] || "", events) if it in { type: "text" } }
    in { type: "assistant", message: { content: String => text } }
      events << Event.new(:assistant, text.strip, nil, nil) unless text.strip.empty?
    in { type: "assistant", message: { content: Array => content } }
      content.each do |block|
        case block
        in { type: "text", text: String => t } unless t.strip.empty?
          events << Event.new(:assistant, t.strip, nil, nil)
        in { type: "thinking", thinking: String => t } if include_thinking && !t.strip.empty?
          events << Event.new(:thinking, t.strip, nil, nil)
        in { type: "tool_use", id: }
          name = block[:name] || "?"
          sig = tool_signature(name, block[:input] || {})
          res = results[id] ? tool_result_text(results[id]) : nil
          # text: raw name (for the collapsed md summary, no args)
          # sig:  name(args) for the full txt view
          events << Event.new(:tool, name, sig, res)
        else nil
        end
      end
    else nil
    end
  end
  events
end

# --------------------------------------------------------------------------
# Renderer: txt (complete, native /export style)
# --------------------------------------------------------------------------

def prefixed(prefix, cont, text)
  first, *rest = text.split("\n", -1)
  [prefix + first, *rest.map { cont + it }].join("\n")
end

def render_result_block(text, max_lines)
  text = scrub(text).sub(/\n+\z/, "")
  text = "(no output)" if text.strip.empty?
  lines = text.split("\n", -1)
  if max_lines.positive? && lines.length > max_lines
    lines = lines.take(max_lines) << "… +#{lines.length - max_lines} lines"
  end
  first, *rest = lines
  [RESULT_PREFIX + first, *rest.map { RESULT_CONT + it }].join("\n")
end

def render_txt(events, max_result_lines:)
  blocks = events.map do |e|
    case e.kind
    in :user | :command then prefixed(USER_PREFIX, "  ", e.text)
    in :stdout          then render_result_block(e.text, max_result_lines)
    in :assistant       then prefixed(ASSISTANT_PREFIX, "  ", e.text)
    in :thinking        then "#{THINKING_HEADER}\n\n#{prefixed('  ', '  ', e.text)}"
    in :tool
      piece = ASSISTANT_PREFIX + e.sig
      piece += "\n" + render_result_block(e.result, max_result_lines) unless e.result.nil?
      piece
    end
  end
  scrub(blocks.join("\n\n")) + "\n"
end

# --------------------------------------------------------------------------
# Renderer: md (cleaned up, Obsidian-friendly)
# --------------------------------------------------------------------------

USER_HEADING = "## 💬 User"
CLAUDE_HEADING = "## 🤖 Claude"

def tool_display(name) = name.sub(/\Amcp__(.+?)__(.+)\z/m) { "#{$1} #{$2}" }

# One-line summary of a run of consecutive tool calls - verbs and counts
# only, never arguments or output. "Ran 2 shell commands, read 1 file."
def collapse_tools(names)
  tally = names.each_with_object(Hash.new(0)) { |n, h| h[n] += 1 }
  phrases = tally.map do |name, count|
    if (verb, singular, plural = TOOL_VERBS[name])
      "#{verb} #{count} #{count == 1 ? singular : plural}"
    else
      suffix = count > 1 ? " (#{count}×)" : ""
      "used #{tool_display(name)}#{suffix}"
    end
  end
  sentence = phrases.join(", ").sub(/\A(\w)/) { $1.upcase }
  "*#{sentence}.*"
end

def render_md(events, title:, session_id:, date:)
  front = ["---", "title: #{title.inspect}", "date: #{date}"]
  front << "session: #{session_id}" if session_id && !session_id.empty?
  front << "source: claude-code" << "---"
  chunks = [front.join("\n")]

  speaker = nil
  emit = lambda do |side, chunk|
    chunks << (side == :user ? USER_HEADING : CLAUDE_HEADING) if side != speaker
    speaker = side
    chunks << chunk unless chunk.nil?
  end

  i = 0
  while i < events.length
    e = events[i]
    if e.kind == :tool # collapse the whole consecutive run into one summary
      j = i
      j += 1 while j < events.length && events[j].kind == :tool
      emit.call(:claude, collapse_tools(events[i...j].map(&:text)))
      i = j
      next
    end
    case e.kind
    in :user      then emit.call(:user, e.text)      # raw: renders as Markdown
    in :command   then emit.call(:user, "`#{e.text}`") # the slash command typed
    in :stdout    then nil                            # command output: dropped
    in :assistant then emit.call(:claude, e.text)    # raw: renders as Markdown
    in :thinking  then nil                            # dropped in the clean view
    end
    i += 1
  end

  scrub(chunks.join("\n\n")).gsub(/\n{3,}/, "\n\n").strip + "\n"
end

# --------------------------------------------------------------------------
# Filename (replicates the native /export implementation)
# --------------------------------------------------------------------------

def first_prompt(chain)
  chain.each do |rec|
    next unless rec in { type: "user" }
    next if rec[:isMeta] || rec[:isSidechain]

    text = case rec.dig(:message, :content)
           in String => s then s.strip
           in Array => content
             content.find { it in { type: "text" } }&.dig(:text)&.strip || ""
           else ""
           end
    cmd, remainder = parse_command(text)
    text = (cmd || strip_system_tags(remainder)).gsub(/\s+/, " ").strip
    next if text.empty?

    return text.length > 50 ? text[0, 49] + "…" : text
  end
  ""
end

def sanitize_filename(text)
  text.downcase
      .gsub(/[^a-z0-9\s-]/, "")
      .gsub(/\s+/, "-")
      .squeeze("-")
      .delete_prefix("-").delete_suffix("-")
end

def default_filename(chain, ext)
  slug = sanitize_filename(first_prompt(chain))
  ts = Time.now.strftime("%Y-%m-%d-%H%M%S")
  slug.empty? ? "#{ts}#{ext}" : "#{ts}-#{slug}#{ext}"
end

# --------------------------------------------------------------------------
# Destination configuration - resolution order (most specific wins):
#   --out argument > $CLAUDE_EXPORT_DIR > env.CLAUDE_EXPORT_DIR in
#   .claude/settings(.local).json > current directory.
# Relative paths resolve against the project root (nearest ancestor with a
# .claude or .git directory).
# --------------------------------------------------------------------------

def find_project_root
  d = Dir.pwd
  until [File.join(d, ".claude"), File.join(d, ".git")].any? { File.directory?(it) }
    parent = File.dirname(d)
    return nil if parent == d
    d = parent
  end
  d
end

def settings_export_dir(root)
  return nil unless root

  %w[settings.local.json settings.json].each do |name|
    path = File.join(root, ".claude", name)
    next unless File.file?(path)
    case JSON.parse(File.read(path, encoding: "utf-8"), symbolize_names: true)
    in { env: { CLAUDE_EXPORT_DIR: String => dir } } if !dir.strip.empty?
      return dir.strip
    else next
    end
  rescue SystemCallError, JSON::ParserError
    next
  end
  nil
end

def resolve_out(arg_out)
  return arg_out if arg_out

  root = find_project_root
  out_dir = ENV.fetch("CLAUDE_EXPORT_DIR", nil) || settings_export_dir(root)
  return "." if out_dir.nil? || out_dir.empty?

  out_dir = File.expand_path(out_dir, out_dir.start_with?("~") ? nil : (root || Dir.pwd))
  # always a directory; the trailing separator keeps a not-yet-existing
  # directory from being mistaken for a file path
  File.join(out_dir, "")
end

# Append -2, -3, ... so auto-named exports never overwrite each other.
def unique_path(path)
  return path unless File.exist?(path)

  ext = File.extname(path)
  base = path.delete_suffix(ext)
  n = (2..).find { !File.exist?("#{base}-#{it}#{ext}") }
  "#{base}-#{n}#{ext}"
end

def dir_target?(out) = File.directory?(out) || out.end_with?("/", File::SEPARATOR)

# --------------------------------------------------------------------------

def main
  options = { max_result_lines: 0 }
  OptionParser.new do |op|
    op.banner = "Usage: export_session.rb [options]"
    op.on("--session ID", "session uuid or path to a .jsonl transcript") { options[:session] = it }
    op.on("--out PATH", "output file or directory") { options[:out] = it }
    op.on("--full", "complete .txt transcript (all commands + output); " \
                    "default is clean Markdown") { options[:full] = true }
    op.on("--stdout", "print to stdout instead of writing a file") { options[:stdout] = true }
    op.on("--no-thinking", "omit thinking blocks (--full only)") { options[:no_thinking] = true }
    op.on("--max-result-lines N", Integer, "truncate tool results to N lines (--full only)") { options[:max_result_lines] = it }
    op.on("--force", "overwrite an existing --out file") { options[:force] = true }
  end.parse!
  abort "error: --max-result-lines must be >= 0" if options[:max_result_lines].negative?
  abort "error: --out must not be empty" if options[:out]&.strip&.empty?

  transcript = find_transcript(options[:session])
  chain = conversation_chain(load_records(transcript))
  abort "error: no messages found in #{transcript}" if chain.empty?

  full = options[:full]
  if full
    warn "warning: --full includes complete tool commands and their output, " \
         "which may contain credentials (env vars, tokens, .env contents). " \
         "Review before sharing or syncing. The default (no --full) omits these."
  end
  events = walk(chain, include_thinking: full && !options[:no_thinking])
  text =
    if full
      render_txt(events, max_result_lines: options[:max_result_lines])
    else
      render_md(events, title: first_prompt(chain),
                        session_id: File.basename(transcript, ".jsonl"),
                        date: Time.now.strftime("%Y-%m-%d"))
    end

  return $stdout.write(text) if options[:stdout]

  ext = full ? ".txt" : ".md"
  out = resolve_out(options[:out])
  if dir_target?(out)
    FileUtils.mkdir_p(out)
    out = unique_path(File.join(out, default_filename(chain, ext)))
  else
    abort "error: #{out} exists; pass --force to overwrite" if File.exist?(out) && !options[:force]
    FileUtils.mkdir_p(File.dirname(File.expand_path(out)))
  end
  File.write(out, text, encoding: "utf-8")
  puts File.expand_path(out)
end

main if __FILE__ == $PROGRAM_NAME

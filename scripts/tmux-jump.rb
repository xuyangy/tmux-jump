#!/usr/bin/env ruby
# frozen_string_literal: true
#
# PERFORMANCE CONTRACT -- read before editing.
#
# This script runs on every jump keystroke and its budget is a few tens of
# milliseconds, most of which is interpreter startup. The rules below are load
# bearing; breaking any one of them costs more than everything else here saves.
#
#   * No `require`, ever, and no gems. scripts/tmux-jump.sh launches ruby with
#     --disable-gems, which removes ~70% of interpreter startup (98ms -> 29ms
#     measured). A single `require` of a stdlib that pulls in RubyGems, or any
#     gem dependency at all, silently undoes that. `require "tempfile"` alone
#     cost 17ms -- as much as the whole interpreter boot -- via delegate/tmpdir.
#   * tmux round-trips cost ~10ms each, so they are enumerated here rather than
#     estimated. This list is the complete ledger for one jump:
#
#       worker, always     1  startup chain -- geometry + @jump-* options +
#                             screen, in a single display-message chain
#       worker, always     1  jump chain -- copy-mode + cursor moves (on success)
#       worker, double     1  command-prompt for the second search char
#       worker, per marker 1  command-prompt per marker level -- none when the
#                             search char matches exactly once
#       worker, alt screen 1  capture-pane -ep, only when the pane runs a
#                             full-screen program (recover_alternate_screen_after)
#       launcher, always   1  command-prompt for the first search char
#
#     So the floor is two worker round-trips (single mode, unique match, normal
#     screen) and three in double mode. Any invocation not on this list is a
#     regression: measure it, add it here, or do not add it.
#   * Never shell out. Ruby backticks fork /bin/sh -c first: 14.4ms per call
#     versus 9.6ms for IO.popen with an argv array.
#   * No per-character Ruby iteration over the screen. each_char allocates a
#     String and dispatches a block per character; screen-wide work must use
#     C-implemented primitives (index, count, rindex, ascii_only?) over the
#     precomputed line table.
#   * No polling on the keypress path. The prompt handoff is a FIFO plus
#     IO.select, so the wake is immediate.

# SPECIAL STRINGS
HOME_SEQ = "\e[H"
RESET_COLORS = "\e[0m"
ENTER_ALTERNATE_SCREEN = "\e[?1049h"
RESTORE_NORMAL_SCREEN = "\e[?1049l"

# CONFIG
KEYS = (ENV['JUMP_KEYS'] || 'jfhgkdlsa').each_char.to_a
# If the user pauses longer than this after the first char, we treat it as a single-char jump.

Config = Struct.new(
  :pane_nr,
  :pane_tty_file,
  :cursor_y,
  :cursor_x,
  :alternate_on,
  :scroll_position,
  :pane_height,
  :history_size,
  :line_numbers,
  # Added for performance
  :gray,
  :red,
  :keys_position,
  :mode_single,
  :mode_double,
  # Invocation arguments. Held here rather than in load-time constants read from
  # ARGV so that this file can be required (by the specs) without picking up the
  # requiring process's own argv.
  :mode,
  :prompt_file,
  :cancel_file,
  :arg_first,
  :arg_second
).new

# Args: mode then optional pre-read chars (from tmux command-prompt).
# Supports either a single combined string (e.g. "%1%2") or two separate args.
def parse_argv!(argv)
  args = argv.dup
  Config.mode = (args.shift || 'single')
  loop do
    case args[0]
    when '--prompt-file'
      args.shift
      Config.prompt_file = args.shift
    when '--cancel-file'
      args.shift
      Config.cancel_file = args.shift
    else
      break
    end
  end
  Config.arg_first = args[0]
  Config.arg_second = args[1]
end

# METHODS

# Set JUMP_DEBUG=1 to let tmux's stderr through. It is discarded by default so a
# failing command cannot scribble on the pane, but tmux reports a malformed -S/-E
# by silently falling back to 0, so this is often the only diagnostic available.
DEBUG = !(ENV['JUMP_DEBUG'] || '').empty?

# Run tmux with an argv array so no /bin/sh is forked. Returns stdout.
def tmux(*args)
  opts = DEBUG ? {} : { err: File::NULL }
  IO.popen(['tmux', *args], **opts, &:read)
end

# Fire-and-forget: we never read the output of the jump chain.
def tmux!(*args)
  err = DEBUG ? 2 : File::NULL
  Process.wait Kernel.spawn('tmux', *args, out: File::NULL, err: err)
end

# Fields for the startup chain, in order. Tab-separated on ONE line: colour
# values legitimately contain ';' and could contain '\n', but never a tab, and
# a single field line means we never depend on capture-pane emitting exactly
# pane_height lines (blank bottom rows and clipped ranges both break that).
# pane_in_mode is deliberately absent: the copy-mode cancel is done by the
# if-shell in the same chain, so nothing in Ruby needs to know.
STARTUP_FIELDS = %w[
  pane_id pane_tty cursor_y cursor_x alternate_on
  scroll_position pane_height
  @jump-bg-color @jump-fg-color @jump-keys-position
  @jump-mode-single @jump-mode-double
  history_size copy-mode-line-numbers
].freeze

# tmux format-expands capture-pane's -S/-E, which is what lets the geometry, the
# options and the correctly-scrolled screen arrive in a single round-trip.
#
# -E is pane_height - (scroll_position + 1), i.e. -scroll_position +
# pane_height - 1 rearranged so the nested #{e|...} forms stay non-negative.
# An empty scroll_position (the pane is not in copy mode) evaluates to 0 in this
# arithmetic, which is what we want; a bare "-#{scroll_position}" would degrade
# to "-S -" and capture the ENTIRE history, so the multiply form is deliberate.
CAPTURE_START = '#{e|*:-1,#{scroll_position}}'
CAPTURE_END = '#{e|-:#{pane_height},#{e|+:#{scroll_position},1}}'

# WARNING: a malformed CAPTURE_START/CAPTURE_END does NOT fail. tmux treats an
# unparseable -S/-E as 0, so a typo here silently captures the live bottom of
# the pane instead of the scrolled view and every jump lands on the wrong
# screen. spec/ asserts this range against a known-good literal -S/-E pair.
#
# No -t on either command, so both resolve the same default target. Adding -t to
# one without the other would let them disagree about which pane they describe.
#
# On TMUX_PANE: it is exported to run-shell children. Whether it tracks the pane
# the key was pressed in is unconfirmed, so targeting deliberately does not use
# it -- the default target is what the rest of this file already relies on.
def read_startup_state!
  out = tmux(
    'display-message', '-p', '-F', STARTUP_FIELDS.map { |f| "\#{#{f}}" }.join("\t"),
    ';', 'capture-pane', '-p', '-S', CAPTURE_START, '-E', CAPTURE_END,
    ';', 'if-shell', '-F', '#{pane_in_mode}', 'send-keys -X cancel'
  )
  field_line, screen = out.split("\n", 2)
  fields = field_line.to_s.split("\t", -1)

  Config.pane_nr = fields[0]
  Config.pane_tty_file = fields[1]
  Config.cursor_y = fields[2]
  Config.cursor_x = fields[3]
  Config.alternate_on = fields[4]
  Config.scroll_position = fields[5].to_i
  Config.pane_height = fields[6].to_i

  apply_option_defaults!(fields[7], fields[8], fields[9], fields[10], fields[11])
  Config.history_size = fields[12].to_i
  Config.line_numbers = fields[13]

  # capture-pane ends with a newline; drop it, not a trailing blank screen row.
  screen = screen.to_s
  screen = screen[0..-2] if screen.end_with?("\n")
  screen.gsub("\u{FE0E}", '')
end

# Resolve the @jump-* options against env fallbacks and built-in defaults. Kept
# out of read_startup_state! so it is reachable without a live tmux -- otherwise
# Config.red is nil and the draw path raises TypeError under test.
def apply_option_defaults!(bg = nil, fg = nil, pos = nil, mode_single = nil, mode_double = nil)
  bg = bg.to_s.strip
  fg = fg.to_s.strip
  pos = pos.to_s.strip
  Config.gray = (bg.empty? ? (ENV['JUMP_BACKGROUND_COLOR'] || "\e[48;5;240m") : bg).gsub('\\e', "\e")
  Config.red = (fg.empty? ? (ENV['JUMP_FOREGROUND_COLOR'] || "\e[1m\e[31m") : fg).gsub('\\e', "\e")
  Config.keys_position = pos.empty? ? (ENV['JUMP_KEYS_POSITION'] || 'left') : pos
  Config.mode_single = mode_single.to_s.strip
  Config.mode_double = mode_double.to_s.strip
end

def recover_screen_after
  if Config.alternate_on == '1'
    recover_alternate_screen_after { yield }
  else
    recover_normal_screen_after { yield }
  end
end

def recover_normal_screen_after
  File.open(Config.pane_tty_file, 'a') do |tty|
    tty << ENTER_ALTERNATE_SCREEN + HOME_SEQ
  end
  returns = nil
  begin
    returns = yield
  rescue Interrupt
    # user took too long, or pressed Ctrl-C, but we recover anyways
  ensure
    File.open(Config.pane_tty_file, 'a') do |tty|
      tty << RESTORE_NORMAL_SCREEN
    end
  end
  returns
end

def recover_alternate_screen_after
  saved_screen =
    tmux('capture-pane', '-ep', '-t', Config.pane_nr)[0..-2] # with colors...
      .gsub("\n", "\n\r")
  File.open(Config.pane_tty_file, 'a') do |tty|
    tty << HOME_SEQ
  end
  returns = nil
  begin
    returns = yield
  rescue Interrupt
    # user took too long, or pressed Ctrl-C, but we recover anyways
  ensure
    File.open(Config.pane_tty_file, 'a') do |tty|
      tty << HOME_SEQ
      tty << saved_screen
      tty << "\e[#{Config.cursor_y.to_i + 1};#{Config.cursor_x.to_i + 1}H"
      tty << RESET_COLORS
    end
  end
  returns
end

PROMPT_TIMEOUT = 10
# How long to keep waiting for a character after the prompt process has already
# exited. Submitting the prompt makes `tmux command-prompt` return and fires the
# run-shell write, so the two race; only the cancel path ever waits this out.
PROMPT_EXIT_GRACE = 0.05

# Open a FIFO for reading without blocking on a writer, and keep a write end
# open in this process. Holding the write end means a writer closing -- each
# `printf > fifo` from tmux is a separate open/close -- never surfaces as EOF,
# which would otherwise make IO.select return readable forever and turn this
# back into a busy loop.
def open_prompt_fifo(path)
  File.open(path, File::RDWR | File::NONBLOCK)
end

# Block until `char_count` complete characters are available. No polling: the
# only wait is IO.select, which wakes the moment tmux writes.
def read_chars_from_fifo(io, char_count, timeout_seconds = PROMPT_TIMEOUT, cancel_io = nil)
  buf = String.new(encoding: Encoding::BINARY)
  watched = cancel_io ? [io, cancel_io] : [io]
  deadline_grace = nil

  loop do
    timeout = deadline_grace || timeout_seconds
    ready, = IO.select(watched, nil, nil, timeout)
    return nil if ready.nil? # timed out, or grace elapsed after prompt exit

    if cancel_io && ready.include?(cancel_io)
      # The prompt that fed this FIFO has resolved. Each prompt is read by
      # exactly one call, so an empty buffer here means it was cancelled. A
      # character can still be in flight -- the callback write and the prompt
      # returning race -- so allow a short grace before giving up.
      watched = [io]
      deadline_grace = PROMPT_EXIT_GRACE
      next unless ready.include?(io)
    end

    begin
      buf << io.read_nonblock(64)
    rescue IO::WaitReadable
      next
    end

    # Any control byte cancels, not just <Esc>. `command-prompt -1` appends the
    # key verbatim (status.c handles PROMPT_SINGLE before the status-keys
    # translation), so <Esc> arrives as 0x1b, C-c as 0x03, Enter as 0x0d and
    # Backspace as 0x7f. None of them can be a jump target -- the captured screen
    # holds no control characters -- and letting one through leaves an orphan
    # char2: prompt on an aborted double jump.
    #
    # This line IS the cancel rule documented under "Cancelling a jump" in
    # README.md. Keep the two in step: 0x01-0x1f and 0x7f abort, 0x20-0x7e and
    # UTF-8 are jump targets.
    first = buf.getbyte(0)
    return nil if first && (first < 0x20 || first == 0x7f)

    text = buf.dup.force_encoding(Encoding::UTF_8)
    next unless text.valid_encoding? # partial multi-byte character
    return text[0, char_count] if text.length >= char_count
  end
rescue Interrupt
  nil
end

# A FIFO at a plain $TMPDIR path. Tempfile would do this too, but requiring it
# costs 17ms of interpreter startup -- see the performance contract at the top.
def prompt_fifo_path!
  path = Config.prompt_file
  return path if path && !path.empty?

  dir = ENV['TMPDIR'] || '/tmp'
  path = File.join(dir, "tmux-jump-#{Process.pid}.fifo")
  File.delete(path) if File.exist?(path)
  File.mkfifo path
  Config.prompt_file = path
  path
end

def prompt_char!(label = 'char:')
  path = prompt_fifo_path!
  io = open_prompt_fifo path
  cancel_r, cancel_w = IO.pipe
  pid = Kernel.spawn(
    'tmux', 'command-prompt', '-1', '-p', label,
    "run-shell \"printf '%1' > #{path}\""
  )
  watcher = Thread.new do
    Process.wait pid
    cancel_w.write 'x'
  rescue StandardError
    nil
  end

  read_chars_from_fifo(io, 1, PROMPT_TIMEOUT, cancel_r)
ensure
  watcher.kill if watcher
  io.close if io
  cancel_r.close if cancel_r
  cancel_w.close if cancel_w
end

def cleanup_prompt_file
  [Config.prompt_file, Config.cancel_file].each do |path|
    next if path.nil? || path.empty?

    File.delete(path) if File.exist?(path)
  rescue StandardError
    nil
  end
end

def positions_of(jump_to_chars, screen_chars, jump_mode)
  if jump_mode == 'char'
    positions_of_char(jump_to_chars, screen_chars)
  else
    positions_of_word(jump_to_chars, screen_chars)
  end
end

private

def positions_of_char(jump_to_chars, screen_chars)
  positions = []
  case jump_to_chars.length
  when 1
    target = jump_to_chars[0]
    if target == target.upcase
      idx = -1
      while idx = screen_chars.index(target, idx + 1)
        positions << idx
      end
    else
      hay = screen_chars.downcase
      tci = target.downcase
      idx = -1
      while idx = hay.index(tci, idx + 1)
        positions << idx
      end
    end
  when 2
    a = jump_to_chars[0]
    b = jump_to_chars[1]
    if a == a.upcase
      needle = a + b
      idx = -1
      while idx = screen_chars.index(needle, idx + 1)
        positions << idx
        idx += 1
        idx += 1 while needle[0] == needle[1] && screen_chars[idx + 1] == needle[0]
      end
    else
      hay = screen_chars.downcase
      needle = (a + b).downcase
      idx = -1
      while idx = hay.index(needle, idx + 1)
        positions << idx
        idx += 1
        idx += 1 while needle[0] == needle[1] && hay[idx + 1] == needle[0]
      end
    end
  end
  positions
end

def positions_of_word(jump_to_chars, screen_chars)
  positions = []
  case jump_to_chars.length
  when 1
    target = jump_to_chars[0]
    return positions unless target =~ /\w/
    regex = if target == target.upcase
      /\b#{Regexp.escape(target)}/
    else
      /\b#{Regexp.escape(target)}/i
    end
    start_at = 0
    while (m = regex.match(screen_chars, start_at))
      positions << m.begin(0)
      start_at = m.begin(0) + 1
    end
  when 2
    a = jump_to_chars[0]
    b = jump_to_chars[1]
    needle = Regexp.escape(a + b)
    regex = if a == a.upcase
      /\b#{needle}/
    else
      /\b#{needle}/i
    end
    start_at = 0
    while (m = regex.match(screen_chars, start_at))
      positions << m.begin(0)
      start_at = m.begin(0) + 1
    end
  end
  positions
end

# Extended: supports 1-char or 2-char sequences.

# Return an approximate terminal column width for a character.
def char_width(char)
  cp = char.ord
  # Printable ASCII fast path. This is almost every character on a normal
  # screen, and it skips the dozen Range#cover? tests below.
  return 1 if cp >= 0x20 && cp < 0x7f

  # Control characters and DEL / C1 controls
  return 0 if cp <= 0x1f || (cp >= 0x7f && cp <= 0x9f)

  # Zero-width: combining marks, variation selectors and the zero-width
  # space/joiner group. tmux packs these into the preceding cell, so counting
  # them as 1 column shifts every marker after them on the line.
  return 0 if (0x0300..0x036f).cover?(cp) ||   # combining diacritical marks
              (0x0483..0x0489).cover?(cp) ||
              (0x0591..0x05bd).cover?(cp) ||
              (0x0610..0x061a).cover?(cp) ||
              (0x064b..0x065f).cover?(cp) ||
              (0x0670..0x0670).cover?(cp) ||
              (0x1ab0..0x1aff).cover?(cp) ||   # combining diacriticals ext.
              (0x1dc0..0x1dff).cover?(cp) ||   # combining diacriticals suppl.
              (0x200b..0x200f).cover?(cp) ||   # ZWSP / ZWNJ / ZWJ / LRM / RLM
              (0x20d0..0x20f0).cover?(cp) ||   # combining marks for symbols
              (0xfe00..0xfe0f).cover?(cp) ||   # variation selectors
              (0xfe20..0xfe2f).cover?(cp) ||   # combining half marks
              (0x1f3fb..0x1f3ff).cover?(cp) || # emoji skin-tone modifiers
              (0xe0100..0xe01ef).cover?(cp)    # variation selectors suppl.

  # Rough East Asian Wide / Emoji ranges (wcwidth-like)
  return 2 if (0x1100..0x115f).cover?(cp) ||
              (0x2329..0x232a).cover?(cp) ||
              (0x2e80..0xa4cf).cover?(cp) ||
              (0xac00..0xd7a3).cover?(cp) ||
              (0xf900..0xfaff).cover?(cp) ||
              (0xfe10..0xfe19).cover?(cp) ||
              (0xfe30..0xfe6f).cover?(cp) ||
              (0xff00..0xff60).cover?(cp) ||
              (0xffe0..0xffe6).cover?(cp) ||
              (0x1f300..0x1f64f).cover?(cp) ||
              (0x1f900..0x1f9ff).cover?(cp)

  1
end

def draw_keys_onto_tty(screen_chars, positions, keys, key_len)
  if Config.alternate_on == '1'
    # Existing pane already has content; overlay markers only.
    draw_keys_with_cursor screen_chars, positions, keys, key_len
  else
    # We entered a fresh alternate screen; need to paint base text then overlay markers.
    draw_keys_with_overlay screen_chars, positions, keys, key_len
  end
end

# Byte offsets of every line start, found with String#index (a C scan) instead of
# walking characters in Ruby. Built once per draw and shared by both draw paths.
def line_starts_of(screen_chars)
  starts = [0]
  at = 0
  while (at = screen_chars.index("\n", at))
    at += 1
    starts << at
  end
  starts
end

# Display column of `index` within the line beginning at `line_start`.
#
# The ASCII fast path is what makes this cheap: for a line with no multi-byte
# characters the column IS the offset, so no per-character work happens at all.
# Only a genuinely wide/combining line pays for char_width, and only over that
# one line's prefix rather than the whole screen.
def column_of(screen_chars, line_start, index)
  prefix = screen_chars[line_start...index]
  return 0 if prefix.nil?
  return prefix.length if prefix.ascii_only?

  width = 0
  prefix.each_char { |char| width += char_width(char) }
  width
end

# The marker escape sequences, in position order. Emitted identically by both
# draw paths, which previously carried two copies of this arithmetic.
def marker_sequences(screen_chars, positions, keys, key_len)
  starts = line_starts_of screen_chars
  off_left = Config.keys_position == 'off_left'
  red = Config.red
  out = String.new
  row = 0

  positions.each_with_index do |target, key_index|
    if target >= screen_chars.length
      # Past the end of the screen: the original code left the cursor wherever
      # the final character put it, i.e. the end of the last line.
      row = starts.size - 1
      column = column_of screen_chars, starts[row], screen_chars.length
    else
      # positions is ascending, so advance rather than search.
      row += 1 while row + 1 < starts.size && starts[row + 1] <= target
      column = column_of screen_chars, starts[row], target
    end

    column = column - key_len if off_left
    column = 0 if column < 0

    out << "\e[#{row + 1};#{column + 1}H" << red << keys[key_index] << RESET_COLORS
  end

  out << HOME_SEQ
  out
end

def draw_keys_with_cursor(screen_chars, positions, keys, key_len)
  File.open(Config.pane_tty_file, 'a') do |tty|
    tty << marker_sequences(screen_chars, positions, keys, key_len)
  end
end

def draw_keys_with_overlay(screen_chars, positions, keys, key_len)
  File.open(Config.pane_tty_file, 'a') do |tty|
    # Paint the whole buffer once with the background colour, then overlay.
    tty << Config.gray << screen_chars.gsub("\n", "\n\r") << RESET_COLORS
    tty << marker_sequences(screen_chars, positions, keys, key_len)
  end
end

def keys_for(position_count, keys = KEYS)
  if position_count > keys.size
    keys_for(position_count, keys.product(KEYS).map(&:join))
  else
    keys
  end
end

def prompt_position_index!(positions, screen_chars)
  return nil if positions.empty?
  return 0 if positions.size == 1

  keys = keys_for positions.size
  key_len = keys.first.size
  draw_keys_onto_tty screen_chars, positions, keys, key_len
   char = prompt_char!
   return nil if char.nil? # Handle cancellation

   key_index = KEYS.index(char)

  if !key_index.nil? && key_len > 1
    magnitude = KEYS.size ** (key_len - 1)
    range_beginning = key_index * magnitude
    range_ending = range_beginning + magnitude - 1
    remaining_positions = positions[range_beginning..range_ending]
    return nil if remaining_positions.nil?
    lower_index = prompt_position_index!(remaining_positions, screen_chars)
    return nil if lower_index.nil?
    range_beginning + lower_index
  else
    key_index
  end
end



def main(screen_chars)
  # String.new, not '': the frozen_string_literal pragma above makes literals
  # frozen, and this one is appended to.
  jump_to_chars = String.new

  # Jump mode, with env fallbacks. Both @jump-mode-* options already arrived
  # with the pane data, so this costs no tmux round-trip.
  double = Config.mode == 'double'
  if double
    jm = Config.mode_double.to_s
    jump_mode = (jm.empty? ? (ENV['JUMP_MODE_DOUBLE'] || 'char') : jm)
  else
    jm = Config.mode_single.to_s
    jump_mode = (jm.empty? ? (ENV['JUMP_MODE_SINGLE'] || 'word') : jm)
  end

  prompt_path = Config.prompt_file
  launcher_prompt = prompt_path && !prompt_path.empty? && Config.arg_first.nil?
  prompted_chars =
    if launcher_prompt
      io = open_prompt_fifo prompt_path
      # The launcher signals on this channel as each prompt resolves, so <Esc>
      # aborts immediately instead of waiting out PROMPT_TIMEOUT.
      cancel_path = Config.cancel_file
      cancel_io = open_prompt_fifo(cancel_path) if cancel_path && !cancel_path.empty?
      begin
        # One character: the launcher only ever opens one prompt. In double mode
        # the second prompt is opened below, via prompt_char!, so that <Esc> on
        # the first character aborts without leaving an orphan prompt behind.
        read_chars_from_fifo(io, 1, PROMPT_TIMEOUT, cancel_io)
      ensure
        io.close
        cancel_io.close if cancel_io
      end
    end

  # A launcher prompt that yielded nothing was cancelled (or timed out). That is
  # a definitive answer -- fall through to prompt_char! here and the user gets a
  # SECOND prompt popped in their face for a jump they just aborted.
  Kernel.exit 0 if launcher_prompt && prompted_chars.nil?

  # Read the first character (prompt already running in tmux via shell script)
  first_char = Config.arg_first || (prompted_chars && prompted_chars[0]) || prompt_char!
  Kernel.exit 0 if first_char.nil?
  jump_to_chars << first_char

  if double
    # Config.arg_first doubles as the legacy combined-chars form ("ab" in one
    # arg), hence the [1] fallback here. Otherwise we open the second prompt
    # ourselves -- reached only because the first character was accepted.
    second_char = Config.arg_second || (Config.arg_first && Config.arg_first[1]) ||
                  prompt_char!('char2:')
    Kernel.exit 0 if second_char.nil?
    jump_to_chars << second_char
  end

  # If punctuation or any non-word chars are used, force 'char' mode
  if jump_mode == 'word' && jump_to_chars.chars.any? { |c| (c =~ /\w/).nil? }
    jump_mode = 'char'
  end

  positions = positions_of jump_to_chars, screen_chars, jump_mode
  position_index = recover_screen_after do
    prompt_position_index! positions, screen_chars
  end

  Kernel.exit 0 if position_index.nil?
  jump_to = positions[position_index]

  jump_to_index! jump_to, screen_chars
end

# Translate a character index into `screen_chars` into the row / character
# offset pair that copy-mode navigation needs.
#
# A linear `-N <index> cursor-right` must NOT be used. tmux 3.7 made the
# end-of-line stop depend on `mode-keys` (grid_reader_cursor_right() gained an
# `onemore` argument, set only for emacs mode). Under `mode-keys vi` the cursor
# can no longer rest one past the last character, so crossing a line of length L
# costs L moves, while that line costs L + 1 characters in `screen_chars` (its
# chars plus the trailing "\n"). The error accumulates one column per line.
# tmux 3.6a and earlier always allowed the extra stop, which is why the linear
# form used to work.
#
# Row/column navigation avoids the issue entirely: the offset is always within
# the line, so the end-of-line wrap never comes into play and the result is the
# same for both `mode-keys` settings.
def row_and_offset_of(index, screen_chars)
  prefix = screen_chars[0, index]
  row = prefix.count("\n")
  last_newline = prefix.rindex("\n")
  line_prefix = last_newline ? prefix[(last_newline + 1)..] : prefix

  # Count grapheme clusters, not columns and not code points. One cursor-right
  # crosses exactly one cell: a wide character occupies two columns but one
  # cell, and tmux packs a base character together with its combining marks into
  # a single cell. For an all-ASCII prefix clusters and code points coincide, and
  # #ascii_only? is a cached-coderange check ~900x cheaper than segmenting, so
  # the common case never segments at all.
  offset =
    if line_prefix.ascii_only?
      line_prefix.length
    else
      line_prefix.each_grapheme_cluster.count
    end

  [row, offset]
end

def jump_to_index!(index, screen_chars)
  row, offset = row_and_offset_of index, screen_chars
  tmux!(*jump_argv(row, offset, screen_chars))
end

# STICKY END-OF-LINE -- the reason this is not just top-line + cursor-down.
#
# Every vertical step in copy mode restores a remembered column (`lastcx`), and
# window_copy only updates that memory while the cursor is NOT at the end of its
# line. On a row with no text column 0 IS the end of the line, and a fresh copy
# mode starts with the memory zeroed, so until the cursor has left a row with
# text on it every step re-snaps to the end of whatever row it lands on. The
# `cursor-right` that follows then wraps onto the row below, which is what puts
# the cursor a row down and a column left of the marker the user pressed.
#
# A blank first row is not exotic: any full-screen program that pads its frame
# has one, and that is exactly when this bites.
#
# Two ways out, both verified against a live tmux 3.7b under `mode-keys vi` and
# `mode-keys emacs`, on blank-top-row, wrapped-line and scrolled-back screens:
#
#   * Start from a row that has text on it. `top-line` / `bottom-line` set the
#     cursor outright rather than stepping, so they never snap, and the first
#     step away from a row with text primes the memory correctly for the whole
#     trip -- blank rows crossed later are then harmless. Costs nothing.
#   * Hold the column in a rectangle selection, which suppresses the snap the
#     way vim's visual block preserves a column. Correct anywhere, but each step
#     redraws the selection: ~1ms per row on a 218-column pane, so it is the
#     fallback rather than the rule.
#
# Resetting the column after the fact is NOT an option: `start-of-line`, and
# `back-to-indentation` which calls it internally, both resolve to the start of
# the *logical* line and walk up through GRID_LINE_WRAPPED rows, so on a wrapped
# row -- any long command or log line -- they land above the target row.

# The copy-mode command chain that lands the cursor on (row, offset) of
# `screen_chars`. One chain, one round-trip; kept pure so spec/ can assert the
# exact command sequence without a live server.
def jump_argv(row, offset, screen_chars,
              pane = Config.pane_nr,
              scroll = Config.scroll_position.to_i,
              height = Config.pane_height.to_i,
              history_size = Config.history_size.to_i,
              line_numbers = Config.line_numbers)
  send_x = [';', 'send-keys', '-X', '-t', pane]
  starts = line_starts_of screen_chars

  # copy-mode opens on the live view. When the capture came from scrollback,
  # `goto-line scroll` moves straight to its first row; walking there with
  # `cursor-up` would redraw once per history row and make deep jumps needlessly
  # slow. The bottom anchor is in the capture only when the pane is not scrolled.
  bottom = height - 1

  if !blank_row?(screen_chars, starts, 0)
    from_top, guard = true, false
  elsif scroll.zero? && height > 0 && !blank_row?(screen_chars, starts, bottom)
    from_top, guard = false, false
  else
    from_top, guard = true, true
  end

  up = from_top ? 0 : bottom - row
  down = from_top ? row : 0
  guard &&= up + down > 0

  argv = ['copy-mode', '-t', pane, *send_x, from_top ? 'top-line' : 'bottom-line']
  if from_top && scroll > 0
    # absolute/relative/hybrid all make goto-line count from the oldest history
    # line; off/default use the distance from the live view.
    absolute = %w[absolute relative hybrid].include?(line_numbers)
    line = absolute ? history_size - scroll + 1 : scroll
    argv.concat [*send_x, 'goto-line', line.to_s]
  end
  argv.concat [*send_x, 'begin-selection', *send_x, 'rectangle-toggle'] if guard
  argv.concat [*send_x, '-N', up.to_s, 'cursor-up'] if up > 0
  argv.concat [*send_x, '-N', down.to_s, 'cursor-down'] if down > 0
  argv.concat [*send_x, 'rectangle-toggle', *send_x, 'clear-selection'] if guard
  argv.concat [*send_x, '-N', offset.to_s, 'cursor-right'] if offset > 0
  argv
end

# Whether copy-mode sees no text on `row`, i.e. whether its column 0 is also its
# end of line. capture-pane without `-e` gives us plain text, and both empty and
# spaces-only rows have zero text width to copy-mode. The range check is
# defensive for a short or malformed capture.
def blank_row?(screen_chars, starts, row)
  return true if row.negative? || row >= starts.size

  start = starts[row]
  finish = screen_chars.index("\n", start) || screen_chars.length
  screen_chars[start...finish].lstrip.empty?
end

if $PROGRAM_NAME == __FILE__
  parse_argv! ARGV
  # One round-trip: geometry, every @jump-* option, and the correctly-scrolled
  # screen. Nothing looks at tmux again until the jump chain fires.
  screen = read_startup_state!

  begin
    main screen
  ensure
    cleanup_prompt_file
  end
end

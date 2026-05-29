#!/usr/bin/env ruby
require 'timeout'
require 'tempfile'

# Args: mode then optional pre-read chars (from tmux command-prompt)
# Supports either a single combined string (e.g., "%1%2") or two separate args (%1 %2)
args = ARGV.dup
MODE = (args.shift || 'single')
prompt_file = nil
if args[0] == '--prompt-file'
  args.shift
  prompt_file = args.shift
end
PROMPT_FILE = prompt_file
ARG_FIRST = args[0]
ARG_SECOND = args[1]
PRECHARS = args[0] # backward compatibility when both chars are concatenated in one arg

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
  :pane_mode,
  :cursor_y,
  :cursor_x,
  :alternate_on,
  :scroll_position,
  :pane_height,
  # Added for performance
  :gray,
  :red,
  :keys_position
).new

# METHODS
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
  rescue Timeout::Error, Interrupt
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
    `tmux capture-pane -ep -t #{Config.pane_nr}`[0..-2] # with colors...
      .gsub("\n", "\n\r")
  File.open(Config.pane_tty_file, 'a') do |tty|
    tty << HOME_SEQ
  end
  returns = nil
  begin
    returns = yield
  rescue Timeout::Error, Interrupt
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

def prompt_char! # raises Timeout::Error
  tmp_file = Tempfile.new 'tmux-jump'
  pid = Kernel.spawn(
    'tmux', 'command-prompt', '-1', '-p', 'char:',
    "run-shell \"printf '%1' >> #{tmp_file.path}\""
  )

  result_queue = Queue.new
  thread_0 = async_read_char_from_file! tmp_file, result_queue
  thread_1 = async_detect_prompt_exit pid, tmp_file, result_queue

  char = nil
  begin
    char = result_queue.pop
  rescue Interrupt
    thread_0.kill
    thread_1.kill
    # try to cancel any active tmux prompt so it doesn't linger
    begin
      `tmux send-keys Escape`
    rescue StandardError
    end
    return nil
  end

  # Handle cancellation key (e.g., <Esc>)
  return nil if char.nil? || char == "\e"

  thread_0.kill
  thread_1.kill

  char
end

def read_char_from_file(tmp_file, timeout_seconds = 10) # raises Timeout::Error
  char = nil
  begin
    Timeout.timeout(timeout_seconds) do
      loop do
        # busy waiting with files :/
        break if char = tmp_file.getc
        sleep 0.01
      end
    end
  rescue Interrupt
    return nil
  end
  char
end

def read_chars_from_prompt_file(path, char_count, timeout_seconds = 10)
  chars = nil
  Timeout.timeout(timeout_seconds) do
    loop do
      data = File.exist?(path) ? File.binread(path) : ''
      return nil if data.start_with?("\e")

      chars = data.each_char.first(char_count).join
      break if chars.length >= char_count

      sleep 0.005
    end
  end
  chars
rescue Timeout::Error, Interrupt
  nil
end

def async_read_char_from_file!(tmp_file, result_queue)
  thread = Thread.new do
    begin
      char = read_char_from_file tmp_file
      result_queue.push char
    rescue Timeout::Error, Interrupt
      result_queue.push nil
    ensure
      tmp_file.close!
    end
  end
  thread.abort_on_exception = true
  thread
end

def async_detect_prompt_exit(pid, tmp_file, result_queue)
  Thread.new do
    Process.wait(pid)
    # The prompt process has finished.
    # Give a tiny bit of time for the filesystem to catch up, just in case.
    sleep 0.01
    # If the other thread hasn't already found a character (file is empty),
    # it means the prompt was cancelled.
    if tmp_file.size == 0
      result_queue.push nil
    end
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
      end
    else
      hay = screen_chars.downcase
      needle = (a + b).downcase
      idx = -1
      while idx = hay.index(needle, idx + 1)
        positions << idx
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
  # Control characters and DEL / C1 controls
  return 0 if cp <= 0x1f || (cp >= 0x7f && cp <= 0x9f)

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

def draw_keys_with_buffer(screen_chars, positions, keys, key_len)
  # Legacy; not used.
  draw_keys_with_overlay screen_chars, positions, keys, key_len
end

def draw_keys_with_cursor(screen_chars, positions, keys, key_len)
  File.open(Config.pane_tty_file, 'a') do |tty|
    output = String.new
    line = 0
    column = 0
    index = 0
    target = positions[index]

    screen_chars.each_char.with_index do |char, idx|
      break if target.nil?

      while target == idx
        draw_column =
          if Config.keys_position == 'off_left'
            [column - key_len, 0].max
          else
            column
          end

        output << "\e[#{line + 1};#{draw_column + 1}H"
        output << Config.red
        output << keys[index]
        output << RESET_COLORS

        index += 1
        target = positions[index]
      end

      if char == "\n"
        line += 1
        column = 0
      else
        column += char_width(char)
      end
    end

    while target
      draw_column =
        if Config.keys_position == 'off_left'
          [column - key_len, 0].max
        else
          column
        end

      output << "\e[#{line + 1};#{draw_column + 1}H"
      output << Config.red
      output << keys[index]
      output << RESET_COLORS

      index += 1
      target = positions[index]
    end

    output << HOME_SEQ
    tty << output
  end
end

def draw_keys_with_overlay(screen_chars, positions, keys, key_len)
  File.open(Config.pane_tty_file, 'a') do |tty|
    base = String.new
    # Paint full buffer once with background color
    base << Config.gray
    base << screen_chars.gsub("\n", "\n\r")
    base << RESET_COLORS
    # Now overlay markers using cursor addressing
    line = 0
    column = 0
    positions_index = 0
    target = positions[positions_index]
    screen_chars.each_char.with_index do |char, idx|
      break if target.nil?
      while target == idx
        draw_column =
          if Config.keys_position == 'off_left'
            [column - key_len, 0].max
          else
            column
          end
        base << "\e[#{line + 1};#{draw_column + 1}H"
        base << Config.red
        base << keys[positions_index]
        base << RESET_COLORS
        positions_index += 1
        target = positions[positions_index]
      end
      if char == "\n"
        line += 1
        column = 0
      else
        column += char_width(char)
      end
    end
    # Remaining markers if any after end (unlikely)
    while target
      draw_column =
        if Config.keys_position == 'off_left'
          [column - key_len, 0].max
        else
          column
        end
      base << "\e[#{line + 1};#{draw_column + 1}H"
      base << Config.red
      base << keys[positions_index]
      base << RESET_COLORS
      positions_index += 1
      target = positions[positions_index]
    end
    base << HOME_SEQ
    tty << base
  end
end

def keys_for(position_count, keys = KEYS)
  if position_count > keys.size
    keys_for(position_count, keys.product(KEYS).map(&:join))
  else
    keys
  end
end

def prompt_position_index!(positions, screen_chars) # raises Timeout::Error
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



def main
  jump_to_chars = ''
  `tmux send-keys -X -t #{Config.pane_nr} cancel` if Config.pane_mode == '1'

  start = -Config.scroll_position
  ending = -Config.scroll_position + Config.pane_height - 1
  screen_chars =
    `tmux capture-pane -p -t #{Config.pane_nr} -S #{start} -E #{ending}`[0..-2].gsub("︎", '') # without colors

  # Resolve jump mode from tmux options with env fallbacks while the prompt can
  # still be waiting for input.
  if MODE == 'double'
    jm = `tmux show-option -gqv '@jump-mode-double'`.strip
    jump_mode = (jm.empty? ? (ENV['JUMP_MODE_DOUBLE'] || 'char') : jm)
  else
    jm = `tmux show-option -gqv '@jump-mode-single'`.strip
    jump_mode = (jm.empty? ? (ENV['JUMP_MODE_SINGLE'] || 'word') : jm)
  end

  prompted_chars =
    if PROMPT_FILE && !PROMPT_FILE.empty?
      read_chars_from_prompt_file(PROMPT_FILE, MODE == 'double' ? 2 : 1)
    end

  # Read the first character (prompt already running in tmux via shell script)
  first_char = ARG_FIRST || (PRECHARS && PRECHARS[0]) || (prompted_chars && prompted_chars[0]) || prompt_char!
  Kernel.exit 0 if first_char.nil?
  jump_to_chars << first_char

  if MODE == 'double'
    second_char = ARG_SECOND || (PRECHARS && PRECHARS[1]) || (prompted_chars && prompted_chars[1]) || prompt_char!
    Kernel.exit 0 if second_char.nil?
    jump_to_chars << second_char
  end

  # Cancel tmux copy-mode prompt if we were in command mode.
  `tmux send-keys -X -t #{Config.pane_nr} cancel` if Config.pane_mode == '1'

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

  # --- JUMP SEQUENCE ---
  # Enter copy-mode if not already
  `tmux copy-mode -t #{Config.pane_nr}`

  # Go to top of visible area and start of line
  `tmux send-keys -X -t #{Config.pane_nr} top-line`
  `tmux send-keys -X -t #{Config.pane_nr} start-of-line`

  # Adjust for scroll offset by moving DOWN from the top
  if Config.scroll_position > 0
    `tmux send-keys -X -t #{Config.pane_nr} -N #{Config.scroll_position} cursor-down`
  end

  # Move cursor to target position (cursor-right wraps at line ends)
  if jump_to > 0
    `tmux send-keys -X -t #{Config.pane_nr} -N #{jump_to} cursor-right`
  end
end

if $PROGRAM_NAME == __FILE__
  # Get pane data with a single tmux call for performance
  format = '#{pane_id};#{pane_tty};#{pane_in_mode};#{cursor_y};#{cursor_x};'\
           '#{alternate_on};#{scroll_position};#{pane_height}'
  tmux_data = `tmux display-message -p -F "#{format}"`.strip.split(';')

  Config.pane_nr = tmux_data[0]
  Config.pane_tty_file = tmux_data[1]
  Config.pane_mode = tmux_data[2]
  Config.cursor_y = tmux_data[3]
  Config.cursor_x = tmux_data[4]
  Config.alternate_on = tmux_data[5]
  Config.scroll_position = tmux_data[6].to_i
  Config.pane_height = tmux_data[7].to_i

  # Read color and position config from tmux options so chaining via run-shell preserves settings
  bg_opt = `tmux show-option -gqv '@jump-bg-color'`.strip
  fg_opt = `tmux show-option -gqv '@jump-fg-color'`.strip
  pos_opt = `tmux show-option -gqv '@jump-keys-position'`.strip
  Config.gray = (bg_opt.empty? ? (ENV['JUMP_BACKGROUND_COLOR'] || "\e[48;5;240m") : bg_opt).gsub('\\e', "\e")
  Config.red  = (fg_opt.empty? ? (ENV['JUMP_FOREGROUND_COLOR'] || "\e[1m\e[31m") : fg_opt).gsub('\\e', "\e")
  Config.keys_position = pos_opt.empty? ? (ENV['JUMP_KEYS_POSITION'] || 'left') : pos_opt

  main
end

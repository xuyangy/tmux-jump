#!/usr/bin/env ruby
require 'timeout'
require 'tempfile'
require 'open3'

# SPECIAL STRINGS
GRAY = ENV['JUMP_BACKGROUND_COLOR'].gsub('\e', "\e")
# RED = "\e[38;5;124m"
RED = ENV['JUMP_FOREGROUND_COLOR'].gsub('\e', "\e")
CLEAR_SEQ = "\e[2J"
HOME_SEQ = "\e[H"
RESET_COLORS = "\e[0m"
ENTER_ALTERNATE_SCREEN = "\e[?1049h"
RESTORE_NORMAL_SCREEN = "\e[?1049l"

# CONFIG
KEYS_POSITION = ENV['JUMP_KEYS_POSITION']
KEYS = (ENV['JUMP_KEYS'] || 'jfhgkdlsa').each_char.to_a
SECOND_CHAR_TIMEOUT =
  begin
    Float(ENV['JUMP_SECOND_CHAR_TIMEOUT'] || 0.35)
  rescue
    0.35
  end
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
  :tmp_file
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
  File.open(Config.pane_tty_file, 'a') { |tty| tty << ENTER_ALTERNATE_SCREEN + HOME_SEQ }
  begin
    returns = yield
  rescue Timeout::Error
    # user took too long, but we recover anyways
  end
  File.open(Config.pane_tty_file, 'a') { |tty| tty << RESTORE_NORMAL_SCREEN }
  returns
end

def recover_alternate_screen_after
  saved_screen =
    `tmux capture-pane -ep -t #{Config.pane_nr}`[0..-2] # with colors...
      .gsub("\n", "\n\r")
  File.open(Config.pane_tty_file, 'a') { |tty| tty << CLEAR_SEQ + HOME_SEQ }
  begin
    returns = yield
  rescue Timeout::Error
    # user took too long, but we recover anyways
  end
  File.open(Config.pane_tty_file, 'a') do |tty|
    tty << RESET_COLORS + CLEAR_SEQ
    tty << saved_screen
    tty << "\e[#{Config.cursor_y.to_i + 1};#{Config.cursor_x.to_i + 1}H"
    tty << RESET_COLORS
  end
  returns
end

def prompt_char! # raises Timeout::Error
  tmp_file = Tempfile.new 'tmux-jump'
  Kernel.spawn(
    'tmux', 'command-prompt', '-1', '-p', 'char:',
    "run-shell \"printf '%1' >> #{tmp_file.path}\""
  )

  result_queue = Queue.new
  thread_0 = async_read_char_from_file! tmp_file, result_queue
  thread_1 = async_detect_user_escape result_queue

  char = result_queue.pop

  thread_0.kill
  thread_1.kill

  char
end

def read_char_from_file(tmp_file, timeout_seconds = 10) # raises Timeout::Error
  char = nil
  Timeout.timeout(timeout_seconds) do
    until char
      ready = IO.select([tmp_file], nil, nil, 0.1) # Wait for up to 0.1s for input
      char = tmp_file.getc if ready
    end
  end
  char
end

def async_read_char_from_file!(tmp_file, result_queue)
  thread = Thread.new do
    char = read_char_from_file tmp_file
    File.delete tmp_file.path
    result_queue.push char
  end
  thread.abort_on_exception = true
  thread
end

def async_detect_user_escape(result_queue)
  Thread.new do
    last_activity =
      Open3.capture2 'tmux', 'display-message', '-p', '#{session_activity}'
    loop do
      new_activity =
        Open3.capture2 'tmux', 'display-message', '-p', '#{session_activity}'
      sleep 0.05
      if last_activity != new_activity
        # Optionally push escape signal here if wanted
        # result_queue.push nil
      end
    end
  end
end

# Extended: supports 1-char or 2-char sequences.
def positions_of(jump_to_chars, screen_chars)
  positions = []
  case jump_to_chars.length
  when 1
    target = jump_to_chars[0].downcase
    return positions unless target =~ /\w/  # only jump to 'word' chars
    screen_chars.each_char.with_index do |char, i|
      next unless char =~ /\w/
      # mimic original semantic: start-of-word (start of buffer or previous non-word)
      if char.downcase == target && (i == 0 || (screen_chars[i - 1] =~ /\w/).nil?)
        positions << i
      end
    end
  when 2
    a = jump_to_chars[0].downcase
    b = jump_to_chars[1].downcase
    # original logic preserved / mildly hardened
    if screen_chars[0] && screen_chars[1] &&
       screen_chars[0] =~ /\w/ &&
       screen_chars[0].downcase == a &&
       screen_chars[1].downcase == b
      positions << 0
    end
    screen_chars.each_char.with_index do |char, i|
      # we consider the next two chars starting after a non-word boundary
      if (char =~ /\w/).nil? \
         && screen_chars[i + 1] && screen_chars[i + 1].downcase == a \
         && screen_chars[i + 2] && screen_chars[i + 2].downcase == b
        positions << i + 1
      end
    end
  else
    # Fallback (should not happen): treat as no matches
  end
  positions
end

def draw_keys_onto_tty(screen_chars, positions, keys, key_len)
  File.open(Config.pane_tty_file, 'a') do |tty|
    cursor = 0
    positions.each_with_index do |pos, i|
      tty << "#{GRAY}#{screen_chars[cursor..pos-1].to_s.gsub("\n", "\n\r")}"
      tty << "#{RED}#{keys[i]}"
      cursor = [pos + key_len - (KEYS_POSITION == 'off_left' ? key_len : 0), 0].max
    end
    tty << "#{GRAY}#{screen_chars[cursor..-1].to_s.gsub("\n", "\n\r")}"
    tty << HOME_SEQ
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
  key_index = KEYS.index(prompt_char!)

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

def read_optional_second_char(file)
  # Try to read a second char within a shorter timeout; if not, return nil.
  read_char_from_file(file, SECOND_CHAR_TIMEOUT)
rescue Timeout::Error
  nil
end

def main
  jump_to_chars = ''
  chars_read_file = nil
  begin
    chars_read_file = File.new(Config.tmp_file)
    first_char = read_char_from_file(chars_read_file) # up to 10s
    jump_to_chars << first_char
    # Attempt to read a second char quickly; if user doesn't type one, proceed with single-char jump.
    second_char = read_optional_second_char(chars_read_file)
    jump_to_chars << second_char if second_char
  rescue Timeout::Error
    # Did not even get the first char – abort silently.
    Kernel.exit
  ensure
    if chars_read_file
      chars_read_file.close
      File.delete(chars_read_file.path)
    end
  end

  # Cancel tmux copy-mode prompt if we were in command mode.
  `tmux send-keys -X -t #{Config.pane_nr} cancel` if Config.pane_mode == '1'

  start = -Config.scroll_position
  ending = -Config.scroll_position + Config.pane_height - 1
  screen_chars =
    `tmux capture-pane -p -t #{Config.pane_nr} -S #{start} -E #{ending}`[0..-2]
      .gsub("︎", '') # remove weird artifacts

  positions = positions_of jump_to_chars, screen_chars
  position_index = recover_screen_after do
    prompt_position_index! positions, screen_chars
  end

  Kernel.exit 0 if position_index.nil?
  jump_to = positions[position_index]

  # Enter copy-mode if not already
  `tmux copy-mode -t #{Config.pane_nr}`

  # Tmux quirks handling (original logic)
  `tmux send-keys -X -t #{Config.pane_nr} start-of-line`
  `tmux send-keys -X -t #{Config.pane_nr} top-line`
  `tmux send-keys -X -t #{Config.pane_nr} -N 200 cursor-right`
  `tmux send-keys -X -t #{Config.pane_nr} start-of-line`
  `tmux send-keys -X -t #{Config.pane_nr} top-line`

  # Adjust for scroll offset
  if Config.scroll_position > 0
    `tmux send-keys -X -t #{Config.pane_nr} -N #{Config.scroll_position} cursor-up`
  end

  # Move cursor to target
  `tmux send-keys -X -t #{Config.pane_nr} -N #{jump_to} cursor-right`
end

if $PROGRAM_NAME == __FILE__
  Config.pane_nr = `tmux display-message -p "\#{pane_id}"`.strip
  format = '#{pane_id};#{pane_tty};#{pane_in_mode};#{cursor_y};#{cursor_x};'\
           '#{alternate_on};#{scroll_position};#{pane_height}'
  tmux_data = `tmux display-message -p -t #{Config.pane_nr} -F "#{format}"`.strip.split(';')
  Config.pane_tty_file = tmux_data[1]
  Config.pane_mode = tmux_data[2]
  Config.cursor_y = tmux_data[3]
  Config.cursor_x = tmux_data[4]
  Config.alternate_on = tmux_data[5]
  Config.scroll_position = tmux_data[6].to_i
  Config.pane_height = tmux_data[7].to_i
  Config.tmp_file = ARGV[0]
  main
end

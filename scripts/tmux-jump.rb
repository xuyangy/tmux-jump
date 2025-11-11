#!/usr/bin/env ruby
require 'timeout'
require 'tempfile'

# Args: possible tmp_file then mode (for back-compat we detect file path)
ARG_TMP = ARGV[0]
ARG_MODE = ARGV[1]
MODE = (ARG_MODE || ARG_TMP || 'single')
EXTERNAL_TMP_FILE = (ARG_MODE ? ARG_TMP : nil)

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

def prompt_char!(external: nil) # raises Timeout::Error
  # If external prompt file provided (shell already did tmux command-prompt), reuse it
  # only when explicitly requested. Otherwise spawn our own prompt.
  use_external = external.nil? ? false : external
  if use_external && EXTERNAL_TMP_FILE
    $external_reader ||= File.new(EXTERNAL_TMP_FILE, 'r')
    begin
      char = read_char_from_file $external_reader
      return char
    rescue Timeout::Error
      return nil
    end
  end

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
    raise
  end

  # Handle cancellation key (e.g., <Esc>)
  if char.nil?
    Kernel.exit
  end

  thread_0.kill
  thread_1.kill

  char
end

def read_char_from_file(tmp_file, timeout_seconds = 10) # raises Timeout::Error
  char = nil
  Timeout.timeout(timeout_seconds) do
    loop do
      # busy waiting with files :/
      break if char = tmp_file.getc
      sleep 0.01
    end
  end
  char
end

def async_read_char_from_file!(tmp_file, result_queue)
  thread = Thread.new do
    begin
      char = read_char_from_file tmp_file
      result_queue.push char
    rescue Timeout::Error
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
    case_sensitive = (target == target.upcase)

    # Adjust target for case-insensitive matching if needed
    search_target = case_sensitive ? target : target.downcase

    screen_chars.each_char.with_index do |char, i|
      char_to_compare = case_sensitive ? char : char.downcase
      if char_to_compare == search_target
        positions << i
      end
    end
  when 2
    a = jump_to_chars[0]
    b = jump_to_chars[1]
    # Determine case sensitivity based on first character
    case_sensitive = a == a.upcase

    # Adjust for case-insensitive matching if needed
    a = a.downcase unless case_sensitive
    b = b.downcase unless case_sensitive

    (0..screen_chars.length - 2).each do |i|
      char_a = screen_chars[i]
      char_b = screen_chars[i+1]
      char_to_compare_a = case_sensitive ? char_a : char_a.downcase
      char_to_compare_b = case_sensitive ? char_b : char_b.downcase
      if char_to_compare_a == a && char_to_compare_b == b
        positions << i
      end
    end
  else
    # Fallback (should not happen): treat as no matches
  end
  positions
end

def positions_of_word(jump_to_chars, screen_chars)
  positions = []
  case jump_to_chars.length
  when 1
     target = jump_to_chars[0]
     case_sensitive = target == target.upcase

     # Adjust target for case-insensitive matching if needed
     target = target.downcase unless case_sensitive
    return positions unless target =~ /\w/  # only jump to 'word' chars
    screen_chars.each_char.with_index do |char, i|
      next unless char =~ /\w/
      # mimic original semantic: start-of-word (start of buffer or previous non-word)
       if (case_sensitive ? char == target : char.downcase == target) && (i == 0 || (screen_chars[i - 1] =~ /\w/).nil?)
        positions << i
      end
    end
  when 2
    a = jump_to_chars[0]
    b = jump_to_chars[1]
    # Determine case sensitivity based on first character
    case_sensitive = a == a.upcase

    # Adjust for case-insensitive matching if needed
    a = a.downcase unless case_sensitive
    b = b.downcase unless case_sensitive

    # Check if first two chars match at position 0
    if screen_chars[0] && screen_chars[1] &&
       screen_chars[0] =~ /\w/ &&
       (case_sensitive ? screen_chars[0] == a : screen_chars[0].downcase == a) &&
       (case_sensitive ? screen_chars[1] == b : screen_chars[1].downcase == b)
      positions << 0
    end

    screen_chars.each_char.with_index do |char, i|
      # we consider the next two chars starting after a non-word boundary
      if (char =~ /\w/).nil? \
         && screen_chars[i + 1] && screen_chars[i + 1] =~ /\w/ \
         && screen_chars[i + 2] \
         && (case_sensitive ? screen_chars[i + 1] == a : screen_chars[i + 1].downcase == a) \
         && (case_sensitive ? screen_chars[i + 2] == b : screen_chars[i + 2].downcase == b)
        positions << i + 1
      end
    end
  else
    # Fallback (should not happen): treat as no matches
  end
  positions
end

# Extended: supports 1-char or 2-char sequences.

def draw_keys_onto_tty(screen_chars, positions, keys, key_len)
  if Config.alternate_on == '1'
    draw_keys_with_cursor screen_chars, positions, keys, key_len
  else
    draw_keys_with_buffer screen_chars, positions, keys, key_len
  end
end

def draw_keys_with_buffer(screen_chars, positions, keys, key_len)
  File.open(Config.pane_tty_file, 'a') do |tty|
    output = String.new
    cursor = 0
    positions.each_with_index do |pos, i|
      output << "#{Config.gray}#{screen_chars[cursor..pos-1].to_s.gsub("\n", "\n\r")}"
      output << "#{Config.red}#{keys[i]}"
      cursor = [pos + key_len - (Config.keys_position == 'off_left' ? key_len : 0), 0].max
    end
    output << "#{Config.gray}#{screen_chars[cursor..-1].to_s.gsub("\n", "\n\r")}"
    output << HOME_SEQ
    tty << output
  end
end

def draw_keys_with_cursor(screen_chars, positions, keys, key_len)
  File.open(Config.pane_tty_file, 'a') do |tty|
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

        tty << "\e[#{line + 1};#{draw_column + 1}H"
        tty << Config.red
        tty << keys[index]
        tty << RESET_COLORS

        index += 1
        target = positions[index]
      end

      if char == "\n"
        line += 1
        column = 0
      else
        column += 1
      end
    end

    while target
      draw_column =
        if Config.keys_position == 'off_left'
          [column - key_len, 0].max
        else
          column
        end

      tty << "\e[#{line + 1};#{draw_column + 1}H"
      tty << Config.red
      tty << keys[index]
      tty << RESET_COLORS

      index += 1
      target = positions[index]
    end

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
   char = prompt_char!(external: false)
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

  # Read the first character (prompt already running in tmux via shell script)
  first_char = prompt_char!(external: true)
  Kernel.exit 0 if first_char.nil?
  jump_to_chars << first_char

  if MODE == 'double'
    second_char = prompt_char!(external: true)
    Kernel.exit 0 if second_char.nil?
    jump_to_chars << second_char
  end

  # Cancel tmux copy-mode prompt if we were in command mode.
  `tmux send-keys -X -t #{Config.pane_nr} cancel` if Config.pane_mode == '1'

  jump_mode = if MODE == 'double'
                ENV['JUMP_MODE_DOUBLE'] || 'word'
              else
                ENV['JUMP_MODE_SINGLE'] || 'word'
              end

  positions = positions_of jump_to_chars, screen_chars, jump_mode
  position_index = recover_screen_after do
    prompt_position_index! positions, screen_chars
  end

  Kernel.exit 0 if position_index.nil?
  jump_to = positions[position_index]

  # --- OPTIMIZED AND CORRECTED JUMP SEQUENCE ---
  # Enter copy-mode if not already
  `tmux copy-mode -t #{Config.pane_nr}`

  # Go to top of history and start of line
  `tmux send-keys -X -t #{Config.pane_nr} top-line`
  `tmux send-keys -X -t #{Config.pane_nr} start-of-line`

  # Adjust for scroll offset by moving DOWN from the top of history
  if Config.scroll_position > 0
    `tmux send-keys -X -t #{Config.pane_nr} -N #{Config.scroll_position} cursor-down`
  end

  # Move cursor to target
  `tmux send-keys -X -t #{Config.pane_nr} -N #{jump_to} cursor-right`
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

  # Read color and position config from ENV variables (set by the shell script)
  Config.gray = (ENV['JUMP_BACKGROUND_COLOR'] || '\e[0m\e[32m').gsub('\e', "\e")
  Config.red = (ENV['JUMP_FOREGROUND_COLOR'] || '\e[1m\e[31m').gsub('\e', "\e")
  Config.keys_position = ENV['JUMP_KEYS_POSITION'] || 'left'

  main
end

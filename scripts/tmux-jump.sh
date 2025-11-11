#!/usr/bin/env bash

mode="$1"

current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$current_dir/utils.sh"

# Export configuration
export JUMP_BACKGROUND_COLOR=$(get_tmux_option "@jump-bg-color" "\e[0m\e[32m")
export JUMP_FOREGROUND_COLOR=$(get_tmux_option "@jump-fg-color" "\e[1m\e[31m")
export JUMP_KEYS_POSITION=$(get_tmux_option "@jump-keys-position" "left")
export JUMP_MODE_SINGLE=$(get_tmux_option "@jump-mode-single" "word")
export JUMP_MODE_DOUBLE=$(get_tmux_option "@jump-mode-double" "char")

# Create a temp file and show the tmux prompt(s) immediately for snappy UX
tmp_file="$(mktemp)"
trap "rm -f '$tmp_file'" EXIT

if [[ "$mode" == "single" ]]; then
  tmux command-prompt -1 -p 'char:' "run-shell \"printf '%1' >> $tmp_file\""
elif [[ "$mode" == "double" ]]; then
  tmux command-prompt -1 -p 'char1:' "run-shell \"printf '%1' >> $tmp_file\""
  tmux command-prompt -1 -p 'char2:' "run-shell \"printf '%1' >> $tmp_file\""
else
  echo "Invalid mode. Use 'single' or 'double'." >&2
  exit 1
fi

# Run the Ruby script, passing the tmp file and mode
ruby "$current_dir/tmux-jump.rb" "$tmp_file" "$mode"

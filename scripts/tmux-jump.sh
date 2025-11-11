#!/usr/bin/env bash

mode="$1"

current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Use tmux command-prompt so the prompt shows instantly and Esc cancels immediately.
if [[ "$mode" == "single" ]]; then
  tmux command-prompt -1 -p 'char:' "run-shell 'ruby \"$current_dir/tmux-jump.rb\" single \"%1\"'"
elif [[ "$mode" == "double" ]]; then
  # Two prompts in one invocation; ensure both show trailing ':'
  tmux command-prompt -1 -p 'char1:,char2:' "run-shell 'ruby \"$current_dir/tmux-jump.rb\" double \"%1\" \"%2\"'"
else
  echo "Invalid mode. Use 'single' or 'double'." >&2
  exit 1
fi

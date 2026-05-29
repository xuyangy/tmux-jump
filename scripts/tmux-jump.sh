#!/usr/bin/env bash

mode="$1"

current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ "$mode" != "single" && "$mode" != "double" ]]; then
  echo "Invalid mode. Use 'single' or 'double'." >&2
  exit 1
fi

prompt_file="$(mktemp "${TMPDIR:-/tmp}/tmux-jump.XXXXXX")" || exit 1
ruby_path="$(tmux show-option -gqv '@jump-ruby-path')"

if [[ -z "$ruby_path" ]]; then
  if [[ -x /usr/local/opt/ruby/bin/ruby ]]; then
    ruby_path=/usr/local/opt/ruby/bin/ruby
  elif [[ -x /opt/homebrew/opt/ruby/bin/ruby ]]; then
    ruby_path=/opt/homebrew/opt/ruby/bin/ruby
  else
    ruby_path=ruby
  fi
fi

# Start Ruby before the prompt returns so pane capture and option lookup can run
# while the user is choosing the target character.
"$ruby_path" "$current_dir/tmux-jump.rb" "$mode" --prompt-file "$prompt_file" &

# Use tmux command-prompt so the prompt shows instantly and Esc cancels immediately.
if [[ "$mode" == "single" ]]; then
  tmux command-prompt -1 -p 'char:' "run-shell 'printf %s \"%1\" > \"$prompt_file\"'"
elif [[ "$mode" == "double" ]]; then
  # Use two single prompts so each callback only substitutes its own character.
  tmux command-prompt -1 -p 'char1:' "run-shell 'printf %s \"%%\" > \"$prompt_file\"; tmux command-prompt -1 -p \"char2:\" \"run-shell '\''printf %s \\\"%%\\\" >> \\\"$prompt_file\\\"'\''\"'"
fi

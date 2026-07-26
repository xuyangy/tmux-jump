#!/usr/bin/env bash
#
# $1 = mode ("single" | "double")
# $2 = ruby interpreter, resolved once at plugin load by tmux-jump.tmux
#
# There is deliberately no interpreter search here. Probing /usr/local/opt, then
# /opt/homebrew, then bare `ruby` can silently land on macOS's system ruby (2.6),
# which fails on the language features this script uses -- and it fails as a
# parse error, so the plugin simply does nothing with no diagnostic.

mode="$1"
ruby_path="$2"

current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ "$mode" != "single" && "$mode" != "double" ]]; then
  tmux display-message "tmux-jump: invalid mode '$mode' (expected single|double)"
  exit 1
fi

if [[ -z "$ruby_path" ]]; then
  tmux display-message "tmux-jump: set @jump-ruby-path to a ruby >= 3.4 executable"
  exit 1
fi

if [[ ! -x "$ruby_path" ]]; then
  tmux display-message "tmux-jump: @jump-ruby-path '$ruby_path' is not executable"
  exit 1
fi

# A FIFO, not a regular file: the reader blocks in IO.select and wakes the
# instant tmux writes, so there is no polling interval on the keypress path.
prompt_file="$(mktemp -u "${TMPDIR:-/tmp}/tmux-jump.XXXXXX")" || exit 1
mkfifo "$prompt_file" || exit 1

# Separate channel so "the prompt chain finished" can never be confused with a
# typed character. Opened read-write here so writing to it can never block, even
# if the worker has already exited.
cancel_file="$prompt_file.cancel"
mkfifo "$cancel_file" || exit 1
exec 8<>"$cancel_file"

# --disable-gems removes ~70% of interpreter startup (98ms -> 29ms measured).
# This script has no gem dependencies; adding one would undo it.
#
# Start ruby BEFORE the prompt so the remaining startup cost overlaps with the
# user's keystroke instead of being serialised after it. Do not reorder these.
"$ruby_path" --disable-gems "$current_dir/tmux-jump.rb" "$mode" \
  --prompt-file "$prompt_file" --cancel-file "$cancel_file" &

# Exactly ONE prompt here, in both modes. In double mode the worker opens the
# second prompt itself, after it has seen that the first character is usable.
#
# Do NOT chain the second prompt from this callback. `command-prompt -1` handles
# PROMPT_SINGLE before the status-keys translation and appends the key verbatim
# (tmux status.c), so <Esc> is delivered as a character rather than cancelling.
# A chained callback therefore opens the second prompt even when the user pressed
# <Esc>, leaving an orphan prompt that nothing is listening to -- which is why
# aborting a double jump used to take two <Esc> presses.
if [[ "$mode" == "single" ]]; then
  prompt_label='char:'
else
  prompt_label='char1:'
fi

# `tmux command-prompt` blocks until the prompt is answered.
tmux command-prompt -1 -p "$prompt_label" \
  "run-shell 'printf %s \"%1\" > \"$prompt_file\"'"

# Our prompt resolved. If nothing reached the worker it was cancelled, and this
# lets it stop now rather than waiting out its timeout.
printf x >&8
exec 8>&-

#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $CURRENT_DIR/scripts/utils.sh

# Resolve the interpreter ONCE, here at plugin load, and bake it into the key
# binding. Reading @jump-ruby-path per jump would cost a tmux round-trip (~10ms)
# on a path budgeted at a few tens of milliseconds total.
RUBY_PATH="$(get_tmux_option "@jump-ruby-path" "")"

tmux bind-key -N "Jump to pane location in copy mode" \
  "$(get_tmux_option "@jump-key" "j")" \
  run-shell -b "$CURRENT_DIR/scripts/tmux-jump.sh single '$RUBY_PATH'"

tmux bind-key -N "Jump to pane location (double key) in copy mode" \
  "$(get_tmux_option "@jump-double-key" "J")" \
  run-shell -b "$CURRENT_DIR/scripts/tmux-jump.sh double '$RUBY_PATH'"

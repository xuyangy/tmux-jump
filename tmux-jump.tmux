#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $CURRENT_DIR/scripts/utils.sh
tmux bind-key -N "Jump to pane location in copy mode" $(get_tmux_option "@jump-key" "j") run-shell -b "$CURRENT_DIR/scripts/tmux-jump.sh single"
tmux bind-key -N "Jump to pane location (double key) in copy mode" $(get_tmux_option "@jump-double-key" "J") run-shell -b "$CURRENT_DIR/scripts/tmux-jump.sh double"

#!/usr/bin/env bash

mode="$1"
current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$current_dir/utils.sh"
export JUMP_BACKGROUND_COLOR=$(get_tmux_option "@jump-bg-color" "\e[0m\e[32m")
export JUMP_FOREGROUND_COLOR=$(get_tmux_option "@jump-fg-color" "\e[1m\e[31m")
export JUMP_KEYS_POSITION=$(get_tmux_option "@jump-keys-position" "left")
fallback_jump_mode=$(get_tmux_option "@jump-mode" "word")
export JUMP_MODE_SINGLE=$(get_tmux_option "@jump-mode-single" "$fallback_jump_mode")
export JUMP_MODE_DOUBLE=$(get_tmux_option "@jump-mode-double" "$fallback_jump_mode")
ruby "$current_dir/tmux-jump.rb" "$mode"

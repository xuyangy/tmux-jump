<p align="center">
  <img src="assets/tmux-jump-logo.png"
       alt="Vimium/Easymotion like cursor jump for tmux."
       title="tmux-jump" />
</p>

[![Build Status](https://travis-ci.org/schasse/tmux-jump.svg?branch=master)](https://travis-ci.org/schasse/tmux-jump)

A fast way to jump wherever you want in your terminal without using the mouse. A plugin similar to [vimium](https://vimium.github.io/) and [easymotion](https://github.com/easymotion/vim-easymotion) but for tmux. tmux-jump is written in ruby and can easily be installed via tpm.

![tmux-jump-demo](https://user-images.githubusercontent.com/3882305/74186577-2f6aad80-4c4b-11ea-8054-91c54e3dd2af.gif)

From now to then I think about how to improve my dev tools. Copy and pasting inside the terminal is something I do everyday, all the time. This is one of the most obvious things make more efficient. [tmux-yank](https://github.com/tmux-plugins/tmux-yank) improved the situation a lot. Though, it felt still annoying to get to the string I wanted to copy. Either I used to enter tmux copy mode and moved the cursor to the string or I used the mouse. I looked for a plugin such as easymotion for vim or ace jump for emacs, but I couldn't find one. So I decided to write my own tmux plugin.

## Requirements

All of these are mandatory. The plugin is tuned for latency and deliberately
does not carry fallbacks for older versions — a jump budget is a few tens of
milliseconds, and compatibility shims cost more than they are worth.

* [tmux](https://github.com/tmux/tmux) >= 3.7 — pane state and every `@jump-*`
  option are read in a single format expansion, and cursor placement relies on
  3.7's `mode-keys`-aware copy-mode cursor semantics.
* [ruby](https://www.ruby-lang.org/) >= 3.4 — required for grapheme-cluster
  cell counting and for interpreter startup, which dominates the jump budget.

`@jump-ruby-path` is **required** — there is no interpreter search. Find the
path with `brew --prefix ruby` (Homebrew lives at `/usr/local` on Intel Macs and
`/opt/homebrew` on Apple Silicon), or `command -v ruby` otherwise:

```sh
# Intel macOS / Homebrew at /usr/local
set -g @jump-ruby-path '/usr/local/opt/ruby/bin/ruby'
```

It is read once at plugin load and baked into the key binding, so it costs
nothing per jump. Probing a list of likely locations was removed deliberately:
it can land on macOS's system `ruby` (2.6), which fails as a *parse* error, so
the plugin would silently do nothing. If the option is unset or not executable
you get a message in the status line instead.

Verify the interpreter you point at is new enough:

```sh
$ /usr/local/opt/ruby/bin/ruby -v
ruby 3.4.4 ...
```

Ruby is launched with `--disable-gems`, which removes ~70% of interpreter
startup (98ms → 29ms measured). Consequently the script has, and must keep,
**zero `require`s and zero gem dependencies** — `require 'tempfile'` alone cost
17ms, as much as the entire interpreter boot. See the performance contract at
the top of `scripts/tmux-jump.rb` before changing anything in it.

## Installation via [TPM](https://github.com/tmux-plugins/tpm)

Add plugin to the list of TPM plugins in `~/.tmux.conf`:

```
set -g @plugin 'schasse/tmux-jump'
```
Hit <kbd>tmux-prefix</kbd> + <kbd>I</kbd> to fetch the plugin and source it. You should now be able to use the plugin.

## Manual Installation

Clone the repository:

```
git clone https://github.com/schasse/tmux-jump ~/.tmux-jump
```

Add the following to `.tmux.conf`:

```
run-shell ~/.tmux-jump/tmux-jump.tmux
```

Reload tmux:

```
tmux source-file ~/.tmux.conf
```

## Usage

* <kbd>tmux-prefix</kbd> + <kbd>j</kbd> and enter the first character of a word.
* The screen will rerender and highlight the keys to press to jump to the word.
* Type the key sequence of the word to jump to.
* The cursor moves to the word.

tmux-jump can also be used in in any program and during copy mode.

### Cancelling a jump

A jump can be aborted at any prompt. One press is always enough — the pane is
left exactly as it was, and no further prompt appears.

| Key | Effect |
| --- | --- |
| <kbd>Esc</kbd> | Cancels |
| <kbd>Enter</kbd> | Cancels |
| <kbd>Tab</kbd> | Cancels |
| <kbd>Backspace</kbd> | Cancels |
| <kbd>Ctrl</kbd> + any key | Cancels — includes <kbd>Ctrl</kbd>+<kbd>C</kbd>, <kbd>Ctrl</kbd>+<kbd>G</kbd>, <kbd>Ctrl</kbd>+<kbd>D</kbd> |
| Arrow / function / <kbd>Home</kbd> / <kbd>End</kbd> / <kbd>PgUp</kbd> / <kbd>PgDn</kbd> | **Ignored** — the prompt stays open, waiting |
| Any key that is not a marker key | Cancels, at the marker prompt only |
| *(no key at all)* | Cancels after 10 seconds |

The rule is that every control character cancels: bytes `0x01`–`0x1f` plus
`0x7f`. Everything printable — `0x20`–`0x7e`, plus any UTF-8 character — is a
jump target, so punctuation and <kbd>Space</kbd> are searchable and do not abort.

Two notes on why the table looks the way it does:

* <kbd>Esc</kbd> is not special-cased by tmux here. `command-prompt -1` appends
  the pressed key verbatim (it handles `PROMPT_SINGLE` before the `status-keys`
  translation), so <kbd>Esc</kbd> arrives as an ordinary `0x1b` character and
  tmux-jump is what interprets it as "abort". This also means `status-keys vi`
  has no effect on cancelling.
* Special keys above `0x7f` that are not characters — arrows and friends — are
  dropped by tmux before tmux-jump ever sees them, which is why they neither
  jump nor cancel.

In double-key mode both prompts cancel independently: aborting at `char1:` never
opens `char2:`, and aborting at `char2:` ends the jump immediately.

You can customize the key binding in your `.tmux.conf`:

```
set -g @jump-key 's'
```

You can also customize foreground and background color:
```
set -g @jump-bg-color '\e[0m\e[90m'
set -g @jump-fg-color '\e[1m\e[31m'
```

The Ruby executable that runs the plugin. This one is **required**, not
optional — see [Requirements](#requirements):
```
set -g @jump-ruby-path '/usr/local/opt/ruby/bin/ruby'
```

And the keys position:
```
# keys will overlap with the word (default)
set -g @jump-keys-position 'left'

# keys will be at the left of the word without overlap
set -g @jump-keys-position 'off_left'
```

You can also configure the jump mode. For single and double-key jumps, you can set the mode to 'word' or 'char'.
```
# For single-key jumps (default: 'word')
set -g @jump-mode-single 'char'

# For double-key jumps (default: 'char')
set -g @jump-mode-double 'word'
```

## Similar Projects

* [vimium](https://vimium.github.io/)
* [easymotion](https://github.com/easymotion/vim-easymotion)
* [ace-jump-mode](https://github.com/winterTTr/ace-jump-mode)

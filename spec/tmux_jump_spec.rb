require 'pty'

ENV['JUMP_BACKGROUND_COLOR'] = "\e[0m\e[32m"
ENV['JUMP_FOREGROUND_COLOR'] = "\e[1m\e[31m"

require_relative '../scripts/tmux-jump'

Config.pane_nr = '%68'
# Colour / mode options normally arrive from tmux. Apply the same defaults
# here so the draw path has a real Config.red without a live server.
apply_option_defaults!

RSpec.describe 'tmux-jump' do
  before do
    @read, @write = PTY.open
    Config.pane_tty_file = @write.path
    # The draw path writes straight to this pty and nothing consumes it. macOS
    # blocks the writer once ~1024 bytes are buffered, and a full-screen draw is
    # far more than that (measured 2644 bytes for many_es_screen with 82
    # markers), so without a reader the suite deadlocks rather than failing.
    @drain = Thread.new do
      loop do
        begin
          @read.readpartial(4096)
        rescue StandardError, EOFError
          break
        end
      end
    end
    expect(Kernel).to_not receive :exit
  end

  after do
    @drain.kill
    @write.close
    @read.close
  end

  let(:simple_screen) do
    tmp_screen = <<~EOS
      ~$ echo 'hello world! easymotion for tmux :)'
      hello world! easymotion for tmux :)
      ~$
    EOS
    tmp_screen[0..-2] # no newline ending
  end

  let(:many_es_screen) do
    tmp_screen = <<~EOS
      ~$ echo 'eello eorld! easymotion eor emux :)'
      eello eorld! easymotion eor tmux :)
      ~$ echo 'eello eorld! easymotion eor emux :)'
      eello eorld! easymotion eor tmux :)
      ~$ echo 'eello eorld! easymotion eor emux :)'
      eello eorld! easymotion eor tmux :)
      ~$ echo 'eello eorld! easymotion eor emux :)'
      eello eorld! easymotion eor tmux :)
      ~$ echo 'eello eorld! easymotion eor emux :)'
      eello eorld! easymotion eor tmux :)
      ~$ echo 'eello eorld! easymotion eor emux :)'
      eello eorld! easymotion eor tmux :)
      ~$ echo 'eello eorld! easymotion eor emux :)'
      eello eorld! easymotion eor tmux :)
      ~$ echo 'eello eorld! easymotion eor emux :)'
      eello eorld! easymotion eor tmux :)
      ~$ echo 'eello eorld! easymotion eor emux :)'
      eello eorld! easymotion eor tmux :)
      ~$
    EOS
    tmp_screen[0..-2] # no newline ending
  end

  describe '#positions_of' do
    context 'in char mode' do
      it 'matches every occurrence' do
        expect(positions_of('h', simple_screen, 'char')).to eq [5, 9, 46]
        expect(positions_of('e', simple_screen, 'char')).to eq [3, 10, 22, 47, 59]
        expect(positions_of('s', simple_screen, 'char')).to eq [24, 61]
      end
    end

    context 'in word mode' do
      # Word mode keeps only word-initial matches: 'h' at 5 (inside "echo") and
      # 'e' at 10/47 (inside "hello") drop out, while 'e' at 3 ("echo") and
      # 22/59 ("easymotion") stay.
      it 'only matches at word boundaries' do
        expect(positions_of('h', simple_screen, 'word')).to eq [9, 46]
        expect(positions_of('e', simple_screen, 'word')).to eq [3, 22, 59]
        expect(positions_of('s', simple_screen, 'word')).to eq []
      end
    end
  end

  # The cursor-positioning logic. This has been written, reverted (e2e932c) and
  # rewritten, so the tmux cell model it depends on is pinned here explicitly:
  # one cursor-right crosses one *cell*, and a cell is a grapheme cluster, not a
  # code point and not a column.
  describe '#row_and_offset_of' do
    let(:screen) { "line one\nline two\nline three" }

    it 'returns the origin for index 0' do
      expect(row_and_offset_of(0, screen)).to eq [0, 0]
    end

    it 'returns column 0 for an index right after a newline' do
      expect(row_and_offset_of(5, "AAAA\nBB")).to eq [1, 0]
    end

    it 'counts every row' do
      expect(row_and_offset_of(screen.index('two'), screen)).to eq [1, 5]
      expect(row_and_offset_of(screen.index('three'), screen)).to eq [2, 5]
    end

    it 'clamps past the end without raising' do
      expect { row_and_offset_of(9999, screen) }.to_not raise_error
      expect(row_and_offset_of(9999, screen)).to eq [2, 'line three'.length]
    end

    it 'counts a wide character as one cell, not two columns' do
      screen = 'AB中文CD'
      expect(row_and_offset_of(screen.index('C'), screen)).to eq [0, 4]
    end

    it 'counts a base character and its combining mark as one cell' do
      screen = "BéXYZ" # "BeXYZ" with a combining acute on the e
      expect(screen.length).to eq 6 # six code points ...
      expect(row_and_offset_of(screen.index('Y'), screen)).to eq [0, 3] # ... four cells
    end

    it 'counts combining marks per row' do
      screen = "B\nxéXYZ"
      expect(row_and_offset_of(screen.index('Y'), screen)).to eq [1, 3]
    end
  end

  describe '#char_width' do
    it 'reports zero width for marks tmux packs into the preceding cell' do
      expect(char_width("\u0301")).to eq 0  # combining acute
      expect(char_width("\uFE0F")).to eq 0  # variation selector-16
      expect(char_width("\u200D")).to eq 0  # zero width joiner
    end

    it 'reports two columns for East Asian wide characters' do
      expect(char_width('中')).to eq 2
    end

    it 'reports one column for printable ascii' do
      expect(char_width('a')).to eq 1
      expect(char_width(' ')).to eq 1
    end

    it 'reports zero width for control characters' do
      expect(char_width("\e")).to eq 0
      expect(char_width("\u007F")).to eq 0 # DEL
    end
  end

  describe 'keys_for' do
    [
      [1, KEYS.size, 1],
      [(KEYS.size - 1), KEYS.size, 1],
      [KEYS.size, KEYS.size, 1],
      [(KEYS.size + 1), KEYS.size**2, 2],
      [(KEYS.size**2 - 1), KEYS.size**2, 2],
      [KEYS.size**2, KEYS.size**2, 2],
      [(KEYS.size**2 + 1), KEYS.size**3, 3],
      [(KEYS.size**3 - 1), KEYS.size**3, 3],
      [KEYS.size**3, KEYS.size**3, 3],
      [(KEYS.size**3 + 1), KEYS.size**4, 4]
    ].each do |position_count, key_size, key_len|
      it "returns the correct keys for #{position_count}" do
        calculated_keys = keys_for position_count
        expect(calculated_keys.size).to eq key_size
        expect(calculated_keys.first.size).to eq key_len
      end
    end
  end

  describe '#prompt_position_index!' do
    context 'when prompt char returns a char thats not on the screen' do
      before do
        allow_any_instance_of(Object).to receive(:prompt_char!).and_return 'b'
      end

      it 'returns nil' do
        expect(prompt_position_index!([3, 22, 59], simple_screen)).to eq nil
      end
    end

    context 'when prompt char does not return any char' do
      before do
        allow_any_instance_of(Object).to receive(:prompt_char!).and_return nil
      end

      it 'just returns nil' do
        expect(prompt_position_index!([3, 22, 59], simple_screen)).to eq nil
      end
    end

    it "returns the index if it's just 1 possibility" do
      expect(prompt_position_index!([100], simple_screen)).to eq 0
    end

    context 'with many times the same char (many possible positions)' do
      before do
        allow_any_instance_of(Object).to receive(:prompt_char!).and_return 'j'
      end

      it 'returns the ccorrect position' do
        positions = (0..81).to_a
        expect(prompt_position_index!(positions, many_es_screen)).to eq 0
      end
    end
  end

  # The capture range is tmux format arithmetic so that geometry, options and the
  # screen arrive in ONE round-trip. tmux treats a malformed -S/-E as 0 -- no
  # error, no non-zero exit -- so a typo in CAPTURE_START/CAPTURE_END silently
  # captures the live bottom of the pane instead of the scrolled view, and every
  # jump lands on the wrong screen. That is the failure mode reverted once
  # already (e2e932c), so it is pinned against a literal -S/-E pair here.
  describe 'capture range' do
    def tmux_out(*args)
      IO.popen(['tmux', *args], &:read)
    end

    def capture(*range)
      tmux_out('capture-pane', '-p', '-t', @session, *range)
    end

    def geometry
      tmux_out('display-message', '-p', '-t', @session,
               '-F', '#{scroll_position},#{pane_height}').strip.split(',')
    end

    around do |example|
      @session = "tmux-jump-spec-#{Process.pid}"
      system('tmux', 'kill-session', '-t', @session, out: File::NULL, err: File::NULL)
      system('tmux', 'new-session', '-d', '-s', @session, '-x', '40', '-y', '10',
             "PS1='$ ' bash --norc --noprofile")
      sleep 0.4
      tmux_out('send-keys', '-t', @session,
               'clear; for i in $(seq 1 80); do echo "line-$i"; done', 'Enter')
      sleep 1.2
      example.run
    ensure
      system('tmux', 'kill-session', '-t', @session, out: File::NULL, err: File::NULL)
    end

    it 'matches a literal -S/-E pair when the pane is scrolled' do
      tmux_out('copy-mode', '-t', @session)
      tmux_out('send-keys', '-X', '-t', @session, '-N', '6', 'scroll-up')
      scroll, height = geometry.map(&:to_i)
      expect(scroll).to eq 6

      expanded = capture('-S', CAPTURE_START, '-E', CAPTURE_END)
      expect(expanded).to eq capture('-S', (-scroll).to_s, '-E', (height - 1 - scroll).to_s)
      # ... and must NOT equal the unscrolled view, or the above is vacuous.
      expect(expanded).to_not eq capture('-S', '0', '-E', (height - 1).to_s)
    end

    it 'captures the visible screen when the pane is not in copy mode' do
      _scroll, height = geometry
      expect(_scroll).to eq '' # empty, not 0, outside copy mode
      expanded = capture('-S', CAPTURE_START, '-E', CAPTURE_END)
      expect(expanded).to eq capture('-S', '0', '-E', (height.to_i - 1).to_s)
    end

    it 'never degrades to the whole history' do
      # A bare "-#{scroll_position}" becomes "-S -" when the option is empty,
      # which captures every line of history. The multiply form must not.
      expanded = capture('-S', CAPTURE_START, '-E', CAPTURE_END)
      expect(expanded.lines.size).to be < capture('-S', '-', '-E', '-').lines.size
    end
  end

  # Per-jump wall-clock budget. Deliberately loose -- these guard against a 10x
  # algorithmic regression (a reintroduced per-character screen scan), not noise.
  describe 'performance budget' do
    let(:big_screen) { (1..60).map { |i| "row-#{i}-#{'abcdefghij' * 19}" }.join("\n") }

    def elapsed_ms
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
    end

    it 'computes row/offset in well under a millisecond' do
      index = big_screen.length - 40
      ms = elapsed_ms { 100.times { row_and_offset_of(index, big_screen) } } / 100
      expect(ms).to be < 0.5
    end

    it 'builds a full screen of markers in about a millisecond' do
      positions = []
      i = -1
      positions << i while (i = big_screen.index('a', i + 1))
      keys = keys_for positions.size
      Config.keys_position = 'left'
      ms = elapsed_ms { 10.times { marker_sequences(big_screen, positions, keys, keys.first.size) } } / 10
      expect(positions.size).to be > 400
      expect(ms).to be < 5.0
    end

    it 'does not iterate the screen per character' do
      # Teeth: with markers held constant, 4x the screen must not cost ~4x.
      large = ([big_screen] * 4).join("\n")
      positions = [10, 500, 2000]
      keys = keys_for positions.size
      kl = keys.first.size
      t_small = elapsed_ms { 50.times { marker_sequences(big_screen, positions, keys, kl) } }
      t_large = elapsed_ms { 50.times { marker_sequences(large, positions, keys, kl) } }
      expect(t_large).to be < (t_small * 3)
    end
  end

  # The prompt handoff is a FIFO plus IO.select: no polling interval on the
  # keypress path, and the wake is immediate. These drive the FIFO exactly the
  # way tmux does -- `printf %s c > fifo`, one open/close per character.
  describe 'prompt handoff over a FIFO' do
    def fresh_fifo(name)
      path = File.join(ENV['TMPDIR'] || '/tmp', "tmux-jump-spec-#{name}-#{Process.pid}")
      File.delete(path) if File.exist?(path)
      File.mkfifo path
      path
    end

    around do |example|
      @path = fresh_fifo example.description.gsub(/\W+/, '-')
      @io = open_prompt_fifo @path
      example.run
    ensure
      @io.close if @io
      File.delete(@path) if @path && File.exist?(@path)
    end

    def write_later(text, delay = 0.03)
      Thread.new do
        sleep delay
        system("printf %s '#{text}' > #{@path}")
      end
    end

    it 'returns the character a writer sends' do
      t = write_later 'e'
      expect(read_chars_from_fifo(@io, 1, 5)).to eq 'e'
      t.join
    end

    it 'assembles two characters from two separate writers' do
      t = Thread.new do
        sleep 0.03
        system("printf %s a > #{@path}")
        sleep 0.03
        system("printf %s b > #{@path}")
      end
      expect(read_chars_from_fifo(@io, 2, 5)).to eq 'ab'
      t.join
    end

    it 'waits for a complete multi-byte character' do
      t = write_later '中'
      expect(read_chars_from_fifo(@io, 1, 5)).to eq '中'
      t.join
    end

    # `command-prompt -1` appends the key verbatim (status.c handles
    # PROMPT_SINGLE before the status-keys translation), so control keys arrive
    # as data rather than cancelling the prompt. None of them can be a jump
    # target, and letting one through leaves an orphan char2: prompt in double
    # mode -- the same class of bug as the chained second prompt.
    {
      'C-c' => "\x03", 'C-g' => "\x07", 'C-d' => "\x04",
      'Enter' => "\r", 'Tab' => "\t", 'Backspace' => "\x7f"
    }.each do |name, byte|
      it "treats #{name} as a cancellation" do
        t = Thread.new do
          sleep 0.03
          File.open(@path, 'wb') { |f| f.write byte }
        end
        expect(read_chars_from_fifo(@io, 1, 5)).to eq nil
        t.join
      end
    end

    it 'still accepts ordinary jump targets' do
      [' ', '/', '~', '7'].each do |ch|
        path = "#{@path}-#{ch.ord}"
        File.mkfifo path
        io = open_prompt_fifo path
        t = Thread.new { sleep 0.02; File.open(path, 'wb') { |f| f.write ch } }
        expect(read_chars_from_fifo(io, 1, 5)).to eq ch
        t.join
        io.close
        File.delete path
      end
    end

    it 'treats a leading Esc as a cancellation' do
      t = Thread.new { sleep 0.03; system("printf '\\033' > #{@path}") }
      expect(read_chars_from_fifo(@io, 1, 5)).to eq nil
      t.join
    end

    it 'times out to nil rather than hanging when nothing is written' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(read_chars_from_fifo(@io, 1, 0.3)).to eq nil
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(elapsed).to be_within(0.2).of(0.3)
    end

    # The launcher opens exactly one prompt and reports on a separate channel when
    # it resolves. Each prompt is read by exactly one call, so an empty buffer when
    # that signal arrives means the prompt was cancelled.
    context 'with a cancel channel' do
      around do |example|
        @cancel_path = "#{@path}.cancel"
        File.delete(@cancel_path) if File.exist?(@cancel_path)
        File.mkfifo @cancel_path
        @cancel_io = open_prompt_fifo @cancel_path
        example.run
      ensure
        @cancel_io.close if @cancel_io
        File.delete(@cancel_path) if @cancel_path && File.exist?(@cancel_path)
      end

      def signal(delay = 0.05)
        Thread.new do
          sleep delay
          File.open(@cancel_path, 'w') { |f| f.write 'x' }
        end
      end

      def timed
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
      end

      it 'cancels promptly when the prompt resolved with nothing written' do
        t = signal
        got, elapsed = timed { read_chars_from_fifo(@io, 1, 10, @cancel_io) }
        expect(got).to eq nil
        expect(elapsed).to be < 1.0 # not the full 10s timeout
        t.join
      end

      it 'still returns a character written before the signal' do
        t = Thread.new do
          sleep 0.03
          system("printf %s e > #{@path}")
          File.open(@cancel_path, 'w') { |f| f.write 'x' }
        end
        expect(read_chars_from_fifo(@io, 1, 10, @cancel_io)).to eq 'e'
        t.join
      end

      # The callback write and the prompt returning race, so a character landing
      # just after the signal must still win.
      it 'honours a character that arrives during the grace window' do
        t = Thread.new do
          File.open(@cancel_path, 'w') { |f| f.write 'x' }
          sleep 0.01
          system("printf %s q > #{@path}")
        end
        expect(read_chars_from_fifo(@io, 1, 10, @cancel_io)).to eq 'q'
        t.join
      end
    end

    it 'survives a writer that opens and closes without writing' do
      t = Thread.new do
        sleep 0.05
        system(": > #{@path}")
        sleep 0.05
        system("printf %s z > #{@path}")
      end
      cpu_before = Process.times.utime
      expect(read_chars_from_fifo(@io, 1, 5)).to eq 'z'
      expect(Process.times.utime - cpu_before).to be < 0.02 # i.e. not spinning
      t.join
    end
  end
end

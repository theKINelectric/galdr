#+build darwin, linux, freebsd, openbsd, netbsd
package galdr

import "base:runtime"
import "core:c"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

Options :: struct {
	inline:      bool,   // draw below the prompt instead of taking over the screen
	height:      int,    // inline rows (0 = 10)
	keep:        bool,   // inline: leave the final frame on screen at exit
	no_mouse:    bool,   // fullscreen: don't capture the mouse
	no_kitty:    bool,   // don't request the kitty keyboard protocol
	theme:       Theme,  // zero value = nightfall
	title:       string, // window title (OSC 2)
	no_suspend:  bool,   // don't treat ctrl+z as "suspend to shell"
	no_probe:    bool,   // skip querying the terminal's capabilities
}

@(private) _live_term: ^Terminal
@(private) _live_teardown: string
@(private) _winch_fd: posix.FD = -1
@(private) _live_suspend: string // bytes that hand the screen back before stopping
@(private) _resumed: i32         // set by the SIGTSTP handler once we are continued

@(private)
_on_assert :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	if _live_term != nil {
		term_write(_live_term, _live_teardown)
		term_restore(_live_term)
		_live_term = nil
	}
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

@(private)
_on_fatal_signal :: proc "c" (sig: posix.Signal) {
	if _live_term != nil {
		posix.write(_live_term.fd, raw_data(_live_teardown), c.size_t(len(_live_teardown)))
		posix.tcsetattr(_live_term.fd, .TCSAFLUSH, &_live_term.saved)
	}
	posix._exit(128 + c.int(sig))
}

// SIGTSTP (ctrl+z via raise, or kill -TSTP): give the terminal back, stop for
// real, and when continued flag the loop to take the screen again.
@(private)
_on_tstp :: proc "c" (sig: posix.Signal) {
	if _live_term != nil {
		posix.write(_live_term.fd, raw_data(_live_suspend), c.size_t(len(_live_suspend)))
		posix.tcsetattr(_live_term.fd, .TCSAFLUSH, &_live_term.saved)
	}
	dfl: posix.sigaction_t
	dfl.sa_handler = auto_cast posix.SIG_DFL
	posix.sigaction(.SIGTSTP, &dfl, nil)
	// SIGTSTP is blocked while its handler runs; unblock it or raise() would
	// only queue it and we would re-enter this handler forever.
	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGTSTP)
	posix.sigprocmask(.UNBLOCK, &set, nil)
	posix.raise(.SIGTSTP) // stops here until SIGCONT
	again: posix.sigaction_t
	again.sa_handler = _on_tstp
	posix.sigaction(.SIGTSTP, &again, nil)
	sync.atomic_store(&_resumed, 1)
	if _winch_fd >= 0 {
		b := [1]u8{3}
		posix.write(_winch_fd, &b[0], 1)
	}
}

@(private)
_on_winch :: proc "c" (sig: posix.Signal) {
	if _winch_fd >= 0 {
		b := [1]u8{2}
		posix.write(_winch_fd, &b[0], 1)
	}
}

@(private)
_install_handler :: proc(sig: posix.Signal, handler: proc "c" (posix.Signal)) -> (old: posix.sigaction_t, ok: bool) {
	act: posix.sigaction_t
	act.sa_handler = handler
	posix.sigemptyset(&act.sa_mask)
	err := posix.sigaction(sig, &act, &old)
	return old, err == .OK
}

// The signals a session installs (index 4, SIGTSTP, only unless no_suspend).
@(private)
_SESSION_SIGS :: [5]posix.Signal{.SIGTERM, .SIGHUP, .SIGQUIT, posix.Signal(posix.SIGWINCH), .SIGTSTP}

@(private)
_wake_pipe :: proc(data: rawptr) {
	pipe_poke(posix.FD(uintptr(data)))
}

Run_Error :: enum u8 {
	None,
	No_Terminal,    // no controlling terminal (/dev/tty): CI, cron, detached
	Dumb_Terminal,  // TERM=dumb or unset: no cursor addressing
	Raw_Mode_Failed,
}

// ------------------------------------------------------------ session

// Session is everything about owning the terminal that doesn't depend on the
// app's types: modes, signal handlers, the wake pipe, the clock, presenting
// frames and reading input. One Session at a time: signal dispositions and
// crash-safety state are process-wide. Externally delivered SIGINT is not
// covered by the session's fatal-signal handlers (apps take ctrl+c as a key).
Session :: struct {
	term:           Terminal,
	opts:           Options,
	wake_r, wake_w: posix.FD,
	setup:          strings.Builder,
	teardown:       strings.Builder,
	suspend:        strings.Builder,
	out:            strings.Builder,
	start:          time.Tick,
	reader:         Input_Reader,
	chunk:          [16384]u8,
	full:           bool, // next present must redraw everything
	trace:          bool, // GALDR_TRACE: log every loop iteration
	log_file:       ^os.File,
	logger:         log.Logger,
	sig_saved:      [len(_SESSION_SIGS)]posix.sigaction_t, // host dispositions, restored on close
	sig_on:         [len(_SESSION_SIGS)]bool,
}

// Diagnostics never touch the terminal (that would corrupt the UI):
//   GALDR_LOG=path   send core:log output (yours and Galdr's) to a file
//   GALDR_TRACE=1    also log every event-loop iteration and probe results
@(private)
_session_logging :: proc(s: ^Session) {
	path := os.get_env("GALDR_LOG", context.temp_allocator)
	trace := os.get_env("GALDR_TRACE", context.temp_allocator)
	s.trace = trace != "" && trace != "0"
	if path == "" do return
	f, err := os.open(path, {.Write, .Create, .Append}, os.Permissions_Read_All + {.Write_User})
	if err != nil do return
	s.log_file = f
	s.logger = log.create_file_logger(f, s.trace ? .Debug : .Info)
}

session_open :: proc(s: ^Session, opts: Options) -> Run_Error {
	if is_dumb_terminal() do return .Dumb_Terminal
	term, ok := term_open()
	if !ok do return .No_Terminal
	if !term_enter_raw(&term) {
		posix.close(term.fd)
		return .Raw_Mode_Failed
	}
	s.term = term
	s.opts = opts
	// The wake pipe first: nothing after this point allocates logging state
	// that a failure return would have to unwind.
	wake_r, wake_w, pipe_ok := make_pipe()
	if !pipe_ok {
		// No wake pipe, no session: restore what was taken and fail closed
		// rather than keeping -1 descriptors wait_readable would feed to FD_SET.
		term_restore(&s.term)
		posix.close(term.fd)
		return .Raw_Mode_Failed
	}
	s.wake_r, s.wake_w = wake_r, wake_w
	_session_logging(s)
	s.start = time.tick_now()
	s.full = true
	reader_init(&s.reader)
	if !opts.no_probe do _session_probe(s)
	s.setup = strings.builder_make()
	s.teardown = strings.builder_make()
	s.suspend = strings.builder_make()
	s.out = strings.builder_make()

	if !opts.inline {
		strings.write_string(&s.setup, "\x1b[?1049h\x1b[H")
		if !opts.no_mouse do strings.write_string(&s.setup, "\x1b[?1000h\x1b[?1002h\x1b[?1006h")
	}
	strings.write_string(&s.setup, "\x1b[?25l\x1b[?2004h\x1b[?1004h")
	kitty := !opts.no_kitty && terminal.kitty_keyboard
	if kitty do strings.write_string(&s.setup, "\x1b[>1u")
	cluster_mode := terminal.graphemes == .Reset // supported but off: turn it on
	if cluster_mode do strings.write_string(&s.setup, "\x1b[?2027h")
	if opts.title != "" {
		strings.write_string(&s.setup, "\x1b]2;")
		strings.write_string(&s.setup, sanitize(opts.title))
		strings.write_string(&s.setup, "\x07")
	}
	if kitty do strings.write_string(&s.teardown, "\x1b[<u")
	if cluster_mode do strings.write_string(&s.teardown, "\x1b[?2027l")
	strings.write_string(&s.teardown, "\x1b[?1004l\x1b[?2004l\x1b[0m\x1b[?25h")
	if !opts.inline {
		if !opts.no_mouse do strings.write_string(&s.teardown, "\x1b[?1006l\x1b[?1002l\x1b[?1000l")
		strings.write_string(&s.teardown, "\x1b[?1049l")
	}
	if opts.inline do strings.write_string(&s.suspend, "\r\x1b[0m\x1b[J")
	strings.write_string(&s.suspend, strings.to_string(s.teardown))
	term_write(&s.term, strings.to_string(s.setup))

	// Crash safety: restore the terminal on assertion failure or fatal signal.
	_live_term = &s.term
	_live_teardown = strings.to_string(s.teardown)
	_live_suspend = strings.to_string(s.suspend)
	_winch_fd = s.wake_w
	// Save the host's dispositions so session_close can put them back.
	handlers := [len(_SESSION_SIGS)]proc "c" (posix.Signal){
		_on_fatal_signal, _on_fatal_signal, _on_fatal_signal, _on_winch, _on_tstp,
	}
	for sig, i in _SESSION_SIGS {
		if i == 4 && opts.no_suspend do continue
		s.sig_saved[i], s.sig_on[i] = _install_handler(sig, handlers[i])
	}
	return .None
}

// session_close hands the terminal back. With opts.keep (inline), `last` is
// left on screen; otherwise the inline region is erased.
session_close :: proc(s: ^Session, last: ^Frame) {
	if s.opts.inline {
		if s.opts.keep && last != nil {
			strings.builder_reset(&s.out)
			render_inline(&s.out, last, s.term.caps)
			strings.write_string(&s.out, "\x1b[0m")
			if last.h > 1 {
				strings.write_string(&s.out, "\x1b[")
				strings.write_int(&s.out, last.h - 1)
				strings.write_string(&s.out, "B")
			}
			strings.write_string(&s.out, "\r\n")
			term_write(&s.term, strings.to_string(s.out))
		} else {
			term_write(&s.term, "\r\x1b[0m\x1b[J")
		}
	}
	term_write(&s.term, strings.to_string(s.teardown))
	// Put the host's signal dispositions back exactly as they were — a custom
	// handler, SIG_IGN, or the default — so embedding Galdr doesn't leave our
	// fatal-signal handler (which _exits) installed after the UI closes.
	for sig, i in _SESSION_SIGS {
		if s.sig_on[i] do posix.sigaction(sig, &s.sig_saved[i], nil)
	}
	_live_term = nil
	_winch_fd = -1
	width_mode = .Legacy
	term_restore(&s.term)
	posix.close(s.term.fd)
	posix.close(s.wake_r)
	posix.close(s.wake_w)
	reader_destroy(&s.reader)
	if s.log_file != nil {
		log.destroy_file_logger(s.logger)
		s.log_file = nil
	}
	strings.builder_destroy(&s.setup)
	strings.builder_destroy(&s.teardown)
	strings.builder_destroy(&s.suspend)
	strings.builder_destroy(&s.out)
}

// _probe_io sends the probe burst on an already-raw terminal and collects
// replies until DA1 arrives or the timeout passes. Bytes that aren't replies
// (keys typed meanwhile) are appended to typed.
@(private)
_probe_io :: proc(t: ^Terminal, typed: ^[dynamic]u8) -> Terminal_Info {
	term_write(t, PROBE_QUERY)
	info: Terminal_Info
	chunk: [4096]u8
	pending := make([dynamic]u8, context.temp_allocator)
	start := time.tick_now()
	for !info.answered {
		left := PROBE_TIMEOUT_MS - int(time.duration_milliseconds(time.tick_since(start)))
		if left <= 0 do break
		if !wait_readable({t.fd}, left)[0] do continue
		n := term_read(t, chunk[:])
		if n <= 0 do continue
		append(&pending, ..chunk[:n])
		rest := probe_scan(pending[:], &info, typed)
		remaining := make([dynamic]u8, context.temp_allocator)
		append(&remaining, ..rest)
		pending = remaining
	}
	append(typed, ..pending[:]) // a half-received reply: the decoder skips it
	return info
}

// _apply_info makes the rest of Galdr follow what the terminal reported.
@(private)
_apply_info :: proc(info: Terminal_Info, caps: ^Caps) {
	terminal = info
	width_mode = mode_supported(info.graphemes) ? .Grapheme : .Legacy
	if info.sync_output == .Unrecognized || info.sync_output == .Always_Reset do caps.no_sync = true
	if caps.depth == .Palette_256 {
		name := strings.to_lower(info.name, context.temp_allocator)
		for known in ([]string{"kitty", "wezterm", "ghostty", "iterm", "foot", "contour", "alacritty", "rio", "konsole", "xterm.js"}) {
			if strings.contains(name, known) do caps.depth = .True_Color
		}
	}
}

// _session_probe queries the terminal (see probe.odin) and applies what it
// learns: color depth, synchronized output, grapheme widths, kitty keyboard.
@(private)
_session_probe :: proc(s: ^Session) {
	typed := make([dynamic]u8, context.temp_allocator)
	info := _probe_io(&s.term, &typed)
	if len(typed) > 0 do reader_feed(&s.reader, typed[:], 0)
	_apply_info(info, &s.term.caps)
	if s.log_file != nil {
		context.logger = s.logger
		log.infof("terminal: name=%q answered=%v kitty=%v sync=%v graphemes=%v background=%v depth=%v",
			info.name, info.answered, info.kitty_keyboard, info.sync_output, info.graphemes, info.background, s.term.caps.depth)
	}
}

// probe_terminal asks the controlling terminal what it supports, for
// programs that print instead of running an app (so text is measured the
// way this terminal will draw it). It sets width_mode and `terminal`, and
// returns caps to render with. ok is false without a usable terminal; then
// nothing changes and caps come from the environment.
probe_terminal :: proc() -> (info: Terminal_Info, caps: Caps, ok: bool) {
	caps = detect_caps()
	if is_dumb_terminal() do return {}, caps, false
	t, opened := term_open()
	if !opened do return {}, caps, false
	defer posix.close(t.fd)
	if !term_enter_raw(&t) do return {}, caps, false
	typed := make([dynamic]u8, context.temp_allocator)
	info = _probe_io(&t, &typed)
	term_restore(&t)
	_apply_info(info, &caps)
	return info, caps, info.answered
}

session_now :: proc(s: ^Session) -> i64 {
	return i64(time.duration_milliseconds(time.tick_diff(s.start, time.tick_now())))
}

// session_frame_size is the frame the app should paint for the current window.
session_frame_size :: proc(s: ^Session) -> (w, h: int) {
	tw, th, _ := term_size(&s.term)
	if !s.opts.inline do return tw, th
	want := s.opts.height > 0 ? s.opts.height : 10
	return tw, min(want, max(th - 1, 1))
}

// session_reserve makes room for an inline region below the prompt
// (scrolling if needed) and returns the cursor to its top-left.
session_reserve :: proc(s: ^Session, h: int) {
	if !s.opts.inline || h <= 1 do return
	res := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< h - 1 do strings.write_string(&res, "\r\n")
	strings.write_string(&res, "\x1b[")
	strings.write_int(&res, h - 1)
	strings.write_string(&res, "A\r")
	term_write(&s.term, strings.to_string(res))
}

// session_resumed re-takes the terminal after a ctrl+z; true if it did.
session_resumed :: proc(s: ^Session, h: int) -> bool {
	if sync.atomic_exchange(&_resumed, 0) != 1 do return false
	s.term.is_raw = false
	term_enter_raw(&s.term)
	term_write(&s.term, strings.to_string(s.setup))
	session_reserve(s, h)
	s.full = true
	return true
}

// session_present sends the difference between prev and next to the screen.
session_present :: proc(s: ^Session, prev, next: ^Frame) {
	strings.builder_reset(&s.out)
	if s.opts.inline {
		render_inline(&s.out, next, s.term.caps)
	} else {
		render_diff(&s.out, prev, next, s.full, s.term.caps)
	}
	term_write(&s.term, strings.to_string(s.out))
	s.full = false
}

// session_wait blocks until input, a wake-up, or timeout_ms (-1 = until
// something happens, capped at 1 s so resizes are noticed), then collects
// decoded inputs into out. Returns true if the wake pipe fired.
session_wait :: proc(s: ^Session, timeout_ms: int, out: ^[dynamic]Input) -> (woke: bool) {
	timeout := timeout_ms
	if rt := reader_timeout(&s.reader, session_now(s)); rt >= 0 {
		timeout = timeout < 0 ? rt : min(timeout, rt)
	}
	if timeout < 0 do timeout = 1000

	ready := wait_readable({s.term.fd, s.wake_r}, timeout)
	now := session_now(s)
	if s.trace do log.debugf("loop now=%d timeout=%d tty=%v wake=%v pending=%d", now, timeout, ready[0], ready[1], len(s.reader.buf))

	if ready[0] {
		// Read everything available right now (a big paste spans many reads).
		for {
			n := term_read(&s.term, s.chunk[:])
			if n <= 0 do break
			reader_feed(&s.reader, s.chunk[:n], now)
			if n < len(s.chunk) do break
		}
	}
	reader_drain(&s.reader, now, out)
	if ready[1] do pipe_drain(s.wake_r)
	return ready[1]
}

// ------------------------------------------------------------ run

// run takes over the terminal and drives app until it quits.
run :: proc(app: App($S, $M), state: ^S, opts: Options = {}) -> Run_Error {
	session: Session
	if err := session_open(&session, opts); err != .None do return err
	context.assertion_failure_proc = _on_assert
	// Not inside an `if`: context changes only last for the enclosing block.
	context.logger = session.log_file != nil ? session.logger : context.logger

	theme := opts.theme.name == "" ? auto_theme(terminal) : opts.theme
	e: Engine(S, M)
	engine_init(&e, app, state, theme)
	e.wake = _wake_pipe
	e.wake_data = rawptr(uintptr(session.wake_w))

	w, h := session_frame_size(&session)
	prev := frame_make(w, h, &e.theme)
	next := frame_make(w, h, &e.theme)
	session_reserve(&session, h)
	defer {
		engine_destroy(&e) // before the wake pipe closes
		session_close(&session, &prev)
		frame_destroy(&prev)
		frame_destroy(&next)
	}

	engine_boot(&e)
	engine_dispatch(&e, Resize{w, h})
	inputs := make([dynamic]Input, 0, 64)
	defer delete(inputs)

	for !e.quit {
		e.now_ms = session_now(&session)
		if session_resumed(&session, next.h) do e.dirty = true

		nw, nh := session_frame_size(&session)
		if nw != next.w || nh != next.h {
			frame_resize(&prev, nw, nh)
			frame_resize(&next, nw, nh)
			session.full = true
			engine_dispatch(&e, Resize{nw, nh})
		}
		if e.dirty {
			engine_paint(&e, &next)
			session_present(&session, &prev, &next)
			prev, next = next, prev
			e.dirty = false
		}
		free_all(context.temp_allocator)
		if e.quit do break

		clear(&inputs)
		session_wait(&session, engine_next_timeout(&e), &inputs)
		e.now_ms = session_now(&session)
		for ev in inputs {
			if e.quit do break
			switch v in ev {
			case Key:
				if !opts.no_suspend && is_ctrl(v, 'z') {
					posix.raise(.SIGTSTP)
					continue
				}
				engine_dispatch(&e, v)
			case Mouse: engine_dispatch(&e, v)
			case Paste: engine_dispatch(&e, v)
			case Focus: engine_dispatch(&e, v)
			}
		}
		engine_drain_inbox(&e)
		engine_fire_timers(&e)
	}
	if opts.keep do engine_paint(&e, &prev)
	return .None
}

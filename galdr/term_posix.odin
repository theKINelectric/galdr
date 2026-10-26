#+build darwin, linux, freebsd, openbsd, netbsd
package galdr

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"

// The terminal: raw mode, size, and byte I/O over /dev/tty. Using /dev/tty
// (not stdin/stdout) keeps stdout free for results, so `x=$(galdr pick ...)`
// works while the UI draws on the terminal.

Terminal :: struct {
	fd:     posix.FD,
	saved:  posix.termios,
	is_raw: bool,
	caps:   Caps,
}

foreign import libc "system:c"

@(private)
winsize :: struct {
	ws_row, ws_col, ws_xpixel, ws_ypixel: c.ushort,
}

when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
	@(private)
	TIOCGWINSZ :: 0x40087468
} else {
	@(private)
	TIOCGWINSZ :: 0x5413
}

@(private)
@(default_calling_convention = "c")
foreign libc {
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

term_open :: proc() -> (t: Terminal, ok: bool) {
	fd := posix.open("/dev/tty", {.RDWR, .NOCTTY})
	if fd < 0 do return {}, false
	t.fd = fd
	t.caps = detect_caps()
	return t, true
}

term_close :: proc(t: ^Terminal) {
	term_restore(t)
	posix.close(t.fd)
}

// detect_caps inspects the environment for color support.
detect_caps :: proc() -> Caps {
	// https://no-color.org: any non-empty NO_COLOR disables color.
	if os.get_env("NO_COLOR", context.temp_allocator) != "" do return {depth = .Mono}
	if os.get_env("TERM", context.temp_allocator) == "dumb" do return {depth = .Mono}
	if os.get_env("TERM", context.temp_allocator) == "linux" do return {depth = .Ansi_16}
	ct := os.get_env("COLORTERM", context.temp_allocator)
	if ct == "truecolor" || ct == "24bit" do return {depth = .True_Color}
	term := os.get_env("TERM", context.temp_allocator)
	prog := os.get_env("TERM_PROGRAM", context.temp_allocator)
	switch prog {
	case "iTerm.app", "WezTerm", "ghostty", "vscode", "Hyper", "Tabby", "rio":
		return {depth = .True_Color}
	}
	if strings.contains(term, "kitty") || strings.contains(term, "ghostty") ||
	   strings.contains(term, "alacritty") || strings.contains(term, "direct") {
		return {depth = .True_Color}
	}
	return {depth = .Palette_256}
}

term_enter_raw :: proc(t: ^Terminal) -> bool {
	if t.is_raw do return true
	if posix.tcgetattr(t.fd, &t.saved) != .OK do return false
	raw := t.saved
	raw.c_iflag -= {.IGNBRK, .BRKINT, .PARMRK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ECHONL, .ICANON, .ISIG, .IEXTEN}
	raw.c_cflag -= posix.CSIZE
	raw.c_cflag -= {.PARENB}
	raw.c_cflag += {.CS8}
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(t.fd, .TCSAFLUSH, &raw) != .OK do return false
	t.is_raw = true
	return true
}

term_restore :: proc(t: ^Terminal) {
	if !t.is_raw do return
	posix.tcsetattr(t.fd, .TCSAFLUSH, &t.saved)
	t.is_raw = false
}

term_size :: proc(t: ^Terminal) -> (w, h: int, ok: bool) {
	ws: winsize
	if ioctl(c.int(t.fd), c.ulong(TIOCGWINSZ), &ws) != 0 || ws.ws_col == 0 {
		return 80, 24, false
	}
	return int(ws.ws_col), int(ws.ws_row), true
}

term_write :: proc(t: ^Terminal, data: string) {
	bytes := transmute([]u8)data
	for len(bytes) > 0 {
		n := posix.write(t.fd, raw_data(bytes), c.size_t(len(bytes)))
		if n < 0 {
			if posix.errno() == .EINTR || posix.errno() == .EAGAIN do continue
			return
		}
		bytes = bytes[n:]
	}
}

// term_read reads whatever is available (non-blocking after poll).
term_read :: proc(t: ^Terminal, buf: []u8) -> int {
	n := posix.read(t.fd, raw_data(buf), c.size_t(len(buf)))
	return max(int(n), 0)
}

// wait_readable blocks until one of fds is readable or timeout_ms passes.
// Returns which fds are ready. macOS poll() rejects /dev/tty (POLLNVAL), so
// Darwin uses select(); other systems use poll().
@(private)
wait_readable :: proc(fds: []posix.FD, timeout_ms: int) -> (ready: [4]bool) {
	n := min(len(fds), 4)
	when ODIN_OS == .Darwin {
		set: posix.fd_set
		posix.FD_ZERO(&set)
		hi: posix.FD = 0
		for i in 0 ..< n {
			posix.FD_SET(fds[i], &set)
			hi = max(hi, fds[i])
		}
		tv := posix.timeval{
			tv_sec  = posix.time_t(timeout_ms / 1000),
			tv_usec = posix.suseconds_t((timeout_ms % 1000) * 1000),
		}
		r := posix.select(c.int(hi) + 1, &set, nil, nil, &tv)
		if r <= 0 do return
		for i in 0 ..< n do ready[i] = posix.FD_ISSET(fds[i], &set)
	} else {
		pfds: [4]posix.pollfd
		for i in 0 ..< n do pfds[i] = {fd = fds[i], events = {.IN}}
		r := posix.poll(&pfds[0], posix.nfds_t(n), c.int(timeout_ms))
		if r <= 0 do return
		for i in 0 ..< n do ready[i] = pfds[i].revents & {.IN, .HUP, .ERR} != {}
	}
	return
}

@(private)
make_pipe :: proc() -> (r, w: posix.FD, ok: bool) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK do return -1, -1, false
	for fd in fds {
		flags := posix.fcntl(fd, .GETFL)
		posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
	}
	return fds[0], fds[1], true
}

@(private)
pipe_poke :: proc(fd: posix.FD) {
	b := [1]u8{1}
	posix.write(fd, &b[0], 1)
}

@(private)
pipe_drain :: proc(fd: posix.FD) {
	buf: [64]u8
	for posix.read(fd, &buf[0], len(buf)) > 0 {}
}

// is_dumb_terminal reports TERM=dumb (or unset): no cursor addressing.
is_dumb_terminal :: proc() -> bool {
	term := os.get_env("TERM", context.temp_allocator)
	return term == "" || term == "dumb"
}

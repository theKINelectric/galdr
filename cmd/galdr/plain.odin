package galdr_cli

// Fallbacks for terminals that can't run a full-screen or inline UI.
//  - TERM=dumb (a terminal, but no cursor addressing): plain line prompts on /dev/tty.
//  - No terminal at all (CI, cron): use the explicit default if one was given.

import gd "galdr:galdr"
import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

Tty :: struct {
	fd: posix.FD,
}

tty_open :: proc() -> (Tty, bool) {
	fd := posix.open("/dev/tty", {.RDWR, .NOCTTY})
	return {fd}, fd >= 0
}

tty_close :: proc(t: Tty) {
	posix.close(t.fd)
}

tty_print :: proc(t: Tty, s: string) {
	posix.write(t.fd, raw_data(s), c.size_t(len(s)))
}

// plain_sanitize strips control characters from an untrusted fragment before
// it is written to the terminal. Plain prompts draw with raw writes — there
// is no Frame sanitizer on this path — so headers, items and questions must
// not be able to smuggle ESC, OSC, BEL or C1 sequences into the display. The
// value later printed to stdout keeps its original bytes (the data contract).
plain_sanitize :: proc(s: string) -> string {
	return gd.sanitize(s)
}

// tty_line reads one line in the terminal's normal (cooked) mode.
tty_line :: proc(t: Tty, echo := true) -> (line: string, ok: bool) {
	saved: posix.termios
	have_saved := posix.tcgetattr(t.fd, &saved) == .OK
	if !echo && have_saved {
		quiet := saved
		quiet.c_lflag -= {.ECHO}
		posix.tcsetattr(t.fd, .TCSANOW, &quiet)
	}
	defer if !echo && have_saved {
		posix.tcsetattr(t.fd, .TCSANOW, &saved)
		tty_print(t, "\n")
	}
	b := strings.builder_make(context.temp_allocator)
	buf: [1]u8
	for {
		n := posix.read(t.fd, &buf[0], 1)
		if n <= 0 do return strings.to_string(b), strings.builder_len(b) > 0
		if buf[0] == '\n' do return strings.to_string(b), true
		if buf[0] != '\r' do strings.write_byte(&b, buf[0])
	}
}

// try_plain runs a line-mode prompt when the UI can't start because the
// terminal is dumb. ran is false when there is no terminal at all.
try_plain :: proc(err: gd.Run_Error, prompt: proc(t: Tty, data: rawptr) -> int, data: rawptr) -> (code: int, ran: bool) {
	if err != .Dumb_Terminal do return 0, false
	t, ok := tty_open()
	if !ok do return 0, false
	defer tty_close(t)
	return prompt(t, data), true
}

// cannot_prompt explains why nothing could be asked, and how to fix it.
cannot_prompt :: proc(err: gd.Run_Error, flag: string) -> int {
	if err == .Raw_Mode_Failed {
		fmt.eprintln("galdr: could not put the terminal into raw mode")
	} else {
		fmt.eprintfln("galdr: no interactive terminal; pass %s to answer non-interactively", flag)
	}
	return 2
}

// ------------------------------------------------------------ plain prompts

plain_pick :: proc(t: Tty, data: rawptr) -> int {
	s := (^Pick_Prompt)(data)
	if s.header != "" do tty_print(t, fmt.tprintf("%s\n", plain_sanitize(s.header)))
	for item, i in s.items do tty_print(t, fmt.tprintf("  %d) %s\n", i + 1, plain_sanitize(item)))
	for {
		tty_print(t, s.multi ? "Numbers (space separated): " : fmt.tprintf("Pick [1-%d]: ", len(s.items)))
		line, ok := tty_line(t)
		if !ok {
			s.canceled = true
			return 130
		}
		clear_picks(s)
		valid := true
		count := 0
		for field in strings.fields(line, context.temp_allocator) {
			n, parsed := strconv.parse_int(field)
			if !parsed || n < 1 || n > len(s.items) {
				valid = false
				break
			}
			s.picked[n - 1] = true
			s.list.cursor = n - 1
			count += 1
		}
		if valid && count > 0 && (s.multi || count == 1) {
			s.done = true
			return 0
		}
		tty_print(t, "  (not a valid choice)\n")
	}
}

clear_picks :: proc(s: ^Pick_Prompt) {
	for &p in s.picked do p = false
}

plain_enter :: proc(t: Tty, data: rawptr) -> int {
	s := (^Enter_Prompt)(data)
	prompt := s.header != "" ? s.header : s.field.placeholder
	tty_print(t, fmt.tprintf("%s: ", plain_sanitize(prompt)))
	line, ok := tty_line(t, echo = s.field.mask == 0)
	if !ok && line == "" {
		s.canceled = true
		return 130
	}
	gd.field_set(&s.field, line)
	s.done = true
	return 0
}

plain_approve :: proc(t: Tty, data: rawptr) -> int {
	s := (^Approve_Prompt)(data)
	hint := s.choice ? "[Y/n]" : "[y/N]"
	question := plain_sanitize(s.question)
	for {
		tty_print(t, fmt.tprintf("%s %s ", question, hint))
		line, ok := tty_line(t)
		if !ok {
			s.canceled = true
			return 130
		}
		switch strings.to_lower(strings.trim_space(line), context.temp_allocator) {
		case "":         s.done = true; return 0
		case "y", "yes": s.choice, s.done = true, true; return 0
		case "n", "no":  s.choice, s.done = false, true; return 0
		}
	}
}

plain_draft :: proc(t: Tty, data: rawptr) -> int {
	s := (^Draft_Prompt)(data)
	tty_print(t, fmt.tprintf("%s (end with a line containing only \".\")\n", plain_sanitize(s.header != "" ? s.header : "Text")))
	b := strings.builder_make(context.temp_allocator)
	for {
		line, ok := tty_line(t)
		if !ok || line == "." do break
		if strings.builder_len(b) > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, line)
	}
	gd.area_set(&s.area, strings.to_string(b))
	s.done = true
	return 0
}

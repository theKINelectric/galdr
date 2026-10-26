package galdr

import "core:testing"

@(test)
test_probe_replies :: proc(t: ^testing.T) {
	info: Terminal_Info
	typed := make([dynamic]u8, context.temp_allocator)
	replies := "\x1b[?1u" + "\x1b[?2026;2$y" + "\x1b[?2027;0$y" + "\x1b]11;rgb:ffff/fafa/f0f0\x1b\\" +
		"q" + "\x1bP>|WezTerm 20240203\x1b\\" + "\x1b[?62;22c"
	rest := probe_scan(transmute([]u8)replies, &info, &typed)
	testing.expect_value(t, len(rest), 0)
	testing.expect(t, info.answered)
	testing.expect(t, info.kitty_keyboard)
	testing.expect_value(t, info.sync_output, Mode_Support.Reset)
	testing.expect_value(t, info.graphemes, Mode_Support.Unrecognized)
	testing.expect_value(t, info.background, rgb(255, 250, 240))
	testing.expect_value(t, info.name, "WezTerm 20240203")
	testing.expect_value(t, string(typed[:]), "q") // a key typed mid-probe is kept
	testing.expect_value(t, auto_theme(info).name, "daybreak")
	delete(info.name)

	// A reply split across reads waits for the rest.
	partial: Terminal_Info
	rest = probe_scan(transmute([]u8)string("\x1b[?2027;"), &partial, &typed)
	testing.expect_value(t, string(rest), "\x1b[?2027;")
	testing.expect_value(t, _parse_xcolor("rgb:00/80/ff"), rgb(0, 128, 255))
	testing.expect_value(t, _parse_xcolor("nonsense"), NO_COLOR)
}

@(test)
test_decoder_ignores_late_replies :: proc(t: ^testing.T) {
	// Replies that arrive after the probe window must never become keys.
	stream := "\x1b[?1u" + "\x1b[?2026;2$y" + "\x1b]11;rgb:0/0/0\x07" + "\x1bP>|kitty\x1b\\" + "\x1b[?62c" + "x"
	buf := transmute([]u8)stream
	keys := 0
	for len(buf) > 0 {
		ev, n, st := decode(buf)
		testing.expect(t, st != .Need_More, "complete replies decode")
		if st == .Ok {
			k := ev.(Key)
			testing.expect_value(t, k.ch, 'x')
			keys += 1
		}
		buf = buf[n:]
	}
	testing.expect_value(t, keys, 1)
	// ESC P / ESC ] alone might be the start of a reply, so they wait; once
	// the ESC timeout flushes them they are Alt+P / Alt+].
	_, _, st := decode(transmute([]u8)string("\x1bP"))
	testing.expect_value(t, st, Decode_Status.Need_More)
	k, _, _ := decode(transmute([]u8)string("\x1bP"), flush = true)
	testing.expect_value(t, k.(Key), Key{code = .Char, ch = 'P', mods = {.Alt}})
	k, _, _ = decode(transmute([]u8)string("\x1b]"), flush = true)
	testing.expect_value(t, k.(Key), Key{code = .Char, ch = ']', mods = {.Alt}})
}

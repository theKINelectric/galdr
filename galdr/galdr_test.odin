package galdr

import "core:strings"
import "core:testing"

// ------------------------------------------------------------ decoder

@(private = "file")
key_of :: proc(t: ^testing.T, s: string, flush := false) -> (Key, int) {
	ev, n, st := decode(transmute([]u8)s, flush)
	testing.expect_value(t, st, Decode_Status.Ok)
	k, ok := ev.(Key)
	testing.expect(t, ok, "expected a Key")
	return k, n
}

@(test)
test_decode_plain_and_control :: proc(t: ^testing.T) {
	k, n := key_of(t, "a")
	testing.expect_value(t, k, Key{code = .Char, ch = 'a'})
	testing.expect_value(t, n, 1)
	k, _ = key_of(t, "\x03")
	testing.expect(t, is_ctrl(k, 'c'))
	k, _ = key_of(t, "\r")
	testing.expect_value(t, k.code, Key_Code.Enter)
	k, _ = key_of(t, "\x7f")
	testing.expect_value(t, k.code, Key_Code.Backspace)
	k, n = key_of(t, "é!")
	testing.expect_value(t, k.ch, 'é')
	testing.expect_value(t, n, 2)
}

@(test)
test_decode_escape_ambiguity :: proc(t: ^testing.T) {
	_, n, st := decode(transmute([]u8)string("\x1b"), false)
	testing.expect_value(t, st, Decode_Status.Need_More)
	testing.expect_value(t, n, 0)
	k, _ := key_of(t, "\x1b", flush = true)
	testing.expect_value(t, k.code, Key_Code.Escape)
	k, _ = key_of(t, "\x1bx")
	testing.expect_value(t, k, Key{code = .Char, ch = 'x', mods = {.Alt}})
	_, _, st = decode(transmute([]u8)string("\x1b[1;5"), false)
	testing.expect_value(t, st, Decode_Status.Need_More)
}

@(test)
test_decode_csi_keys :: proc(t: ^testing.T) {
	k, n := key_of(t, "\x1b[A")
	testing.expect_value(t, k.code, Key_Code.Up)
	testing.expect_value(t, n, 3)
	k, _ = key_of(t, "\x1b[1;5C")
	testing.expect_value(t, k, Key{code = .Right, mods = {.Ctrl}})
	k, _ = key_of(t, "\x1b[3~")
	testing.expect_value(t, k.code, Key_Code.Delete)
	k, _ = key_of(t, "\x1b[5;2~")
	testing.expect_value(t, k, Key{code = .Page_Up, mods = {.Shift}})
	k, _ = key_of(t, "\x1bOP")
	testing.expect_value(t, k.code, Key_Code.F1)
	k, _ = key_of(t, "\x1b[Z")
	testing.expect_value(t, k, Key{code = .Tab, mods = {.Shift}})
	k, _ = key_of(t, "\x1b[24~")
	testing.expect_value(t, k.code, Key_Code.F12)
}

@(test)
test_decode_kitty :: proc(t: ^testing.T) {
	k, _ := key_of(t, "\x1b[99;5u")
	testing.expect(t, is_ctrl(k, 'c'))
	k, _ = key_of(t, "\x1b[27u")
	testing.expect_value(t, k.code, Key_Code.Escape)
	k, _ = key_of(t, "\x1b[97;2u")
	testing.expect_value(t, k, Key{code = .Char, ch = 'A'})
	k, _ = key_of(t, "\x1b[13;3u")
	testing.expect_value(t, k, Key{code = .Enter, mods = {.Alt}})
}

@(test)
test_decode_mouse_paste_focus :: proc(t: ^testing.T) {
	ev, n, st := decode(transmute([]u8)string("\x1b[<0;10;5M"))
	testing.expect_value(t, st, Decode_Status.Ok)
	testing.expect_value(t, n, 10)
	testing.expect_value(t, ev.(Mouse), Mouse{x = 9, y = 4, button = .Left, action = .Press})
	ev, _, _ = decode(transmute([]u8)string("\x1b[<0;10;5m"))
	testing.expect_value(t, ev.(Mouse).action, Mouse_Action.Release)
	ev, _, _ = decode(transmute([]u8)string("\x1b[<65;3;3M"))
	testing.expect_value(t, ev.(Mouse).button, Mouse_Button.Wheel_Down)
	ev, _, _ = decode(transmute([]u8)string("\x1b[<32;4;4M"))
	testing.expect_value(t, ev.(Mouse).action, Mouse_Action.Drag)

	src := "\x1b[200~hello\x1b[world\x1b[201~z"
	ev, n, st = decode(transmute([]u8)src)
	testing.expect_value(t, st, Decode_Status.Ok)
	testing.expect_value(t, ev.(Paste).text, "hello\x1b[world")
	testing.expect_value(t, src[n:], "z")
	_, _, st = decode(transmute([]u8)string("\x1b[200~partial"))
	testing.expect_value(t, st, Decode_Status.Need_More)

	ev, _, _ = decode(transmute([]u8)string("\x1b[I"))
	testing.expect_value(t, ev.(Focus).gained, true)
}

// ------------------------------------------------------------ text

@(test)
test_widths_and_truncate :: proc(t: ^testing.T) {
	testing.expect_value(t, text_width("abc"), 3)
	testing.expect_value(t, text_width("日本"), 4)
	testing.expect_value(t, text_width("🚀"), 2)
	testing.expect_value(t, text_width("é"), 1)
	testing.expect_value(t, truncate("hello world", 8), "hello w…")
	testing.expect_value(t, truncate("日本語テキスト", 5), "日本…")
	testing.expect_value(t, pad_right("ab", 4), "ab  ")
}

@(test)
test_wrap :: proc(t: ^testing.T) {
	lines := wrap("the quick brown fox jumps", 10)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[0], "the quick")
	testing.expect_value(t, lines[1], "brown fox")
	testing.expect_value(t, lines[2], "jumps")
	lines = wrap("abcdefghijkl", 5)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[2], "kl")
	lines = wrap("a\n\nb", 5)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[1], "")
}

// ------------------------------------------------------------ layout

@(test)
test_split :: proc(t: ^testing.T) {
	r := Rect{0, 0, 100, 10}
	cols := columns(r, {fixed(20), grow(), fixed(30)}, gap = 1)
	testing.expect_value(t, cols[0], Rect{0, 0, 20, 10})
	testing.expect_value(t, cols[1], Rect{21, 0, 48, 10})
	testing.expect_value(t, cols[2], Rect{70, 0, 30, 10})
	parts := rows(r, {grow(1), grow(2), grow(1)})
	testing.expect_value(t, parts[0].h + parts[1].h + parts[2].h, 10)
	testing.expect_value(t, parts[1].h, 5)
	// Over-subscription shrinks from the end instead of overflowing.
	tight := columns({0, 0, 10, 1}, {fixed(8), fixed(8)})
	testing.expect_value(t, tight[0].w + tight[1].w, 10)
	rr := Rect{0, 0, 40, 20}
	top := cut_top(&rr, 3)
	testing.expect_value(t, top, Rect{0, 0, 40, 3})
	testing.expect_value(t, rr, Rect{0, 3, 40, 17})
	testing.expect_value(t, center({0, 0, 10, 10}, 4, 2), Rect{3, 4, 4, 2})
}

// ------------------------------------------------------------ frame + render

@(test)
test_frame_wide_glyphs :: proc(t: ^testing.T) {
	th := theme_nightfall()
	f := frame_make(6, 1, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	text(&f, 0, 0, "a日b", {})
	testing.expect_value(t, row_text(&f, 0), "a日b")
	testing.expect_value(t, f.cells[2].width, u8(0))
	// Overwriting the tail of a wide glyph blanks its head.
	put(&f, 2, 0, 'x', {})
	testing.expect_value(t, row_text(&f, 0), "a xb")
	// Wide glyph that doesn't fit the clip is replaced by a space.
	frame_reset(&f)
	text(&f, 5, 0, "日", {})
	testing.expect_value(t, f.cells[5].ch, ' ')
}

@(test)
test_transparent_background :: proc(t: ^testing.T) {
	th := theme_nightfall()
	f := frame_make(4, 1, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	fill(&f, {0, 0, 4, 1}, {bg = th.surface})
	text(&f, 0, 0, "hi", {fg = th.tones[.Primary]})
	testing.expect_value(t, f.cells[0].pen.bg, th.surface)
	testing.expect_value(t, f.cells[0].pen.fg, th.tones[.Primary])
}

@(test)
test_render_diff_is_minimal :: proc(t: ^testing.T) {
	th := theme_nightfall()
	a := frame_make(10, 3, &th)
	b := frame_make(10, 3, &th)
	defer frame_destroy(&a)
	defer frame_destroy(&b)
	frame_reset(&a)
	frame_reset(&b)
	text(&a, 0, 0, "hello", {})
	text(&b, 0, 0, "hello", {})
	text(&b, 2, 1, "X", {})

	sb := strings.builder_make(context.temp_allocator)
	render_diff(&sb, &a, &b, false, {depth = .True_Color})
	out := strings.to_string(sb)
	testing.expect(t, strings.contains(out, "\x1b[2;3H"), "moves to the changed cell")
	testing.expect(t, strings.contains(out, "X"))
	testing.expect(t, !strings.contains(out, "hello"), "unchanged text is not re-sent")
	testing.expect(t, strings.has_prefix(out, "\x1b[?2026h"), "synchronized update")

	strings.builder_reset(&sb)
	render_diff(&sb, &b, &b, false, {depth = .True_Color})
	testing.expect(t, !strings.contains(strings.to_string(sb), "X"), "identical frames emit no glyphs")

	strings.builder_reset(&sb)
	render_diff(&sb, nil, &b, true, {depth = .Palette_256})
	full := strings.to_string(sb)
	testing.expect(t, strings.contains(full, "hello"))
	testing.expect(t, strings.contains(full, "48;5;"), "256-color fallback")
}

@(test)
test_color_helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, hex("#ff8000"), rgb(255, 128, 0))
	testing.expect_value(t, hex("0f0"), rgb(0, 255, 0))
	testing.expect_value(t, hex("zz"), NO_COLOR)
	testing.expect_value(t, mix(rgb(0, 0, 0), rgb(200, 100, 50), 0.5), rgb(100, 50, 25))
	testing.expect_value(t, to_256(rgb(255, 0, 0)), u8(196))
	testing.expect_value(t, to_256(rgb(128, 128, 128)), u8(244))
}

// ------------------------------------------------------------ components

@(test)
test_block_and_widgets :: proc(t: ^testing.T) {
	th := theme_nightfall()
	f := frame_make(24, 5, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	inner := block(&f, {0, 0, 24, 5}, {border = .Rounded, title = "Crew", pad_x = 1})
	testing.expect_value(t, inner, Rect{2, 1, 20, 3})
	testing.expect_value(t, row_text(&f, 0), "╭─ Crew " + "───────────────" + "╮")
	testing.expect_value(t, text_width(row_text(&f, 4)), 24)
	progress(&f, 2, 1, 10, 0.55)
	testing.expect_value(t, row_text(&f, 1), "│ █████▌               │")
	badge(&f, 2, 2, "LIVE", .Success, .Outline)
	testing.expect(t, strings.contains(row_text(&f, 2), "[LIVE]"))
}

@(test)
test_text_field_editing :: proc(t: ^testing.T) {
	tf: Text_Field
	defer field_destroy(&tf)
	for r in "hello world" do field_on_key(&tf, Key{code = .Char, ch = r})
	testing.expect_value(t, field_text(&tf), "hello world")
	field_on_key(&tf, Key{code = .Char, ch = 'w', mods = {.Ctrl}})
	testing.expect_value(t, field_text(&tf), "hello ")
	field_on_key(&tf, Key{code = .Home})
	field_on_key(&tf, Key{code = .Char, ch = '>'})
	testing.expect_value(t, field_text(&tf), ">hello ")
	field_on_key(&tf, Key{code = .Char, ch = 'k', mods = {.Ctrl}})
	testing.expect_value(t, field_text(&tf), ">")
	tf.limit = 3
	field_insert(&tf, "abcdef")
	testing.expect_value(t, field_text(&tf), ">ab")
}

@(test)
test_pick_list_scrolls :: proc(t: ^testing.T) {
	l: Pick_List
	for _ in 0 ..< 7 do pick_on_key(&l, Key{code = .Down}, 20)
	pick_scroll(&l, 20, 5)
	testing.expect_value(t, l.cursor, 7)
	testing.expect_value(t, l.offset, 3)
	pick_on_key(&l, Key{code = .End}, 20)
	pick_scroll(&l, 20, 5)
	testing.expect_value(t, l.offset, 15)
	testing.expect_value(t, pick_hit(&l, {0, 10, 20, 5}, Mouse{x = 2, y = 12}, 20), 17)
}

@(test)
test_markdown :: proc(t: ^testing.T) {
	th := theme_nightfall()
	src := "# Title\n\nSome **bold** and `code` text that wraps nicely.\n\n- one\n- [x] done\n\n> quoted\n\n```odin\nx := 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
	lines := md_lines(src, 20, &th, context.temp_allocator)
	f := frame_make(20, len(lines), &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	for l, i in lines do spans(&f, 0, i, l)
	out := frame_to_text(&f)
	testing.expect(t, strings.contains(out, " TITLE"), out)
	testing.expect(t, strings.contains(out, "• one"), out)
	testing.expect(t, strings.contains(out, "☑ done"), out)
	testing.expect(t, strings.contains(out, "┃ quoted"), out)
	testing.expect(t, strings.contains(out, "x := 1"), out)
	testing.expect(t, strings.contains(out, "a │ b"), out)
	testing.expect(t, !strings.contains(out, "**"), "emphasis markers are consumed")
	for l in lines do testing.expect(t, spans_width(l) <= 20, "no line exceeds the width")
}

// ------------------------------------------------------------ harness

@(private = "file")
Counter :: struct {
	n:     int,
	ticks: int,
	log:   [dynamic]string,
}

@(private = "file")
Counter_Msg :: union {
	Tick_Msg,
	Loaded_Msg,
}
@(private = "file") Tick_Msg :: struct {}
@(private = "file") Loaded_Msg :: struct {value: int}

@(private = "file")
counter_app :: App(Counter, Counter_Msg){
	boot = proc(s: ^Counter, fx: ^Fx(Counter_Msg)) {
		after(fx, 100, Counter_Msg(Tick_Msg{}))
		spawn(fx, proc(_: rawptr) -> Counter_Msg { return Loaded_Msg{42} })
	},
	react = proc(s: ^Counter, ev: Event(Counter_Msg), fx: ^Fx(Counter_Msg)) {
		switch e in ev {
		case Key:
			if is_char(e, '+') do s.n += 1
			if is_char(e, 'q') do quit(fx)
		case Counter_Msg:
			switch m in e {
			case Tick_Msg:
				s.ticks += 1
				after(fx, 100, Counter_Msg(Tick_Msg{}))
			case Loaded_Msg:
				s.n += m.value
			}
		case Mouse, Resize, Paste, Focus:
		}
	},
	paint = proc(s: ^Counter, f: ^Frame) {
		text(f, 0, 0, "n=", {})
		text(f, 2, 0, s.n == 45 ? "45" : "?", {})
	},
}

@(test)
test_harness_drives_app :: proc(t: ^testing.T) {
	s: Counter
	h: Harness(Counter, Counter_Msg)
	harness_init(&h, counter_app, &s, 10, 2)
	defer harness_destroy(&h)
	testing.expect_value(t, s.n, 42) // spawned task delivered synchronously
	harness_type(&h, "+++")
	testing.expect_value(t, harness_snapshot(&h), "n=45\n")
	harness_advance(&h, 350)
	testing.expect_value(t, s.ticks, 3)
	harness_type(&h, "q")
	testing.expect(t, h.engine.quit)
}

// ------------------------------------------------------------ timer fairness

Loop_State :: struct {
	fires: int,
}

Loop_Msg :: struct {}

loop_app :: App(Loop_State, Loop_Msg){
	react = proc(s: ^Loop_State, ev: Event(Loop_Msg), fx: ^Fx(Loop_Msg)) {
		switch e in ev {
		case Resize:
			after(fx, 0, Loop_Msg{})
		case Loop_Msg:
			s.fires += 1
			after(fx, 0, Loop_Msg{}) // rearm at the same instant
		case Key, Mouse, Paste, Focus:
		}
	},
}

loop_quit_app :: App(Loop_State, Loop_Msg){
	react = proc(s: ^Loop_State, ev: Event(Loop_Msg), fx: ^Fx(Loop_Msg)) {
		switch e in ev {
		case Resize:
			after(fx, 0, Loop_Msg{})
		case Loop_Msg:
			s.fires += 1
			after(fx, 0, Loop_Msg{})
			if s.fires >= 5 do quit(fx)
		case Key, Mouse, Paste, Focus:
		}
	},
}

tick_app :: App(Loop_State, Loop_Msg){
	react = proc(s: ^Loop_State, ev: Event(Loop_Msg), fx: ^Fx(Loop_Msg)) {
		switch e in ev {
		case Resize:
			after(fx, 80, Loop_Msg{})
		case Loop_Msg:
			s.fires += 1
			after(fx, 80, Loop_Msg{})
		case Key, Mouse, Paste, Focus:
		}
	},
}

@(test)
test_zero_delay_rearm_returns_to_the_loop :: proc(t: ^testing.T) {
	// Regression (audit A6): a handler rearming itself with after(fx, 0, …)
	// used to monopolize engine_fire_timers forever. Now each call dispatches
	// only timers that existed when it started: one fire per turn. (On the old
	// code the first engine_fire_timers below never returns, hanging the suite.)
	s: Loop_State
	e: Engine(Loop_State, Loop_Msg)
	engine_init(&e, loop_app, &s, theme_nightfall())
	defer engine_destroy(&e)
	engine_dispatch(&e, Resize{1, 1}) // schedules the first zero-delay timer
	engine_fire_timers(&e)
	testing.expect_value(t, s.fires, 1) // exactly one fire this turn
	testing.expect_value(t, len(e.timers), 1) // the rearm waits for the next turn
	engine_fire_timers(&e)
	testing.expect_value(t, s.fires, 2)
	testing.expect_value(t, len(e.timers), 1)

	// Virtual time through a zero-delay storm is bounded and honest: the
	// harness stops where it stopped instead of claiming the whole span.
	h: Harness(Loop_State, Loop_Msg)
	harness_init(&h, loop_app, &s, 4, 1)
	defer harness_destroy(&h)
	harness_advance(&h, 1000)
	testing.expect(t, s.fires >= 2)
	testing.expect(t, h.engine.now_ms < 1000, "a storm does not consume the whole span")

	// A quit delivered during the storm still ends it.
	s2: Loop_State
	h2: Harness(Loop_State, Loop_Msg)
	harness_init(&h2, loop_quit_app, &s2, 4, 1)
	defer harness_destroy(&h2)
	harness_advance(&h2, 1000)
	testing.expect(t, h2.engine.quit)
	testing.expect_value(t, s2.fires, 5)
}

@(test)
test_harness_advance_never_skips_real_schedules :: proc(t: ^testing.T) {
	// Re-review case: the first fairness fix bounded ALL turns, so a 10-minute
	// advance of an 80 ms clock fired 4,096 of its 7,500 ticks. Only
	// non-advancing turns are bounded now.
	s: Loop_State
	h: Harness(Loop_State, Loop_Msg)
	harness_init(&h, tick_app, &s, 4, 1)
	defer harness_destroy(&h)
	harness_advance(&h, 600_000)
	testing.expect_value(t, s.fires, 7_500)
	testing.expect_value(t, h.engine.now_ms, 600_000)
}

@(test)
test_untrusted_text_cannot_inject_escapes :: proc(t: ^testing.T) {
	th := theme_nightfall()
	f := frame_make(40, 2, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	evil := "a\x1b]0;pwned\x07b\x1b[2Jc\u009b31md\x7fe"
	text(&f, 0, 0, evil, {})
	lines := md_lines(evil, 30, &th, context.temp_allocator)
	for l in lines do spans(&f, 0, 1, l)
	testing.expect_value(t, row_text(&f, 0), "a]0;pwnedb[2Jc31mde")
	sb := strings.builder_make(context.temp_allocator)
	render_diff(&sb, nil, &f, true, {depth = .True_Color})
	out := strings.to_string(sb)
	testing.expect(t, !strings.contains(out, "\x1b]0;"), "no OSC from content")
	testing.expect(t, !strings.contains(out, "\x07"), "no BEL from content")
	testing.expect(t, !strings.contains(out, "\u009b"), "no C1 CSI from content")
	testing.expect_value(t, strings.count(out, "\x1b[2J"), 1) // only our own clear
	testing.expect_value(t, sanitize("ti\x1btle\x07\u009b!"), "title!")
}

@(test)
test_md_doc_owns_its_memory :: proc(t: ^testing.T) {
	th := theme_nightfall()
	src := strings.clone("# Hi\n\nSome *text* here.\n")
	doc := md_render(src, 30, &th)
	delete(src) // the doc keeps its own copy
	testing.expect(t, len(doc.lines) > 2)
	testing.expect_value(t, doc.lines[0][0].text, " HI ")
	md_destroy(&doc)
	testing.expect(t, doc.lines == nil)
}

@(test)
test_reduced_color_depths :: proc(t: ^testing.T) {
	th := theme_nightfall()
	f := frame_make(12, 1, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	badge(&f, 0, 0, "GO", .Success, .Solid)
	text(&f, 5, 0, "red", {fg = rgb(230, 20, 20)})

	sb := strings.builder_make(context.temp_allocator)
	render_diff(&sb, nil, &f, true, {depth = .Mono})
	mono := strings.to_string(sb)
	testing.expect(t, !strings.contains(mono, "38;") && !strings.contains(mono, "48;"), "mono emits no colors")
	testing.expect(t, strings.contains(mono, ";1;7m GO "), "solid badge becomes bold reverse")

	strings.builder_reset(&sb)
	render_diff(&sb, nil, &f, true, {depth = .Ansi_16})
	ansi := strings.to_string(sb)
	testing.expect(t, !strings.contains(ansi, "38;2;") && !strings.contains(ansi, "38;5;"), "16-color uses only 30-37/90-97")
	testing.expect(t, strings.contains(ansi, "31mred") || strings.contains(ansi, "91mred"), ansi)
	testing.expect_value(t, to_16(rgb(0, 0, 0)), u8(0))
	testing.expect_value(t, to_16(rgb(250, 250, 250)), u8(15))
}

@(test)
test_grapheme_clusters_in_cells :: proc(t: ^testing.T) {
	th := theme_nightfall()
	f := frame_make(12, 1, &th)
	defer frame_destroy(&f)
	saved := width_mode
	defer width_mode = saved

	// Combining accent stays with its base in either mode (it used to be dropped).
	for mode in Width_Mode {
		width_mode = mode
		frame_reset(&f)
		n := text(&f, 0, 0, "é!", {})
		testing.expect_value(t, n, 2)
		testing.expect_value(t, row_text(&f, 0), "é!")
	}

	family := "\U0001F468‍\U0001F469‍\U0001F467" // 👨‍👩‍👧
	flag := "\U0001F1FA\U0001F1E6"                         // 🇺🇦
	width_mode = .Grapheme
	testing.expect_value(t, text_width(family), 2)
	testing.expect_value(t, text_width(flag), 2)
	testing.expect_value(t, text_width("❤️"), 2) // ❤️ emoji presentation
	frame_reset(&f)
	text(&f, 0, 0, family, {})
	testing.expect_value(t, f.cells[0].width, u8(2))
	testing.expect_value(t, row_text(&f, 0), family) // the whole sequence, in one cell

	width_mode = .Legacy // wcwidth terminals advance per codepoint
	testing.expect_value(t, text_width(family), 6)
	testing.expect_value(t, text_width(flag), 2)
	testing.expect_value(t, truncate("ab\U0001F468‍\U0001F469", 3), "ab…")
}

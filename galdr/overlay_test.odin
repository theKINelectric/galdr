package galdr

import "core:strings"
import "core:testing"

@(test)
test_fuzzy_ranking :: proc(t: ^testing.T) {
	pos := make([dynamic]int, context.temp_allocator)
	_, ok := fuzzy_match("msn", "Mission", &pos)
	testing.expect(t, ok)
	_, ok = fuzzy_match("xyz", "Mission")
	testing.expect(t, !ok)
	a, _ := fuzzy_match("ms", "Mission Status")
	b, _ := fuzzy_match("ms", "atoms")
	testing.expectf(t, a > b, "word starts outrank buried matches (%d vs %d)", a, b)
	fuzzy_match("gs", "git status", &pos)
	testing.expect_value(t, pos[0], 0)
	testing.expect_value(t, pos[1], 4) // the word start 's', not the first 's'
	c, _ := fuzzy_match("save", "Save File")
	d, _ := fuzzy_match("save", "sAVe as backup copy")
	testing.expect(t, c > d)
}

@(test)
test_filter_list :: proc(t: ^testing.T) {
	items := []string{"Open file", "Save file", "Save as…", "Close tab", "Quit"}
	fl: Filter
	defer filter_destroy(&fl)
	filter_update(&fl, items)
	testing.expect_value(t, len(fl.matches), 5)
	for r in "sav" do filter_on_key(&fl, Key{code = .Char, ch = r}, items)
	testing.expect_value(t, len(fl.matches), 2)
	idx, ok := filter_selected(&fl)
	testing.expect(t, ok && strings.has_prefix(items[idx], "Save"))
	filter_on_key(&fl, Key{code = .Down}, items)
	idx, _ = filter_selected(&fl)
	testing.expect(t, strings.has_prefix(items[idx], "Save"))
	for _ in 0 ..< 3 do filter_on_key(&fl, Key{code = .Backspace}, items)
	testing.expect_value(t, len(fl.matches), 5)

	th := theme_nightfall()
	f := frame_make(40, 8, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	for r in "qu" do filter_on_key(&fl, Key{code = .Char, ch = r}, items)
	filter_draw(&f, {0, 0, 40, 4}, &fl, items)
	testing.expect(t, strings.contains(row_text(&f, 0), "1/5"))
	testing.expect(t, strings.contains(row_text(&f, 1), "Quit"))
}

@(test)
test_toasts_expire :: proc(t: ^testing.T) {
	ts: Toasts
	for i in 0 ..< 6 do toast(&ts, 0, .Info, "hello", 1000 + i)
	testing.expect_value(t, ts.count, MAX_TOASTS)
	th := theme_nightfall()
	f := frame_make(40, 12, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	f.now_ms = 500
	toasts_draw(&f, &ts)
	testing.expect(t, strings.contains(frame_to_text(&f), "hello"))
	f.now_ms = 5000
	frame_reset(&f)
	f.now_ms = 5000
	toasts_draw(&f, &ts)
	testing.expect_value(t, ts.count, 0)
}

@(test)
test_modal_layers_on_top :: proc(t: ^testing.T) {
	th := theme_nightfall()
	f := frame_make(40, 12, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	zone(&f, "button", {0, 0, 40, 12})
	inner := modal(&f, 20, 6, "Confirm")
	text(&f, inner.x, inner.y, "Sure?", {})
	z, _ := zone_at(f.zones[:], 20, 6)
	testing.expect_value(t, z.name, "modal")
	z, _ = zone_at(f.zones[:], 1, 1)
	testing.expect_value(t, z.name, "backdrop") // clicks outside hit the backdrop, not the button
	testing.expect(t, strings.contains(frame_to_text(&f), "Sure?"))
	p := popover(&f, {35, 10, 3, 1}, 10, 4)
	testing.expect(t, p.y < 10, "popover flips above when there's no room below")
}

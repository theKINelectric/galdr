package galdr

import "core:testing"

@(private = "file")
Action :: enum {
	Quit,
	Save,
	Up,
	Help,
	Next_Pane,
}

@(test)
test_keymap :: proc(t: ^testing.T) {
	bindings := []Binding(Action){
		{action = .Quit, keys = {"q", "ctrl+c"}, help = "quit"},
		{action = .Save, keys = {"ctrl+s"}, help = "save"},
		{action = .Up, keys = {"up", "k"}, help = "move"},
		{action = .Help, keys = {"?"}},
		{action = .Next_Pane, keys = {"shift+tab"}, help = "back"},
	}
	km := Keymap(Action){bindings}
	a, ok := keymap_match(km, Key{code = .Char, ch = 'c', mods = {.Ctrl}})
	testing.expect(t, ok && a == .Quit)
	a, ok = keymap_match(km, Key{code = .Up})
	testing.expect(t, ok && a == .Up)
	a, ok = keymap_match(km, Key{code = .Char, ch = '?', mods = {.Shift}}) // shift is in the rune
	testing.expect(t, ok && a == .Help)
	a, ok = keymap_match(km, Key{code = .Tab, mods = {.Shift}})
	testing.expect(t, ok && a == .Next_Pane)
	_, ok = keymap_match(km, Key{code = .Char, ch = 's'}) // plain s is not ctrl+s
	testing.expect(t, !ok)

	hints := keymap_hints(km)
	testing.expect_value(t, len(hints), 4) // Help has no text
	testing.expect_value(t, hints[2], Key_Hint{"↑", "move"})
	keymap_enable(&km, Action.Save, false)
	_, ok = keymap_match(km, Key{code = .Char, ch = 's', mods = {.Ctrl}})
	testing.expect(t, !ok)
	testing.expect_value(t, len(keymap_hints(km)), 3)

	k, valid := key_parse("shift+a")
	testing.expect(t, valid && k == Key{code = .Char, ch = 'A'})
	_, valid = key_parse("ctrl+")
	testing.expect(t, !valid)
}

@(private = "file")
Pane :: enum {
	List,
	Detail,
	Input,
}

@(test)
test_focus_ring :: proc(t: ^testing.T) {
	ring := Focus_Ring(Pane){}
	focus_on_key(&ring, Key{code = .Tab})
	testing.expect_value(t, ring.current, Pane.Detail)
	ring.skip = {.Input}
	focus_next(&ring)
	testing.expect_value(t, ring.current, Pane.List) // Input skipped, wrapped
	focus_on_key(&ring, Key{code = .Tab, mods = {.Shift}})
	testing.expect_value(t, ring.current, Pane.Detail)
	testing.expect(t, is_focused(ring, Pane.Detail))
}

@(test)
test_zones_and_clip_scope :: proc(t: ^testing.T) {
	th := theme_nightfall()
	f := frame_make(20, 5, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	zone(&f, "tab", {0, 0, 5, 1}, 0)
	zone(&f, "tab", {6, 0, 5, 1}, 1)
	zone(&f, "dialog", {3, 0, 6, 3}) // painted later: on top
	z, ok := zone_at(f.zones[:], 7, 0)
	testing.expect(t, ok && z.name == "dialog")
	z, ok = zone_at(f.zones[:], 10, 0)
	testing.expect(t, ok && z.name == "tab" && z.index == 1)
	{
		clip_scope(&f, {0, 0, 4, 5})
		text(&f, 0, 1, "clipped text", {})
	}
	text(&f, 0, 2, "free", {})
	testing.expect_value(t, row_text(&f, 1), "clip")
	testing.expect_value(t, row_text(&f, 2), "free") // the scope ended
}

package cookbook

// Recipe: key bindings with a Keymap; the help bar comes from the same table.

import gd "galdr:galdr"
import "core:fmt"

Key_Action :: enum {
	Up,
	Down,
	Save,
	Quit,
}

KEY_BINDINGS := [?]gd.Binding(Key_Action){
	{action = .Up, keys = {"up", "k", "+"}, help = "more"},
	{action = .Down, keys = {"down", "j", "-"}, help = "less"},
	{action = .Save, keys = {"ctrl+s"}, help = "save", disabled = true},
	{action = .Quit, keys = {"q", "ctrl+c"}, help = "quit"},
}
KEYMAP := gd.Keymap(Key_Action){KEY_BINDINGS[:]}

Keys_State :: struct {
	count, saved: int,
}

keys_react :: proc(s: ^Keys_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	k, is_key := ev.(gd.Key)
	if !is_key do return
	action, bound := gd.keymap_match(KEYMAP, k)
	if !bound do return
	switch action {
	case .Up:   s.count += 1
	case .Down: s.count -= 1
	case .Save: s.saved = s.count
	case .Quit: gd.quit(fx)
	}
	// Save only makes sense with unsaved changes. Disabled bindings neither
	// match nor show up in the help bar.
	gd.keymap_enable(&KEYMAP, Key_Action.Save, s.count != s.saved)
}

keys_paint :: proc(s: ^Keys_State, f: ^gd.Frame) {
	th := f.theme
	gd.text(f, 1, 1, fmt.tprintf("count %d (saved %d)", s.count, s.saved), gd.text_pen(th))
	gd.help_bar(f, 1, f.h - 1, f.w - 2, gd.keymap_hints(KEYMAP))
}

KEYS_APP :: gd.App(Keys_State, gd.No_Msg){react = keys_react, paint = keys_paint}

keys_run :: proc() -> gd.Run_Error {
	s: Keys_State
	return gd.run(KEYS_APP, &s)
}

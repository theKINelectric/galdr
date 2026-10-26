package mission

import gd "galdr:galdr"
import "core:strings"
import "core:testing"

@(test)
test_mission_headless :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the demo's state is not freed piecemeal
	s: State
	h: gd.Harness(State, Msg)
	gd.harness_init(&h, gd.App(State, Msg){boot = boot, react = react, paint = paint}, &s, 140, 38)

	screen := gd.harness_snapshot(&h)
	testing.expect(t, strings.contains(screen, "BEINGS IN AVATAR"), screen)
	testing.expect(t, strings.contains(screen, "HOLD"), "Grok's seat projects HOLD")

	// Crew selection moves with the keyboard.
	gd.harness_key(&h, .Down)
	gd.harness_key(&h, .Down)
	testing.expect_value(t, s.crew_list.cursor, 2)

	// Chat: focus, type, send; the spawned reply arrives (synchronously here).
	gd.harness_key(&h, .Tab)
	gd.harness_type(&h, "status?")
	gd.harness_key(&h, .Enter)
	testing.expect_value(t, len(s.chat), 4)
	testing.expect_value(t, s.chat[2].text, "status?")
	testing.expect(t, !s.waiting, "reply delivered")
	gd.harness_key(&h, .Escape)

	// Timers: two seconds of virtual time = 4 pulses.
	gd.harness_advance(&h, 2000)
	testing.expect_value(t, s.seconds, 4)

	// Tabs and themes.
	gd.harness_type(&h, "3")
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "README.md"))
	gd.harness_type(&h, "t")
	testing.expect_value(t, h.engine.theme.name, "daybreak")

	// Command palette: ctrl+k, fuzzy "work", Enter.
	gd.harness_send(&h, gd.Key{code = .Char, ch = 'k', mods = {.Ctrl}})
	testing.expect(t, s.palette_open)
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "Commands"))
	gd.harness_type(&h, "work")
	gd.harness_key(&h, .Enter)
	testing.expect_value(t, s.tab, 3)

	// Workshop form: submitting empty jumps to the error; filling it submits.
	gd.harness_key(&h, .Tab) // Files → Form
	gd.harness_send(&h, gd.Key{code = .Char, ch = 's', mods = {.Ctrl}})
	testing.expect_value(t, s.form_fields[0].err, "required")
	gd.harness_type(&h, "Maverick")
	gd.harness_send(&h, gd.Key{code = .Char, ch = 's', mods = {.Ctrl}})
	testing.expect_value(t, s.toasts.count, 2) // the theme toast and "welcome aboard"
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "welcome aboard, Maverick"))

	// Mouse: click the first tab through its zone.
	gd.harness_paint(&h)
	tab0: gd.Zone
	for z in h.engine.zones do if z.name == "tab" && z.index == 0 do tab0 = z
	gd.harness_click(&h, tab0.rect.x + 1, tab0.rect.y)
	testing.expect_value(t, s.tab, 0)

	gd.harness_type(&h, "q")
	testing.expect(t, h.engine.quit)
}

@(test)
test_comms_follows_the_layout :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	sizes := [3][2]int{{140, 38}, {114, 70}, {100, 30}} // wide; narrow+tall (the Chief's window); narrow+short
	for size, i in sizes {
		s: State
		h: gd.Harness(State, Msg)
		gd.harness_init(&h, gd.App(State, Msg){boot = boot, react = react, paint = paint}, &s, size[0], size[1])
		screen := gd.harness_snapshot(&h)
		gd.harness_key(&h, .Tab)
		if i < 2 {
			testing.expectf(t, strings.contains(screen, "COMMS"), "comms visible at %v", size)
			testing.expect_value(t, s.focus, Pane.Comms)
			testing.expect(t, strings.contains(screen, "tab chat"))
		} else {
			testing.expect(t, !strings.contains(screen, "COMMS"))
			testing.expect_value(t, s.focus, Pane.Crew) // tab can't focus a hidden chat
			testing.expect(t, !strings.contains(screen, "tab chat"))
		}
	}
}

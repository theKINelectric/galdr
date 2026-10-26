package cookbook

import gd "galdr:galdr"
import "core:strings"
import "core:testing"

// ------------------------------------------------------------ recipes

@(test)
test_clock :: proc(t: ^testing.T) {
	s: Clock_State
	h: gd.Harness(Clock_State, Clock_Tick)
	gd.harness_init(&h, CLOCK_APP, &s, 20, 3)
	defer gd.harness_destroy(&h)

	gd.harness_advance(&h, 61_000) // virtual time: returns at once
	testing.expect_value(t, s.seconds, 61)
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "01:01"))

	gd.harness_type(&h, "q")
	testing.expect(t, h.engine.quit)
}

@(test)
test_spawn :: proc(t: ^testing.T) {
	s: Work_State
	h: gd.Harness(Work_State, Work_Msg)
	gd.harness_init(&h, WORK_APP, &s, 40, 3)
	defer gd.harness_destroy(&h)

	gd.harness_type(&h, "g") // the harness runs tasks synchronously
	testing.expect(t, !s.busy)
	r, ok := s.result.?
	testing.expect(t, ok)
	testing.expect_value(t, r.count, 5133)
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "5133 primes below 50000"))
}

@(test)
test_layout :: proc(t: ^testing.T) {
	s: Layout_State
	h: gd.Harness(Layout_State, gd.No_Msg)
	gd.harness_init(&h, LAYOUT_APP, &s, 80, 20)
	defer gd.harness_destroy(&h)

	f := gd.harness_paint(&h)
	testing.expect_value(t, gd.row_text(f, 0), "header")
	testing.expect_value(t, gd.row_text(f, 19), "footer")
	screen := gd.frame_to_text(f)
	for title in ([]string{"sidebar", "main", "top", "bottom", "centered"}) {
		testing.expectf(t, strings.contains(screen, title), "%q missing:\n%s", title, screen)
	}
	// Sidebar: fixed 20 wide from x=0; main starts after the 1-cell gap.
	testing.expect_value(t, gd.cell_at(f, 19, 1).ch, '╮')
	testing.expect_value(t, gd.cell_at(f, 21, 1).ch, '╭')
}

@(test)
test_keymap :: proc(t: ^testing.T) {
	gd.keymap_enable(&KEYMAP, Key_Action.Save, false)
	s: Keys_State
	h: gd.Harness(Keys_State, gd.No_Msg)
	gd.harness_init(&h, KEYS_APP, &s, 60, 4)
	defer gd.harness_destroy(&h)

	help :: proc(h: ^gd.Harness(Keys_State, gd.No_Msg)) -> string {
		return gd.row_text(gd.harness_paint(h), 3)
	}
	testing.expect_value(t, help(&h), " ↑ more · ↓ less · q quit")

	gd.harness_type(&h, "k+")
	gd.harness_key(&h, .Up)
	testing.expect_value(t, s.count, 3)
	testing.expect(t, strings.contains(help(&h), "ctrl+s save"))

	gd.harness_send(&h, gd.Key{code = .Char, ch = 's', mods = {.Ctrl}})
	testing.expect_value(t, s.saved, 3)
	testing.expect(t, !strings.contains(help(&h), "save"))

	gd.harness_send(&h, gd.Key{code = .Char, ch = 's', mods = {.Ctrl}}) // disabled: no match
	gd.harness_type(&h, "x") // unbound
	testing.expect_value(t, s.count, 3)
	gd.harness_send(&h, gd.Key{code = .Char, ch = 'c', mods = {.Ctrl}})
	testing.expect(t, h.engine.quit)
}

@(test)
test_focus :: proc(t: ^testing.T) {
	s: Focus_State
	h: gd.Harness(Focus_State, gd.No_Msg)
	gd.harness_init(&h, FOCUS_APP, &s, 40, 20)
	defer gd.harness_destroy(&h)

	gd.harness_key(&h, .Tab)
	testing.expect_value(t, s.ring.current, Focus_Part.Results)
	gd.harness_key(&h, .Tab) // Details is skipped while closed
	testing.expect_value(t, s.ring.current, Focus_Part.Search)
	gd.harness_key(&h, .Tab, {.Shift})
	testing.expect_value(t, s.ring.current, Focus_Part.Results)

	gd.harness_type(&h, "d")
	gd.harness_key(&h, .Tab)
	testing.expect_value(t, s.ring.current, Focus_Part.Details)
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "details"))
	gd.harness_type(&h, "d") // closing it moves focus back
	testing.expect_value(t, s.ring.current, Focus_Part.Results)
}

@(test)
test_mouse :: proc(t: ^testing.T) {
	s: Mouse_State
	h: gd.Harness(Mouse_State, gd.No_Msg)
	gd.harness_init(&h, MOUSE_APP, &s, 40, 5)
	defer gd.harness_destroy(&h)

	gd.harness_paint(&h) // clicks resolve against the last paint
	blue: gd.Zone
	for z in h.engine.zones do if z.name == "choice" && z.index == 2 do blue = z
	gd.harness_click(&h, blue.rect.x + 1, blue.rect.y)
	testing.expect_value(t, s.chosen, 2)

	gd.harness_click(&h, 39, 4) // no zone there
	testing.expect_value(t, s.chosen, 2)

	gd.harness_send(&h, gd.Mouse{x = 5, y = 3, button = .Wheel_Up})
	testing.expect_value(t, s.wheel, 1)
}

@(test)
test_todo :: proc(t: ^testing.T) {
	s: Todo_State
	defer todo_destroy(&s)
	h: gd.Harness(Todo_State, gd.No_Msg)
	gd.harness_init(&h, TODO_APP, &s, 30, 6)
	defer gd.harness_destroy(&h)

	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "new item"))
	gd.harness_type(&h, "milk")
	gd.harness_key(&h, .Enter)
	gd.harness_send(&h, gd.Paste{text = "  jam "})
	gd.harness_key(&h, .Enter)
	gd.harness_key(&h, .Enter) // empty: ignored
	testing.expect_value(t, len(s.items), 2)
	testing.expect_value(t, s.items[1], "jam")
	testing.expect_value(t, s.list.cursor, 1)

	gd.harness_type(&h, "jk") // letters go to the field, not the list
	testing.expect_value(t, s.list.cursor, 1)
	gd.harness_key(&h, .Up)
	testing.expect_value(t, s.list.cursor, 0)
	screen := gd.harness_snapshot(&h)
	testing.expect(t, strings.contains(screen, "milk"), screen)
	testing.expect(t, strings.contains(screen, "› jk"), screen)
}

@(test)
test_confirm :: proc(t: ^testing.T) {
	s: Confirm_State
	h: gd.Harness(Confirm_State, Repaint)
	gd.harness_init(&h, CONFIRM_APP, &s, 60, 16)
	defer gd.harness_destroy(&h)

	gd.harness_type(&h, "d")
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "Delete file?"))
	gd.harness_type(&h, "q") // swallowed by the dialog
	testing.expect(t, !h.engine.quit)
	gd.harness_type(&h, "y")
	testing.expect_value(t, s.files, 2)
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "file deleted"))

	// Clicking outside the dialog closes it; clicking inside does not.
	gd.harness_type(&h, "d")
	gd.harness_paint(&h)
	gd.harness_click(&h, 30, 8)
	testing.expect(t, s.asking)
	gd.harness_click(&h, 0, 0)
	testing.expect(t, !s.asking)

	gd.harness_advance(&h, 3000) // the toast expires
	testing.expect(t, !strings.contains(gd.harness_snapshot(&h), "file deleted"))
	testing.expect_value(t, s.toasts.count, 0)
}

@(test)
test_form :: proc(t: ^testing.T) {
	s: Signup_State
	defer signup_destroy(&s)
	h: gd.Harness(Signup_State, gd.No_Msg)
	gd.harness_init(&h, SIGNUP_APP, &s, 60, 16)
	defer gd.harness_destroy(&h)

	ctrl_s := gd.Key{code = .Char, ch = 's', mods = {.Ctrl}}
	gd.harness_send(&h, ctrl_s)
	testing.expect_value(t, s.fields[0].err, "required")
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "▲ required"))

	gd.harness_type(&h, "Ada")
	gd.harness_key(&h, .Tab)
	gd.harness_send(&h, gd.Paste{text = "ada@nowhere"})
	gd.harness_send(&h, ctrl_s)
	testing.expect_value(t, s.form.focus, 1) // jumps to the first bad field
	testing.expect_value(t, s.fields[1].err, "not an email address")

	gd.harness_type(&h, ".org")
	gd.harness_key(&h, .Tab)
	gd.harness_key(&h, .Right) // plan: team
	gd.harness_key(&h, .Tab)
	gd.harness_key(&h, .Enter) // Enter on the last field submits
	testing.expect_value(t, s.welcome, "welcome, Ada (team)")
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "welcome, Ada (team)"))

	gd.harness_key(&h, .Escape)
	testing.expect(t, h.engine.quit)
}

@(test)
test_theme :: proc(t: ^testing.T) {
	s: Theme_State
	h: gd.Harness(Theme_State, gd.No_Msg)
	gd.harness_init(&h, THEME_APP, &s, 40, 12)
	defer gd.harness_destroy(&h)

	testing.expect_value(t, gd.row_text(gd.harness_paint(&h), 0), " nightfall")
	gd.harness_type(&h, "t")
	testing.expect_value(t, h.engine.theme.name, "daybreak")

	gd.harness_type(&h, "h")
	f := gd.harness_paint(&h)
	testing.expect_value(t, gd.row_text(f, 0), " harbor")
	solid := gd.cell_at(f, 2, 7) // " solid " sits on the accent fill
	testing.expect_value(t, solid.ch, 's')
	testing.expect_value(t, solid.pen.bg, gd.hex("#7ee0c3"))
	testing.expect_value(t, solid.pen.fg, gd.hex("#07101f"))
}

@(test)
test_inline_picker :: proc(t: ^testing.T) {
	s := Pick_State{picked = -1}
	h: gd.Harness(Pick_State, gd.No_Msg)
	gd.harness_init(&h, PICK_APP, &s, 30, 6)
	defer gd.harness_destroy(&h)

	gd.harness_key(&h, .Down)
	gd.harness_type(&h, "j")
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "strawberry"))
	gd.harness_key(&h, .Enter)
	testing.expect_value(t, s.picked, 2)
	testing.expect(t, h.engine.quit)
}

@(test)
test_markdown :: proc(t: ^testing.T) {
	s: Doc_State
	defer gd.md_destroy(&s.doc)
	h: gd.Harness(Doc_State, gd.No_Msg)
	gd.harness_init(&h, DOC_APP, &s, 40, 6)
	defer gd.harness_destroy(&h)

	screen := gd.harness_snapshot(&h)
	testing.expect(t, strings.contains(screen, "RELEASE NOTES"), screen)
	total := len(s.doc.lines)
	testing.expect(t, total > s.view_h)

	gd.harness_key(&h, .End)
	testing.expect_value(t, s.scroll.offset, total - s.view_h)
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "tables too."))

	gd.harness_type(&h, "t") // new theme: laid out again, colors follow
	gd.harness_paint(&h)
	testing.expect_value(t, s.laid[1], 1)
	gd.frame_resize(&h.frame, 60, 6) // the harness has no resize helper
	gd.harness_send(&h, gd.Resize{60, 6})
	gd.harness_paint(&h)
	testing.expect_value(t, s.laid[0], 58)
}

@(test)
test_log :: proc(t: ^testing.T) {
	s: Log_State
	h: gd.Harness(Log_State, gd.No_Msg)
	gd.harness_init(&h, LOG_APP, &s, 50, 3)
	defer gd.harness_destroy(&h)

	gd.harness_type(&h, "ab") // the test runner collects the log lines
	testing.expect_value(t, s.keys, 2)
}

// ------------------------------------------------------------ the docs

COOKBOOK :: #load("../../docs/COOKBOOK.md", string)

// Every odin block in docs/COOKBOOK.md must appear, byte for byte, in one of
// this package's files. Edit the code here first, then paste it there.
@(test)
test_cookbook_snippets_are_real :: proc(t: ^testing.T) {
	OPEN :: "```odin\n"
	sources := #load_directory(".")
	rest := COOKBOOK
	blocks := 0
	for {
		at := strings.index(rest, OPEN)
		if at < 0 do break
		rest = rest[at + len(OPEN):]
		end := strings.index(rest, "```")
		if !testing.expect(t, end >= 0, "unclosed odin block") do return
		snippet := rest[:end]
		rest = rest[end + 3:]
		blocks += 1
		found := false
		for file in sources {
			if strings.has_suffix(file.name, ".odin") && strings.contains(string(file.data), snippet) {
				found = true
				break
			}
		}
		testing.expectf(t, found, "snippet %d is not in examples/cookbook:\n%s", blocks, snippet)
	}
	testing.expect(t, blocks >= 14, "expected a snippet per recipe")
}

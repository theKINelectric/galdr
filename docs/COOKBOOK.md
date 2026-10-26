# Galdr cookbook

Short recipes for common tasks. Each one says when to reach for it, shows
the code, and notes the catches.

Every snippet here is copied from `examples/cookbook`, which is compiled
with `-vet -strict-style` and tested. A test in that package fails if a
snippet below no longer matches the code. To try a recipe:

```sh
odin run examples/cookbook -collection:galdr=. -- clock
odin run examples/cookbook -collection:galdr=.          # lists the recipes
```

Snippets use `import gd "galdr:galdr"`. For the app model (`boot`, `react`,
`paint`, effects through `^Fx`), read the README first.

## Contents

1. [A clock or periodic tick](#1-a-clock-or-periodic-tick)
2. [Background work](#2-background-work)
3. [Splitting the screen](#3-splitting-the-screen)
4. [Key bindings and help hints](#4-key-bindings-and-help-hints)
5. [Focus between parts](#5-focus-between-parts)
6. [Mouse zones](#6-mouse-zones)
7. [A list and a text input](#7-a-list-and-a-text-input)
8. [A confirm dialog and toasts](#8-a-confirm-dialog-and-toasts)
9. [A validated form](#9-a-validated-form)
10. [Themes](#10-themes)
11. [Inline mode](#11-inline-mode)
12. [Markdown](#12-markdown)
13. [Testing with the Harness](#13-testing-with-the-harness)
14. [Logging and diagnostics](#14-logging-and-diagnostics)

## 1. A clock or periodic tick

When you want something to happen every N milliseconds.

```odin
Clock_Tick :: struct {}

clock_boot :: proc(s: ^Clock_State, fx: ^gd.Fx(Clock_Tick)) {
	gd.after(fx, 1000, Clock_Tick{})
}

clock_react :: proc(s: ^Clock_State, ev: gd.Event(Clock_Tick), fx: ^gd.Fx(Clock_Tick)) {
	#partial switch e in ev {
	case Clock_Tick:
		s.seconds += 1
		gd.after(fx, 1000, Clock_Tick{}) // after fires once: re-arm it
	case gd.Key:
		if gd.is_char(e, 'q') do gd.quit(fx)
	}
}
```

`after` fires once, so the handler schedules the next tick. Ticks are
relative to when the previous one was handled, so they drift a little.
For a wall clock, read `time.now()` in `paint` and use the tick only to
trigger a repaint. When `Msg` is a union, convert the variant:
`gd.after(fx, 1000, Msg(Tick{}))`.

## 2. Background work

When you want slow work (a request, a file scan, a computation) off the UI
thread.

```odin
// count_primes runs on a worker thread. It must not touch the State:
// everything it needs comes in through data, everything it found goes out
// in the message it returns.
count_primes :: proc(data: rawptr) -> Work_Msg {
	below := int(uintptr(data))
	count := 0
	outer: for n in 2 ..< below {
		for d := 2; d * d <= n; d += 1 {
			if n % d == 0 do continue outer
		}
		count += 1
	}
	return Primes_Done{below, count}
}

work_react :: proc(s: ^Work_State, ev: gd.Event(Work_Msg), fx: ^gd.Fx(Work_Msg)) {
	#partial switch e in ev {
	case gd.Key:
		if gd.is_char(e, 'g') && !s.busy {
			s.busy = true
			gd.spawn(fx, count_primes, rawptr(uintptr(50_000)))
		}
		if gd.is_char(e, 'q') do gd.quit(fx)
	case Work_Msg:
		switch m in e {
		case Primes_Done:
			s.busy = false
			s.result = m
		}
	}
}
```

`spawn` runs the procedure on a worker thread (up to `gd.MAX_WORKERS` at a
time) and delivers its return value to `react` as a message. The worker
must not read or write your State. Pass what it needs through `data` (a
value packed into the pointer, as here, or a pointer to memory nobody else
touches until the result arrives). If the result holds a string or slice,
allocate it with `context.allocator` in the worker and free it in `react`.
The worker's temp allocator is freed as soon as it returns.

## 3. Splitting the screen

When you want a header, a footer, a sidebar and panes that follow the
window size.

```odin
layout_paint :: proc(s: ^Layout_State, f: ^gd.Frame) {
	th := f.theme
	area := gd.frame_bounds(f)
	header := gd.cut_top(&area, 1) // area loses its top row
	footer := gd.cut_bottom(&area, 1)
	gd.text(f, header.x, header.y, "header", gd.tone_pen(th, .Primary, .Solid))
	gd.text(f, footer.x, footer.y, "footer", gd.muted_pen(th))

	cols := gd.columns(area, {gd.fixed(20), gd.grow(2), gd.grow(1)}, gap = 1)
	right := gd.rows(cols[2], {gd.percent(30), gd.grow()})
	gd.panel(f, cols[0], "sidebar")
	main := gd.panel(f, cols[1], "main", .Secondary)
	gd.panel(f, right[0], "top", .Accent)
	gd.panel(f, right[1], "bottom", .Info)

	card := gd.center(main, 16, 3)
	gd.fill(f, card, {bg = th.raised})
	gd.text(f, gd.inset(card, 2, 1).x, card.y + 1, "centered", gd.text_pen(th))
}
```

`columns` and `rows` split a rect by `fixed(n)` cells, `percent(n)` of the
space, or `grow(weight)` shares of what is left, with `gap` cells between.
`cut_top`, `cut_bottom`, `cut_left` and `cut_right` take a pointer and
shrink the rect you pass. `inset(r, dx, dy)` pads a rect and `center(r, w, h)`
places a box of that size in the middle. `panel` returns its content rect,
inside the border. Widgets do not clip: wrap a block in
`gd.clip_scope(f, rect)` if its content may overflow.

## 4. Key bindings and help hints

When you want one table that handles keys and also writes the help bar, so
the two can't disagree.

```odin
KEY_BINDINGS := [?]gd.Binding(Key_Action){
	{action = .Up, keys = {"up", "k", "+"}, help = "more"},
	{action = .Down, keys = {"down", "j", "-"}, help = "less"},
	{action = .Save, keys = {"ctrl+s"}, help = "save", disabled = true},
	{action = .Quit, keys = {"q", "ctrl+c"}, help = "quit"},
}
KEYMAP := gd.Keymap(Key_Action){KEY_BINDINGS[:]}
```

```odin
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
```

Specs are `"q"`, `"ctrl+s"`, `"alt+enter"`, `"shift+tab"`, `"space"`,
`"up"`, `"pgdown"`, `"f5"` and so on. The first key of a binding is the one
shown in help; a binding with `help = ""` works but is not shown.
`keymap_enable` changes the binding table the Keymap points at, so a global
Keymap is shared state. Pass the enum type explicitly
(`Key_Action.Save`): Odin can't infer `.Save` through the generic parameter.
Give text inputs the key before the keymap, or typing `q` quits.

## 5. Focus between parts

When Tab and Shift+Tab should move between panes.

```odin
Focus_State :: struct {
	ring:         gd.Focus_Ring(Focus_Part),
	details_open: bool,
}

focus_react :: proc(s: ^Focus_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	k, is_key := ev.(gd.Key)
	if !is_key do return
	if gd.focus_on_key(&s.ring, k) do return // Tab / Shift+Tab
	switch {
	case gd.is_char(k, 'q'):
		gd.quit(fx)
	case gd.is_char(k, 'd'):
		s.details_open = !s.details_open
		s.ring.skip = s.details_open ? {} : {.Details}
		// skip does not move focus off a part that just closed.
		if s.ring.current in s.ring.skip do gd.focus_prev(&s.ring)
	}
}

focus_paint :: proc(s: ^Focus_State, f: ^gd.Frame) {
	sizes := s.details_open ? []gd.Size{gd.fixed(3), gd.grow(), gd.grow()} : []gd.Size{gd.fixed(3), gd.grow()}
	parts := gd.rows(gd.frame_bounds(f), sizes)
	gd.panel(f, parts[0], "search", .Primary, s.ring.current == .Search)
	gd.panel(f, parts[1], "results", .Primary, s.ring.current == .Results)
	if s.details_open do gd.panel(f, parts[2], "details", .Primary, s.ring.current == .Details)
}
```

A `Focus_Ring` cycles through the values of an enum and skips the ones in
`skip`. Adding the current part to `skip` does not move focus off it, so
move it yourself, as above. `focus_on_key` consumes every Tab, so a part
that wants Tab for itself must get the key first.

## 6. Mouse zones

When you want clicks to land on things you drew.

```odin
mouse_paint :: proc(s: ^Mouse_State, f: ^gd.Frame) {
	x := 1
	for label, i in MOUSE_CHOICES {
		r := gd.button(f, x, 1, label, .Primary, .Soft, i == s.chosen)
		gd.zone(f, "choice", r, i) // name must outlive the frame: use a literal
		x += r.w + 1
	}
	gd.text(f, 1, 3, fmt.tprintf("wheel %d", s.wheel), gd.muted_pen(f.theme))
}

mouse_react :: proc(s: ^Mouse_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	#partial switch e in ev {
	case gd.Mouse:
		switch {
		case e.action == .Press && e.button == .Left && gd.in_zone(e, "choice"):
			s.chosen = e.zone.index
		case e.button == .Wheel_Up:
			s.wheel += 1
		case e.button == .Wheel_Down:
			s.wheel -= 1
		}
	case gd.Key:
		if gd.is_char(e, 'q') do gd.quit(fx)
	}
}
```

Register a zone in `paint` with a name and an optional index. In `react`,
the engine has already looked up the topmost zone under the pointer, so
`m.zone.name`, `m.zone.index` and `m.local` (the position inside the zone)
are ready. Hit tests use the zones of the last painted frame. The name must
outlive the frame; use a string literal. Zones registered later win, so a
dialog painted last gets the click. Wheel events come as `Wheel_Up` and
`Wheel_Down` buttons. Inline mode does not capture the mouse, and
`Options.no_mouse` turns it off in fullscreen.

## 7. A list and a text input

When you want a selectable list, a one-line input, or both.

```odin
todo_react :: proc(s: ^Todo_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	#partial switch e in ev {
	case gd.Key:
		switch {
		case e.code == .Escape, gd.is_ctrl(e, 'c'):
			gd.quit(fx)
		case e.code == .Enter:
			item := strings.trim_space(gd.field_text(&s.input)) // temp allocated
			if item != "" {
				append(&s.items, strings.clone(item))
				s.list.cursor = len(s.items) - 1
			}
			gd.field_clear(&s.input)
		case e.code == .Up, e.code == .Down:
			gd.pick_on_key(&s.list, e, len(s.items))
		case:
			gd.field_on_key(&s.input, e)
		}
	case gd.Paste:
		gd.field_insert(&s.input, e.text)
	}
}

todo_paint :: proc(s: ^Todo_State, f: ^gd.Frame) {
	area := gd.frame_bounds(f)
	input := gd.cut_bottom(&area, 1)
	gd.pick_draw(f, area, &s.list, s.items[:])
	gd.field_draw(f, input, &s.input)
}
```

`Pick_List` holds only a cursor and a scroll offset; you keep the items and
pass their count. `pick_on_key` also takes `j`, `k`, `g` and `G`, so when a
text field is on the same screen, send it only the arrow keys. `field_text`
returns a temp string: clone it to keep it. `Paste.text` is only valid
during that `react` call, and `field_insert` copies it. Free the field with
`field_destroy` when you are done.

## 8. A confirm dialog and toasts

When you want to ask before doing something, and say that it was done.

```odin
confirm_react :: proc(s: ^Confirm_State, ev: gd.Event(Repaint), fx: ^gd.Fx(Repaint)) {
	#partial switch e in ev {
	case gd.Key:
		if s.asking {
			switch {
			case gd.is_char(e, 'y'), e.code == .Enter:
				s.asking = false
				s.files -= 1
				ms := gd.toast(&s.toasts, fx.now_ms, .Success, "file deleted")
				gd.after(fx, ms, Repaint{}) // repaint when it expires
			case gd.is_char(e, 'n'), e.code == .Escape:
				s.asking = false
			}
			return // the dialog swallows every key while it is open
		}
		if gd.is_char(e, 'd') && s.files > 0 do s.asking = true
		if gd.is_char(e, 'q') do gd.quit(fx)
	case gd.Mouse:
		// The backdrop zone covers the screen; the dialog's zone sits above it.
		if s.asking && e.action == .Press && gd.in_zone(e, "backdrop") do s.asking = false
	}
}

confirm_paint :: proc(s: ^Confirm_State, f: ^gd.Frame) {
	th := f.theme
	gd.text(f, 1, 1, fmt.tprintf("%d files · d delete · q quit", s.files), gd.text_pen(th))
	if s.asking {
		inner := gd.modal(f, 36, 5, "Delete file?", .Danger, "y yes · n no")
		gd.paragraph(f, inner, "This cannot be undone.", gd.text_pen(th))
	}
	gd.toasts_draw(f, &s.toasts) // last: toasts sit above everything
}
```

`modal` dims what was painted before it, draws a centered panel and returns
its content rect. It also registers a full-screen `"backdrop"` zone and a
`"modal"` zone over the dialog, so a click outside is easy to detect. Paint
the dialog last so it is on top, and swallow keys in `react` while it is
open. Toasts are pruned when they are drawn, and only a repaint draws them,
so schedule a message for when one expires: `toast` returns its lifetime in
milliseconds for exactly that.

## 9. A validated form

When you want labeled fields with validation and a submit.

```odin
check_email :: proc(v: string) -> string {
	if v == "" do return "" // optional: only check what was typed
	at := strings.index_byte(v, '@')
	if at <= 0 || !strings.contains(v[at:], ".") do return "not an email address"
	return ""
}

signup_boot :: proc(s: ^Signup_State, fx: ^gd.Fx(gd.No_Msg)) {
	s.fields = {
		{label = "Name", kind = .Text, required = true},
		{label = "Email", kind = .Text, validate = check_email, help = "for receipts"},
		{label = "Plan", kind = .Choice, choices = PLANS[:]},
		{label = "Newsletter", kind = .Toggle},
	}
	s.form.fields = s.fields[:] // the form edits the fields in place
}
```

```odin
signup_react :: proc(s: ^Signup_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	#partial switch e in ev {
	case gd.Key:
		switch gd.form_on_key(&s.form, e) {
		case .Submitted:
			delete(s.welcome)
			s.welcome = fmt.aprintf("welcome, %s (%s)", gd.form_value(&s.form, 0), gd.form_value(&s.form, 2))
		case .Canceled:
			gd.quit(fx)
		case .None:
		}
	case gd.Paste:
		fl := &s.form.fields[s.form.focus]
		if fl.kind == .Text do gd.field_insert(&fl.input, e.text)
	}
}
```

```odin
signup_paint :: proc(s: ^Signup_State, f: ^gd.Frame) {
	inner := gd.panel(f, gd.frame_bounds(f), "sign up", .Primary, true, "⏎ next · ctrl+s submit · esc quit")
	used := gd.form_draw(f, inner, &s.form)
	if s.welcome != "" do gd.text(f, inner.x, inner.y + used, s.welcome, {fg = f.theme.tones[.Success]})
}
```

A validator returns `""` for a good value, or a short message.
`required` only applies to text fields. Tab, Shift+Tab and the arrows move
between fields, Space toggles, Left and Right pick a choice, and Enter on
the last field or `ctrl+s` submits. On a failed submit the form moves focus
to the first bad field and shows the error under it. Keep the fields in
your State and point `form.fields` at them; don't copy a `Form_Field` after
it has an error, since the error text lives in the field's own buffer.
`form_value` is a temp string. Free with `form_destroy`.

## 10. Themes

When you want to switch themes at runtime or ship your own.

```odin
	case gd.is_char(k, 't'):
		s.index = (s.index + 1) % gd.THEME_COUNT
		gd.set_theme(fx, gd.theme_by_index(s.index)) // applies at the next paint
	case gd.is_char(k, 'h'):
		gd.set_theme(fx, harbor_theme())
```

```odin
// harbor_theme starts from a built-in theme and changes a few slots.
harbor_theme :: proc() -> gd.Theme {
	th := gd.theme_nightfall()
	th.name = "harbor"
	th.corners = .Thick
	th.tones[.Primary] = gd.hex("#ff8c42")
	th.on_tone[.Primary] = gd.hex("#1a0f08") // text drawn on a Solid primary fill
	th.tones[.Accent] = gd.hex("#7ee0c3")
	th.on_tone[.Accent] = gd.hex("#07101f")
	return th
}
```

Draw with a Tone (what it means) and a Variant (how loud it is), never raw
colors, and every widget follows the theme:

```odin
	gd.text(f, 1, y + 1, " solid ", gd.tone_pen(th, .Accent, .Solid))
	gd.text(f, 9, y + 1, "ghost", gd.tone_pen(th, .Accent, .Ghost))
```

```odin
	// Pin the first theme so s.index matches it. Left unset, run picks a
	// built-in theme that suits the terminal's background.
	return gd.run(THEME_APP, &s, {theme = gd.theme_by_index(0)})
```

The built-in themes are `nightfall`, `daybreak`, `ember`, `synth` and `moss`
(`theme_by_index`, `theme_by_name`, `THEME_COUNT`). If `Options.theme` is
left unset, `run` picks one that suits the terminal's background, so track
the theme you set rather than assuming index 0. A custom theme must also set
`on_tone` for any tone you change; `gd.contrast_ratio` helps pick it.

## 11. Inline mode

When you want a small prompt or picker under the shell prompt instead of
taking over the screen.

```odin
inline_run :: proc() -> gd.Run_Error {
	s := Pick_State{picked = -1}
	err := gd.run(PICK_APP, &s, {inline = true, height = 6})
	if err != .None do return err
	if s.picked < 0 do os.exit(1) // canceled
	fmt.println(FLAVORS[s.picked]) // the terminal is ours again: stdout is safe
	return .None
}
```

`Options.inline` draws `height` rows (10 if unset) below the cursor, and
the frame is that tall and as wide as the terminal. By default the region
is erased on exit; set `keep = true` to leave the last frame on screen.
Inline mode does not use the alternate screen and does not capture the
mouse. Print results only after `run` returns. `run` fails with
`.No_Terminal` or `.Dumb_Terminal` when there is no usable terminal, so
have a fallback for scripts.

## 12. Markdown

When you want to show a README, help text or release notes.

```odin
Doc_State :: struct {
	doc:    gd.Md_Doc, // owned
	laid:   [2]int,    // (width, theme) the doc was laid out for
	scroll: gd.Scroll_View,
	view_h: int,
	themes: int,
}

doc_paint :: proc(s: ^Doc_State, f: ^gd.Frame) {
	area := gd.inset(gd.frame_bounds(f), 1)
	key := [2]int{area.w, s.themes}
	if s.doc.lines == nil || s.laid != key {
		// Colors and wrapping are baked in: re-render on resize or theme change.
		gd.md_destroy(&s.doc)
		s.doc = gd.md_render(NOTES, area.w - 1, f.theme) // leave a column for the scrollbar
		s.laid = key
	}
	s.view_h = area.h
	gd.scroll_draw(f, area, &s.scroll, s.doc.lines)
}
```

```odin
doc_run :: proc() -> gd.Run_Error {
	s: Doc_State
	defer gd.md_destroy(&s.doc)
	return gd.run(DOC_APP, &s)
}
```

`md_render` returns an `Md_Doc` that owns its lines and a copy of the
source. Wrapping and colors are fixed at render time, so render again when
the width or the theme changes, and call `md_destroy` on the old one. The
lines work with `scroll_draw`, `scroll_on_key` and `scroll_on_mouse`, or
with `Search` for `/`, `n` and `N`. `md_lines` is the borrowing form: its
lines point into the source you pass.

## 13. Testing with the Harness

When you want to test an app without a terminal.

```odin
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
```

`harness_init` boots the app and sends a `Resize`. `harness_advance` moves
virtual time and fires timers in order, so a minute of ticks takes no time.
Spawned tasks run synchronously, so their results have arrived by the time
the send returns. `harness_snapshot` paints and returns the screen as text
with trailing spaces trimmed; `harness_paint` returns the `Frame` so you can
check cells and pens with `gd.cell_at` and `gd.row_text`.

For clicks, paint first, then find the zone:

```odin
	gd.harness_paint(&h) // clicks resolve against the last paint
	blue: gd.Zone
	for z in h.engine.zones do if z.name == "choice" && z.index == 2 do blue = z
	gd.harness_click(&h, blue.rect.x + 1, blue.rect.y)
	testing.expect_value(t, s.chosen, 2)
```

`harness_key`, `harness_type` and `harness_click` cover the common events;
`harness_send` takes any event, including `gd.Paste` and your own messages.
`h.engine.quit` tells you whether the app asked to quit, and
`h.engine.theme` is the current theme. The harness frame does not follow a
`Resize` you send; call `gd.frame_resize(&h.frame, w, h)` first.

## 14. Logging and diagnostics

When you want to see what the app is doing without breaking the screen.

```odin
log_react :: proc(s: ^Log_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	#partial switch e in ev {
	case gd.Key:
		s.keys += 1
		log.infof("key %s (#%d)", gd.key_name(e), s.keys) // never fmt.println here
		if gd.is_char(e, 'q') do gd.quit(fx)
	case gd.Resize:
		log.debugf("resize %dx%d", e.w, e.h) // Debug level: only with GALDR_TRACE=1
	}
}
```

```sh
GALDR_LOG=/tmp/app.log odin run examples/cookbook -collection:galdr=. -- log
tail -f /tmp/app.log                # in another terminal
GALDR_LOG=/tmp/app.log GALDR_TRACE=1 ...   # also Debug level and every loop iteration
```

While `run` is active, anything written to the terminal corrupts the UI, so
use `core:log`, not `fmt.println`. With `GALDR_LOG=path`, `run` points
`context.logger` at that file for the whole session, yours and Galdr's
lines alike, including what the terminal reported about itself. Without
it, `run` keeps your `context.logger`. Odin's default logger discards
everything, but a console logger you set up yourself would write over the
screen. The level is Info, or Debug with `GALDR_TRACE=1`. Under
`odin test`, the test runner shows the same log lines.

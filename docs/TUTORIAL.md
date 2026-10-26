# Tutorial: your first Galdr app

This tutorial builds a small task list in about 180 lines. Along the way it
covers everything most apps need: state, keys, layout, a list, a text input, a
timer, work on a background thread, and a headless test.

```
╭─ tasks · 1 of 3 done ────────────────────────────────────────╮
│   ☐ Water the plants                                         │
│ ▌ ☑ Read chapter 3                                           │
│   ☐ Call the bank                                            │
│                                                              │
│ › Buy br                                                     │
╰──────────────────────────────────────────────────────── 12s ─╯
 enter add · esc cancel                                   ready
```

The finished program is `examples/tutorial/main.odin`, and its tests are in
`examples/tutorial/tutorial_test.odin`. Every snippet below is copied from
those files, and CI checks that they still match, so what you read here
compiles.

## 0. Set up

Odin has no package manager. Put Galdr next to your project (a git submodule
works well) and tell the compiler where it lives with a collection:

```sh
git submodule add https://github.com/theKINelectric/galdr vendor/galdr
odin run . -collection:galdr=vendor/galdr
```

In your code, import it once. This tutorial uses the `gd` prefix:

```odin
import gd "galdr:galdr"
```

To follow along inside this repository instead, run the finished app with
`odin run examples/tutorial -collection:galdr=.`. Pass a file name after
`--` to let `s` save to it.

## 1. State and messages

A Galdr app is your own `State` struct plus three procedures. Start with the
data:

```odin
Task :: struct {
	title: string,
	done:  bool,
}

State :: struct {
	tasks:   [dynamic]Task,
	list:    gd.Pick_List,
	input:   gd.Text_Field,
	adding:  bool,   // the input line has focus
	seconds: int,    // time since start, from the clock
	status:  string, // last message in the footer
	path:    string, // where `s` saves; empty = don't save
}
```

`Pick_List` and `Text_Field` are Galdr components. They are plain structs that
live inside your state, and you draw them and feed them keys yourself.

Your app also has its own message type. Messages are how timers and background
work talk back to you:

```odin
Tick  :: struct {}
Saved :: struct { ok: bool, count: int }
Msg   :: union { Tick, Saved }
```

## 2. Boot

`boot` runs once, before the first paint. It fills in the starting state and
can ask for effects:

```odin
boot :: proc(s: ^State, fx: ^gd.Fx(Msg)) {
	for title in ([]string{"Water the plants", "Read chapter 3", "Call the bank"}) {
		append(&s.tasks, Task{title = strings.clone(title)})
	}
	s.input.placeholder = "What needs doing?"
	s.status = "ready"
	gd.after(fx, 1000, Tick{})
}
```

`gd.after(fx, 1000, Tick{})` doesn't wait. It records a request, and a second
later the engine delivers `Tick{}` to `react`. Nothing in `boot`, `react` or
`paint` ever blocks. This is what keeps the UI responsive, and it's also what
makes the app testable without a terminal (step 6).

The titles are cloned because the state keeps them. Anything you keep in state
uses `context.allocator` and is yours to free (see `destroy` at the end).

## 3. React

`react` runs for every event: keys, mouse, resize, paste, focus, and your own
messages. It changes the state and may ask for more effects.

```odin
react :: proc(s: ^State, ev: gd.Event(Msg), fx: ^gd.Fx(Msg)) {
	#partial switch e in ev {
	case gd.Key:
		if s.adding {
			on_key_adding(s, e)
		} else {
			on_key_list(s, e, fx)
		}
	case Msg:
		switch m in e {
		case Tick:
			s.seconds += 1
			gd.after(fx, 1000, Tick{}) // re-arm: after fires once
		case Saved:
			s.status = m.ok ? "saved" : "save failed"
		}
	}
}
```

`Event(Msg)` is a union of Galdr's input events and your `Msg`. A clock is
just a timer that re-arms itself each time it fires.

The list gets keys first. `pick_on_key` handles ↑/↓, `j`/`k`, Home, End and
paging, and returns `true` when it used the key:

```odin
on_key_list :: proc(s: ^State, k: gd.Key, fx: ^gd.Fx(Msg)) {
	if gd.pick_on_key(&s.list, k, len(s.tasks)) do return
	switch {
	case gd.is_char(k, 'q'), gd.is_ctrl(k, 'c'):
		gd.quit(fx)
	case gd.is_char(k, ' '), k.code == .Enter:
		if len(s.tasks) > 0 do s.tasks[s.list.cursor].done = !s.tasks[s.list.cursor].done
	case gd.is_char(k, 'a'):
		s.adding = true
```

While the input line is open, keys go to the `Text_Field` instead. It already
knows the readline keys (Ctrl-A, Ctrl-E, Alt-←, and so on), and it moves over
emoji and accented letters as single characters:

```odin
on_key_adding :: proc(s: ^State, k: gd.Key) {
	switch {
	case k.code == .Enter:
		title := strings.trim_space(gd.field_text(&s.input))
		if title != "" {
			append(&s.tasks, Task{title = strings.clone(title)})
			s.list.cursor = len(s.tasks) - 1
		}
		gd.field_clear(&s.input)
		s.adding = false
	case k.code == .Escape:
		gd.field_clear(&s.input)
		s.adding = false
	case:
		gd.field_on_key(&s.input, k)
	}
}
```

Focus is just a `bool` here. With more than two focusable parts, use
`Focus_Ring` (see `docs/COOKBOOK.md`).

## 4. Paint

`paint` draws the whole screen from the state, every time. It never changes
the state. Galdr compares each frame with the previous one and sends only the
cells that changed, so painting everything is cheap.

```odin
paint :: proc(s: ^State, f: ^gd.Frame) {
	th := f.theme
	screen := gd.frame_bounds(f)
	footer := gd.cut_bottom(&screen, 1)

	done := 0
	for t in s.tasks do done += int(t.done)
	title := fmt.tprintf("tasks · %d of %d done", done, len(s.tasks))
	inner := gd.panel(f, screen, title, .Primary, !s.adding, fmt.tprintf("%ds", s.seconds))

	input_row := gd.cut_bottom(&inner, 1)
	gd.pick_draw_custom(f, inner, &s.list, len(s.tasks), draw_task, s, !s.adding)
	if s.adding {
		gd.field_draw(f, input_row, &s.input, true, .Secondary)
	}
```

Layout is rectangles. `cut_bottom(&screen, 1)` takes one row off the bottom of
`screen` and returns it, and `panel` draws a titled border and returns the
space inside it. `columns` and `rows` split a rect by `fixed`, `percent` and
`grow` sizes when you need more than this.

Strings made with `fmt.tprintf` live in the temporary allocator, which Galdr
clears after every frame. You never free them.

`pick_draw_custom` handles the selection bar and scrolling, and calls
`draw_task` for each visible row:

```odin
draw_task :: proc(f: ^gd.Frame, row: gd.Rect, i: int, selected: bool, user: rawptr) {
	s := (^State)(user)
	t := s.tasks[i]
	gd.checkbox(f, row.x, row.y, t.done, gd.truncate(t.title, row.w - 4), .Success, selected)
}
```

Colors come from the theme. `.Primary`, `.Secondary` and `.Success` are
**tones**, and every component resolves them through the active theme, so
switching themes re-skins the whole app. The footer uses `help_bar`, which
drops hints that don't fit:

```odin
	hints := s.adding \
		? []gd.Key_Hint{{"enter", "add"}, {"esc", "cancel"}} \
		: []gd.Key_Hint{{"space", "toggle"}, {"a", "add"}, {"d", "delete"}, {"s", "save"}, {"q", "quit"}}
	gd.help_bar(f, footer.x + 1, footer.y, footer.w - 2, hints)
```

## 5. Background work

Writing a file can be slow, and `react` must not block. So `save` packs up
what the worker needs and hands it to `spawn`:

```odin
save :: proc(s: ^State, fx: ^gd.Fx(Msg)) {
	if s.path == "" {
		s.status = "no save path (run with a file name)"
		return
	}
	b := strings.builder_make()
	for t in s.tasks do fmt.sbprintf(&b, "[%s] %s\n", t.done ? "x" : " ", t.title)
	job := new(Save_Job)
	job^ = {path = s.path, text = strings.to_string(b), count = len(s.tasks)}
	s.status = "saving…"
	gd.spawn(fx, save_work, job, cancel = cancel_save)
}
```

The work procedure runs on a worker thread. Whatever it returns arrives in
`react` as a message, here `Saved`:

```odin
// save_work runs on a worker thread. It owns the job and frees it.
save_work :: proc(data: rawptr) -> Msg {
	job := (^Save_Job)(data)
	defer free(job)
	defer delete(job.text)
	err := os.write_entire_file(job.path, job.text)
	return Saved{ok = err == nil, count = job.count}
}
```

Two rules keep this safe:

- **Never touch `State` from the worker.** Copy what it needs into the job.
- **Decide who frees the job.** Here the worker does, because the UI thread has
  already moved on.

Quitting never waits for a task that's still running — and instant shutdown
does not mean all work has stopped. What happens to work that is still in
flight when the app quits is part of the contract:

- **A queued task never runs.** If the job was still waiting for a worker when
  the engine was destroyed, `work` is not called; the `cancel` callback you can
  pass to `spawn` receives the `data` pointer so you can free it. The tutorial
  app hands the job's ownership across completely:

```odin
	gd.spawn(fx, save_work, job, cancel = cancel_save)
```

```odin
// cancel_save frees a job that never ran (the app quit while it was queued).
cancel_save :: proc(data: rawptr) {
	job := (^Save_Job)(data)
	delete(job.text)
	free(job)
}
```

- **A started task is not interrupted.** It finishes on its own against the
  (reference-counted) hub. Its result message cannot reach the app anymore, so
  if results own memory, declare a `drop` on the app; it receives every result
  the app will never react to (undelivered at shutdown, completed after close,
  or dropped because the engine quit mid-drain). It can run on a worker
  thread — keep it quick, and don't touch `State` from it. The tutorial's
  `Saved` owns nothing, but the declaration site is the same:

```odin
// drop_result disposes of a save result the app will never react to (it quit
// while the save was still running). Saved owns nothing, but this is where
// owned data would be freed.
drop_result :: proc(m: Msg) {
	if s, ok := m.(Saved); ok do _ = s
}
```

```odin
	app := gd.App(State, Msg){boot = boot, react = react, paint = paint, drop = drop_result}
```
- **Worker data must outlive the state it references.** Workers cannot see
  your `State`; that is the point of copying into a job.

The worker pool is bounded (`MAX_WORKERS`), but the queue itself is not: a task
that submits work faster than workers finish it grows memory. Queue admission
and backpressure are the application's policy.

## 6. Test it without a terminal

`Harness` runs the same app headlessly. Keys are sent directly, time is virtual,
and spawned tasks run synchronously, so results are deterministic. A snapshot
is the screen as plain text.

```odin
@(test)
test_tasks :: proc(t: ^testing.T) {
	s: State
	defer destroy(&s)
	h: gd.Harness(State, Msg)
	gd.harness_init(&h, gd.App(State, Msg){boot = boot, react = react, paint = paint}, &s, 60, 12)
	defer gd.harness_destroy(&h)

	screen := gd.harness_snapshot(&h)
	testing.expect(t, strings.contains(screen, "0 of 3 done"), screen)

	// Toggle the second task.
	gd.harness_key(&h, .Down)
	gd.harness_type(&h, " ")
	testing.expect(t, s.tasks[1].done)
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "1 of 3 done"))
```

Three seconds of clock take no real time at all:

```odin
	// The clock runs on virtual time.
	gd.harness_advance(&h, 3000)
	testing.expect_value(t, s.seconds, 3)
```

Run the tests with `odin test examples/tutorial -collection:galdr=.`. Odin's
test runner tracks memory, so a missing `delete` shows up as a failure.

## 7. Run it

`main` starts the engine, and `destroy` frees what the state owns:

```odin
destroy :: proc(s: ^State) {
	for t in s.tasks do delete(t.title)
	delete(s.tasks)
	gd.field_destroy(&s.input)
}

main :: proc() {
	s: State
	if len(os.args) > 1 do s.path = os.args[1]
	app := gd.App(State, Msg){boot = boot, react = react, paint = paint, drop = drop_result}
	if err := gd.run(app, &s, {title = "tasks"}); err != .None {
		fmt.eprintln("tutorial: cannot start:", err)
	}
	destroy(&s)
}
```

`run` takes over the screen, and gives it back on quit, on Ctrl-Z, and on a
crash. `Options` changes that behaviour: `inline = true` draws under the prompt
instead, like a picker, and `no_mouse`, `theme` and `title` do what they say.

## Where next

- `docs/COOKBOOK.md`: short recipes for keymaps, focus, mouse zones,
  dialogs, forms, themes, inline mode, markdown and logging.
- `docs/API.md`: naming, argument order, memory rules and what's stable.
- `examples/mission`: a large app that uses nearly every component.
- `docs/CLI.md`: the `galdr` command for shell scripts.

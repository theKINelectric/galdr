package tutorial

// The app built step by step in docs/TUTORIAL.md: a small task list.
//   odin run examples/tutorial -collection:galdr=.
// Every snippet in the tutorial is an excerpt of this file.

import gd "galdr:galdr"
import "core:fmt"
import "core:os"
import "core:strings"

// ---- step 1: state and messages

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

Tick  :: struct {}
Saved :: struct { ok: bool, count: int }
Msg   :: union { Tick, Saved }

// ---- step 2: boot

boot :: proc(s: ^State, fx: ^gd.Fx(Msg)) {
	for title in ([]string{"Water the plants", "Read chapter 3", "Call the bank"}) {
		append(&s.tasks, Task{title = strings.clone(title)})
	}
	s.input.placeholder = "What needs doing?"
	s.status = "ready"
	gd.after(fx, 1000, Tick{})
}

// ---- step 3: react

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

on_key_list :: proc(s: ^State, k: gd.Key, fx: ^gd.Fx(Msg)) {
	if gd.pick_on_key(&s.list, k, len(s.tasks)) do return
	switch {
	case gd.is_char(k, 'q'), gd.is_ctrl(k, 'c'):
		gd.quit(fx)
	case gd.is_char(k, ' '), k.code == .Enter:
		if len(s.tasks) > 0 do s.tasks[s.list.cursor].done = !s.tasks[s.list.cursor].done
	case gd.is_char(k, 'a'):
		s.adding = true
	case gd.is_char(k, 'd'):
		if len(s.tasks) > 0 {
			delete(s.tasks[s.list.cursor].title)
			ordered_remove(&s.tasks, s.list.cursor)
			gd.pick_move(&s.list, 0, len(s.tasks)) // keep the cursor in range
		}
	case gd.is_char(k, 's'):
		save(s, fx)
	}
}

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

// ---- step 5: background work

Save_Job :: struct {
	path:  string,
	text:  string,
	count: int,
}

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

// cancel_save frees a job that never ran (the app quit while it was queued).
cancel_save :: proc(data: rawptr) {
	job := (^Save_Job)(data)
	delete(job.text)
	free(job)
}

// drop_result disposes of a save result the app will never react to (it quit
// while the save was still running). Saved owns nothing, but this is where
// owned data would be freed.
drop_result :: proc(m: Msg) {
	if s, ok := m.(Saved); ok do _ = s
}

// save_work runs on a worker thread. It owns the job and frees it.
save_work :: proc(data: rawptr) -> Msg {
	job := (^Save_Job)(data)
	defer free(job)
	defer delete(job.text)
	err := os.write_entire_file(job.path, job.text)
	return Saved{ok = err == nil, count = job.count}
}

// ---- step 4: paint

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

	hints := s.adding \
		? []gd.Key_Hint{{"enter", "add"}, {"esc", "cancel"}} \
		: []gd.Key_Hint{{"space", "toggle"}, {"a", "add"}, {"d", "delete"}, {"s", "save"}, {"q", "quit"}}
	gd.help_bar(f, footer.x + 1, footer.y, footer.w - 2, hints)
	status_w := gd.text_width(s.status)
	gd.text(f, footer.x + footer.w - status_w - 1, footer.y, s.status, gd.muted_pen(th))
}

draw_task :: proc(f: ^gd.Frame, row: gd.Rect, i: int, selected: bool, user: rawptr) {
	s := (^State)(user)
	t := s.tasks[i]
	gd.checkbox(f, row.x, row.y, t.done, gd.truncate(t.title, row.w - 4), .Success, selected)
}

// ---- running it

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

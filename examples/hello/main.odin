package hello

// The smallest galdr app: a counter with a heartbeat.
//   odin run examples/hello -collection:galdr=.

import gd "galdr:galdr"
import "core:fmt"

State :: struct {
	count: int,
	beats: int,
}

Beat :: struct {}

boot :: proc(s: ^State, fx: ^gd.Fx(Beat)) {
	gd.after(fx, 500, Beat{})
}

react :: proc(s: ^State, ev: gd.Event(Beat), fx: ^gd.Fx(Beat)) {
	switch e in ev {
	case gd.Key:
		switch {
		case gd.is_char(e, 'q'), e.code == .Escape, gd.is_ctrl(e, 'c'): gd.quit(fx)
		case e.code == .Up, gd.is_char(e, '+'), gd.is_char(e, 'k'):    s.count += 1
		case e.code == .Down, gd.is_char(e, '-'), gd.is_char(e, 'j'):  s.count -= 1
		}
	case Beat:
		s.beats += 1
		gd.after(fx, 500, Beat{})
	case gd.Mouse, gd.Resize, gd.Paste, gd.Focus:
	}
}

paint :: proc(s: ^State, f: ^gd.Frame) {
	th := f.theme
	card := gd.center(gd.frame_bounds(f), 36, 9)
	inner := gd.block(f, card, {
		border = th.corners, border_pen = {fg = th.tones[.Primary]}, fill = th.surface,
		title = "counter", title_pen = gd.tone_pen(th, .Primary, .Solid),
		pad_x = 2, pad_y = 1,
	})
	value := fmt.tprintf("%d", s.count)
	gd.text_aligned(f, inner.x, inner.y, inner.w, value, {fg = th.ink, attrs = {.Bold}}, .Center)
	heart := s.beats % 2 == 0 ? "♥" : "♡"
	gd.text_aligned(f, inner.x, inner.y + 2, inner.w, heart, {fg = th.tones[.Danger]}, .Center)
	gd.text_aligned(f, inner.x, inner.y + 4, inner.w, "↑/↓ change · q quit", gd.muted_pen(th), .Center)
}

main :: proc() {
	state: State
	app := gd.App(State, Beat){boot = boot, react = react, paint = paint}
	if err := gd.run(app, &state, {title = "galdr hello"}); err != .None {
		fmt.eprintln("hello: cannot start:", err)
	}
}

package cookbook

// Recipe: mouse input through zones registered in paint.

import gd "galdr:galdr"
import "core:fmt"

MOUSE_CHOICES := [?]string{"red", "green", "blue"}

Mouse_State :: struct {
	chosen: int,
	wheel:  int,
}

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

MOUSE_APP :: gd.App(Mouse_State, gd.No_Msg){react = mouse_react, paint = mouse_paint}

mouse_run :: proc() -> gd.Run_Error {
	s: Mouse_State
	return gd.run(MOUSE_APP, &s)
}

package cookbook

// Recipe: a modal confirm dialog, and toasts that expire on their own.

import gd "galdr:galdr"
import "core:fmt"

Confirm_State :: struct {
	asking: bool,
	files:  int,
	toasts: gd.Toasts,
}

// Repaint carries no data: any message makes the engine paint again.
Repaint :: struct {}

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

confirm_boot :: proc(s: ^Confirm_State, fx: ^gd.Fx(Repaint)) {
	s.files = 3
}

CONFIRM_APP :: gd.App(Confirm_State, Repaint){boot = confirm_boot, react = confirm_react, paint = confirm_paint}

confirm_run :: proc() -> gd.Run_Error {
	s: Confirm_State
	return gd.run(CONFIRM_APP, &s)
}

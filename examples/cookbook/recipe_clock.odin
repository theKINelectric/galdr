package cookbook

// Recipe: a clock, or any periodic tick, with `after`.

import gd "galdr:galdr"
import "core:fmt"

Clock_State :: struct {
	seconds: int,
}

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

clock_paint :: proc(s: ^Clock_State, f: ^gd.Frame) {
	label := fmt.tprintf("%02d:%02d", s.seconds / 60, s.seconds % 60)
	gd.text_aligned(f, 0, f.h / 2, f.w, label, gd.text_pen(f.theme), .Center)
}

CLOCK_APP :: gd.App(Clock_State, Clock_Tick){boot = clock_boot, react = clock_react, paint = clock_paint}

clock_run :: proc() -> gd.Run_Error {
	s: Clock_State
	return gd.run(CLOCK_APP, &s)
}

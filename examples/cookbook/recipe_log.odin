package cookbook

// Recipe: diagnostics with core:log. Run with GALDR_LOG=path to capture them.

import gd "galdr:galdr"
import "core:log"

Log_State :: struct {
	keys: int,
}

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

log_paint :: proc(s: ^Log_State, f: ^gd.Frame) {
	gd.text(f, 1, 1, "type keys; they go to $GALDR_LOG · q quit", gd.muted_pen(f.theme))
}

LOG_APP :: gd.App(Log_State, gd.No_Msg){react = log_react, paint = log_paint}

log_run :: proc() -> gd.Run_Error {
	s: Log_State
	return gd.run(LOG_APP, &s)
}

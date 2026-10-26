package cookbook

// Recipe: move focus between parts of the screen with a Focus_Ring.

import gd "galdr:galdr"

Focus_Part :: enum {
	Search,
	Results,
	Details,
}

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

focus_boot :: proc(s: ^Focus_State, fx: ^gd.Fx(gd.No_Msg)) {
	s.ring.skip = {.Details} // closed at start
}

FOCUS_APP :: gd.App(Focus_State, gd.No_Msg){boot = focus_boot, react = focus_react, paint = focus_paint}

focus_run :: proc() -> gd.Run_Error {
	s: Focus_State
	return gd.run(FOCUS_APP, &s)
}

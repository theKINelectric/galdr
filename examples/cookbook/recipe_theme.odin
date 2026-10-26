package cookbook

// Recipe: switch themes at runtime, draw with Tone/Variant pens, and make a
// custom theme.

import gd "galdr:galdr"

Theme_State :: struct {
	index: int,
}

theme_react :: proc(s: ^Theme_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	k, is_key := ev.(gd.Key)
	if !is_key do return
	switch {
	case gd.is_char(k, 't'):
		s.index = (s.index + 1) % gd.THEME_COUNT
		gd.set_theme(fx, gd.theme_by_index(s.index)) // applies at the next paint
	case gd.is_char(k, 'h'):
		gd.set_theme(fx, harbor_theme())
	case gd.is_char(k, 'q'):
		gd.quit(fx)
	}
}

theme_paint :: proc(s: ^Theme_State, f: ^gd.Frame) {
	th := f.theme
	gd.text(f, 1, 0, th.name, {fg = th.ink, attrs = {.Bold}})
	y := 2
	for v in gd.Variant {
		x := 1
		for t in ([]gd.Tone{.Primary, .Success, .Warning, .Danger}) {
			x += gd.badge(f, x, y, "ok", t, v) + 1
		}
		y += 1
	}
	gd.text(f, 1, y + 1, " solid ", gd.tone_pen(th, .Accent, .Solid))
	gd.text(f, 9, y + 1, "ghost", gd.tone_pen(th, .Accent, .Ghost))
	gd.text(f, 1, y + 3, "t next · h harbor · q quit", gd.muted_pen(th))
}

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

THEME_APP :: gd.App(Theme_State, gd.No_Msg){react = theme_react, paint = theme_paint}

theme_run :: proc() -> gd.Run_Error {
	s: Theme_State
	// Pin the first theme so s.index matches it. Left unset, run picks a
	// built-in theme that suits the terminal's background.
	return gd.run(THEME_APP, &s, {theme = gd.theme_by_index(0)})
}

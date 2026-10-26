package cookbook

// Recipe: split the screen with columns, rows, cut_*, inset and center.

import gd "galdr:galdr"

Layout_State :: struct {}

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

layout_react :: proc(s: ^Layout_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	if k, ok := ev.(gd.Key); ok && gd.is_char(k, 'q') do gd.quit(fx)
}

LAYOUT_APP :: gd.App(Layout_State, gd.No_Msg){react = layout_react, paint = layout_paint}

layout_run :: proc() -> gd.Run_Error {
	s: Layout_State
	return gd.run(LAYOUT_APP, &s)
}

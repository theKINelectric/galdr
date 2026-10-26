package cookbook

// Recipe: render markdown with md_render, scroll it, free it with md_destroy.

import gd "galdr:galdr"

NOTES :: `# Release notes

Galdr renders **bold**, *italic*, ` + "`code`" + ` and [links](https://example.com).

- lists, including
- [x] task lists

> quotes, rules, fenced code and pipe tables too.
`

Doc_State :: struct {
	doc:    gd.Md_Doc, // owned
	laid:   [2]int,    // (width, theme) the doc was laid out for
	scroll: gd.Scroll_View,
	view_h: int,
	themes: int,
}

doc_paint :: proc(s: ^Doc_State, f: ^gd.Frame) {
	area := gd.inset(gd.frame_bounds(f), 1)
	key := [2]int{area.w, s.themes}
	if s.doc.lines == nil || s.laid != key {
		// Colors and wrapping are baked in: re-render on resize or theme change.
		gd.md_destroy(&s.doc)
		s.doc = gd.md_render(NOTES, area.w - 1, f.theme) // leave a column for the scrollbar
		s.laid = key
	}
	s.view_h = area.h
	gd.scroll_draw(f, area, &s.scroll, s.doc.lines)
}

doc_react :: proc(s: ^Doc_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	#partial switch e in ev {
	case gd.Key:
		switch {
		case gd.is_char(e, 'q'):
			gd.quit(fx)
		case gd.is_char(e, 't'):
			s.themes += 1
			gd.set_theme(fx, gd.theme_by_index(s.themes))
		case:
			gd.scroll_on_key(&s.scroll, e, len(s.doc.lines), s.view_h)
		}
	case gd.Mouse:
		gd.scroll_on_mouse(&s.scroll, e, len(s.doc.lines), s.view_h)
	}
}

DOC_APP :: gd.App(Doc_State, gd.No_Msg){react = doc_react, paint = doc_paint}

doc_run :: proc() -> gd.Run_Error {
	s: Doc_State
	defer gd.md_destroy(&s.doc)
	return gd.run(DOC_APP, &s)
}

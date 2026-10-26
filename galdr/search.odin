package galdr

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Search inside a Scroll_View of styled lines: "/" to type a query, Enter to
// keep it, n / N for next / previous match, Esc to clear. Matches are
// case-insensitive and highlighted in place.

Search_Hit :: struct {
	line:  int,
	start: int, // rune index in the line's text
	count: int, // runes
}

Search :: struct {
	query:    Text_Field,
	typing:   bool,
	hits:     [dynamic]Search_Hit,
	current:  int,
	last:     string, // owned: query the hits belong to
	last_n:   int,
	computed: bool,
}

search_destroy :: proc(s: ^Search) {
	field_destroy(&s.query)
	delete(s.hits)
	delete(s.last)
}

// search_invalidate forces a recompute. Call it whenever the lines' content
// changes (even at the same line count) — search_update only notices a new
// query or a different line count on its own, like filter_invalidate.
search_invalidate :: proc(s: ^Search) {
	s.computed = false
}

// _line_runes returns the runes of a styled line as one string of text.
@(private)
_line_runes :: proc(l: Line) -> []rune {
	out := make([dynamic]rune, context.temp_allocator)
	for sp in l do for r in sp.text do append(&out, unicode.to_lower(r))
	return out[:]
}

// search_update recomputes the hits when the query, the line count, or the
// content (after search_invalidate) changed.
search_update :: proc(s: ^Search, lines: []Line) {
	q := field_text(&s.query)
	if s.computed && q == s.last && len(lines) == s.last_n do return
	delete(s.last)
	s.last = strings.clone(q)
	s.last_n = len(lines)
	s.computed = true
	clear(&s.hits)
	s.current = 0
	if len(q) == 0 do return
	needle := utf8.string_to_runes(strings.to_lower(q, context.temp_allocator), context.temp_allocator)
	for l, li in lines {
		hay := _line_runes(l)
		outer: for i := 0; i + len(needle) <= len(hay); i += 1 {
			for j in 0 ..< len(needle) do if hay[i + j] != needle[j] do continue outer
			append(&s.hits, Search_Hit{li, i, len(needle)})
			i += len(needle) - 1
		}
	}
}

// _search_reveal scrolls so the current hit is visible (a third from the top).
@(private)
_search_reveal :: proc(s: ^Search, sv: ^Scroll_View, total, visible: int) {
	if len(s.hits) == 0 do return
	line := s.hits[s.current].line
	if line < sv.offset || line >= sv.offset + visible {
		sv.offset = clamp(line - visible / 3, 0, max(total - visible, 0))
	}
}

// search_on_key handles search keys; returns true if it consumed k.
search_on_key :: proc(s: ^Search, k: Key, sv: ^Scroll_View, lines: []Line, visible: int) -> bool {
	if s.typing {
		switch {
		case k.code == .Enter:
			s.typing = false
		case k.code == .Escape:
			s.typing = false
			field_clear(&s.query)
			search_update(s, lines)
		case:
			if !field_on_key(&s.query, k) do return false
			search_update(s, lines)
			_search_reveal(s, sv, len(lines), visible)
		}
		return true
	}
	switch {
	case is_char(k, '/'):
		s.typing = true
		field_clear(&s.query)
	case is_char(k, 'n') && len(s.hits) > 0:
		s.current = (s.current + 1) % len(s.hits)
		_search_reveal(s, sv, len(lines), visible)
	case is_char(k, 'N') && len(s.hits) > 0:
		s.current = (s.current + len(s.hits) - 1) % len(s.hits)
		_search_reveal(s, sv, len(lines), visible)
	case k.code == .Escape && len(s.hits) > 0:
		field_clear(&s.query)
		search_update(s, lines)
	case:
		return false
	}
	return true
}

// search_draw draws the lines (like scroll_draw) with hits highlighted, and
// the query prompt on the last row while typing.
// The default tone is Warning (yellow in every theme), the conventional find
// color. Accent would collide with inline `code` in markdown, which uses it.
search_draw :: proc(f: ^Frame, r: Rect, s: ^Search, sv: ^Scroll_View, lines: []Line, tone: Tone = .Warning) {
	th := f.theme
	search_update(s, lines)
	view := r
	if s.typing do view.h -= 1
	scroll_draw(f, view, sv, lines)

	for hit, i in s.hits {
		row := hit.line - sv.offset
		if row < 0 || row >= view.h do continue
		// Walk the glyphs of the line to find the cells of runes [start, start+count).
		x := view.x
		ri := 0
		for sp in lines[hit.line] {
			for gi := 0; gi < len(sp.text); {
				glyph, gw, next, _ := next_glyph(sp.text, gi)
				gi = next
				n := utf8.rune_count_in_string(glyph)
				if ri >= hit.start && ri < hit.start + hit.count && x < view.x + view.w {
					c := cell_at(f, x, view.y + row)
					if c != nil {
						bg := i == s.current ? th.tones[tone] : soft_bg(th, tone, 0.45)
						c.pen.bg = bg
						if i == s.current do c.pen.fg = th.on_tone[tone]
					}
				}
				ri += n
				x += gw
			}
		}
	}

	if s.typing {
		y := r.y + r.h - 1
		label := len(s.hits) > 0 ? fmt_count(s.current + 1, len(s.hits)) : "no matches"
		field_draw(f, {r.x, y, r.w - text_width(label) - 1, 1}, &s.query, true, tone, "/ ")
		text(f, r.x + r.w - text_width(label), y, label, {fg = th.faint})
	}
}

// search_status is a short "3/12" label for a status bar ("" if no query).
search_status :: proc(s: ^Search) -> string {
	if len(s.last) == 0 do return ""
	if len(s.hits) == 0 do return "no matches"
	return fmt_count(s.current + 1, len(s.hits))
}

@(private)
fmt_count :: proc(a, b: int) -> string {
	return strings.concatenate({fmt_int(a), "/", fmt_int(b)}, context.temp_allocator)
}

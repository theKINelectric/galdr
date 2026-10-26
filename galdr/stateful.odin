package galdr

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// Stateful components. Each has a small state struct you keep in your model,
// an `*_on_key` (returns true if it consumed the key) and a draw proc.

// ------------------------------------------------------------ Pick_List

Pick_List :: struct {
	cursor: int,
	offset: int, // first visible row
}

pick_move :: proc(l: ^Pick_List, delta, count: int) {
	if count <= 0 {
		l.cursor = 0
		return
	}
	l.cursor = clamp(l.cursor + delta, 0, count - 1)
}

// pick_on_key handles ↑/↓/j/k/home/end/pgup/pgdn. page = visible rows.
pick_on_key :: proc(l: ^Pick_List, k: Key, count: int, page := 10) -> bool {
	switch {
	case k.code == .Up, is_char(k, 'k'), is_ctrl(k, 'p'):     pick_move(l, -1, count)
	case k.code == .Down, is_char(k, 'j'), is_ctrl(k, 'n'):   pick_move(l, 1, count)
	case k.code == .Home, is_char(k, 'g'):                    pick_move(l, -count, count)
	case k.code == .End, is_char(k, 'G'):                     pick_move(l, count, count)
	case k.code == .Page_Up:                                  pick_move(l, -page, count)
	case k.code == .Page_Down:                                pick_move(l, page, count)
	case:                                                     return false
	}
	return true
}

// pick_scroll keeps the cursor visible within `visible` rows.
pick_scroll :: proc(l: ^Pick_List, count, visible: int) {
	if visible <= 0 do return
	l.cursor = clamp(l.cursor, 0, max(count - 1, 0))
	if l.cursor < l.offset do l.offset = l.cursor
	if l.cursor >= l.offset + visible do l.offset = l.cursor - visible + 1
	l.offset = clamp(l.offset, 0, max(count - visible, 0))
}

// pick_hit maps a mouse row inside r to an item index (or -1).
pick_hit :: proc(l: ^Pick_List, r: Rect, m: Mouse, count: int) -> int {
	if !rect_contains(r, m.x, m.y) do return -1
	i := l.offset + (m.y - r.y)
	return i < count ? i : -1
}

Item_Painter :: #type proc(f: ^Frame, row: Rect, index: int, selected: bool, user: rawptr)

// pick_list_custom draws `count` rows with your painter plus selection bar.
pick_draw_custom :: proc(f: ^Frame, r: Rect, l: ^Pick_List, count: int, painter: Item_Painter, user: rawptr = nil, focused := true, tone: Tone = .Primary) {
	th := f.theme
	pick_scroll(l, count, r.h)
	show_bar := count > r.h
	w := show_bar ? r.w - 1 : r.w
	for row in 0 ..< r.h {
		i := l.offset + row
		if i >= count do break
		sel := i == l.cursor
		row_r := Rect{r.x, r.y + row, w, 1}
		if sel {
			fill(f, row_r, {bg = focused ? soft_bg(th, tone, 0.28) : th.raised})
			put(f, r.x, r.y + row, '▌', {fg = focused ? th.tones[tone] : th.faint})
		}
		painter(f, {row_r.x + 2, row_r.y, row_r.w - 2, 1}, i, sel, user)
	}
	if show_bar do scrollbar(f, r.x + r.w - 1, r.y, r.h, count, r.h, l.offset)
}

// pick_draw draws plain string items.
pick_draw :: proc(f: ^Frame, r: Rect, l: ^Pick_List, items: []string, focused := true, tone: Tone = .Primary) {
	Ctx :: struct {items: []string, tone: Tone, focused: bool}
	ctx := Ctx{items, tone, focused}
	pick_draw_custom(f, r, l, len(items), proc(f: ^Frame, row: Rect, i: int, sel: bool, user: rawptr) {
		c := (^Ctx)(user)
		th := f.theme
		p := sel ? Pen{fg = c.focused ? th.tones[c.tone] : th.ink, attrs = {.Bold}} : Pen{fg = th.ink}
		text(f, row.x, row.y, truncate(c.items[i], row.w), p)
	}, &ctx, focused, tone)
}

// ------------------------------------------------------------ Text_Field

Text_Field :: struct {
	runes:       [dynamic]rune,
	cursor:      int, // rune index
	scroll:      int, // first visible rune
	placeholder: string,
	limit:       int,  // 0 = unlimited
	mask:        rune, // e.g. '•' for passwords; 0 = none
}

field_destroy :: proc(t: ^Text_Field) {
	delete(t.runes)
}

field_set :: proc(t: ^Text_Field, s: string) {
	clear(&t.runes)
	for r in s do append(&t.runes, r)
	t.cursor = len(t.runes)
}

field_clear :: proc(t: ^Text_Field) {
	clear(&t.runes)
	t.cursor, t.scroll = 0, 0
}

// field_text returns the value (temp allocated unless you pass one).
field_text :: proc(t: ^Text_Field, allocator := context.temp_allocator) -> string {
	return utf8.runes_to_string(t.runes[:], allocator)
}

field_insert :: proc(t: ^Text_Field, s: string) {
	// Collect first, then splice once: inserting rune by rune is quadratic.
	add := make([dynamic]rune, 0, len(s), context.temp_allocator)
	room := t.limit > 0 ? t.limit - len(t.runes) : max(int)
	for r in s {
		if len(add) >= room do break
		if r == '\n' || r == '\r' || r == '\t' {
			append(&add, ' ') // flatten pasted newlines/tabs in a one-line field
			continue
		}
		if r < 0x20 || (r >= 0x7f && r <= 0x9f) do continue
		append(&add, r)
	}
	if len(add) == 0 do return
	inject_at_elems(&t.runes, t.cursor, ..add[:])
	t.cursor += len(add)
}

@(private)
_is_word :: proc(r: rune) -> bool {
	return !(r == ' ' || r == '\t' || r == '/' || r == '-' || r == '.' || r == ',')
}

@(private)
_word_left :: proc(t: ^Text_Field) -> int {
	i := t.cursor
	for i > 0 && !_is_word(t.runes[i - 1]) do i -= 1
	for i > 0 && _is_word(t.runes[i - 1]) do i -= 1
	return i
}

@(private)
_word_right :: proc(t: ^Text_Field) -> int {
	i := t.cursor
	n := len(t.runes)
	for i < n && !_is_word(t.runes[i]) do i += 1
	for i < n && _is_word(t.runes[i]) do i += 1
	return i
}

// field_on_key implements readline-flavored editing.
field_on_key :: proc(t: ^Text_Field, k: Key) -> bool {
	n := len(t.runes)
	word := .Alt in k.mods || .Ctrl in k.mods
	switch {
	case k.code == .Left && word:     t.cursor = _word_left(t)
	case k.code == .Right && word:    t.cursor = _word_right(t)
	case k.code == .Left, is_ctrl(k, 'b'):  t.cursor = prev_boundary(glyph_spans(t.runes[:], t.mask), t.cursor)
	case k.code == .Right, is_ctrl(k, 'f'): t.cursor = next_boundary(glyph_spans(t.runes[:], t.mask), t.cursor)
	case k.code == .Home, is_ctrl(k, 'a'):  t.cursor = 0
	case k.code == .End, is_ctrl(k, 'e'):   t.cursor = n
	case k.code == .Backspace && word, is_ctrl(k, 'w'):
		to := _word_left(t)
		remove_range(&t.runes, to, t.cursor)
		t.cursor = to
	case k.code == .Backspace:
		// Whole units: one press removes an emoji sequence or letter+accent.
		if t.cursor > 0 {
			from := prev_boundary(glyph_spans(t.runes[:], t.mask), t.cursor)
			remove_range(&t.runes, from, t.cursor)
			t.cursor = from
		}
	case k.code == .Delete, is_ctrl(k, 'd'):
		if t.cursor < n {
			to := next_boundary(glyph_spans(t.runes[:], t.mask), t.cursor)
			remove_range(&t.runes, t.cursor, to)
		}
	case is_ctrl(k, 'u'):
		remove_range(&t.runes, 0, t.cursor)
		t.cursor = 0
	case is_ctrl(k, 'k'):
		resize(&t.runes, t.cursor)
	case k.code == .Char && .Ctrl not_in k.mods && .Alt not_in k.mods:
		buf, sz := utf8.encode_rune(k.ch)
		field_insert(t, string(buf[:sz]))
	case:
		return false
	}
	return true
}

// field draws the input. When focused, a block cursor is shown.
field_draw :: proc(f: ^Frame, r: Rect, t: ^Text_Field, focused := true, tone: Tone = .Primary, prompt := "› ") {
	th := f.theme
	if r.w <= 0 || r.h <= 0 do return
	row := Rect{r.x, r.y, r.w, 1}
	fill(f, row, {bg = th.raised})
	pw := text(f, r.x, r.y, prompt, {fg = focused ? th.tones[tone] : th.faint, attrs = {.Bold}})
	avail := r.w - pw - 1
	if avail <= 0 do return
	if len(t.runes) == 0 {
		if focused do put(f, r.x + pw, r.y, ' ', {bg = th.tones[tone]})
		text(f, r.x + pw + (focused ? 1 : 0), r.y, truncate(t.placeholder, avail - 1), {fg = th.faint, attrs = {.Italic}})
		return
	}
	// Work in drawn units (grapheme clusters in clustering terminals). The
	// cursor and scroll always sit on a unit boundary.
	spans := glyph_spans(t.runes[:], t.mask)
	t.cursor = clamp(t.cursor, 0, len(t.runes))
	ck := span_at(spans, t.cursor)
	if ck < len(spans) do t.cursor = spans[ck].start
	sk := span_at(spans, clamp(t.scroll, 0, len(t.runes)))
	if sk > ck do sk = ck
	// Walk back from the cursor once to find the earliest unit that still
	// keeps the cursor visible: long values stay linear.
	w := 0
	earliest := ck
	for earliest > 0 {
		cw := spans[earliest - 1].width
		if w + cw >= avail do break
		w += cw
		earliest -= 1
	}
	if sk < earliest do sk = earliest
	t.scroll = sk < len(spans) ? spans[sk].start : len(t.runes)
	x := r.x + pw
	start_x := x
	for k in sk ..< len(spans) {
		sp := spans[k]
		if x + sp.width > r.x + pw + avail do break
		p := Pen{fg = th.ink}
		if focused && k == ck do p = {fg = th.on_tone[tone], bg = th.tones[tone]}
		glyph := t.mask != 0 ? _rune_str(t.mask) : utf8.runes_to_string(t.runes[sp.start:sp.end], context.temp_allocator)
		x += put_glyph(f, x, r.y, glyph, sp.width, p)
	}
	if focused && ck >= len(spans) && x < r.x + r.w {
		put(f, x, r.y, ' ', {bg = th.tones[tone]})
	}
	// Scrolled sideways: show that the value continues to the left.
	if t.scroll > 0 && t.cursor != t.scroll do put(f, start_x, r.y, '…', {fg = th.faint})
}

// ------------------------------------------------------------ Scroll_View

Scroll_View :: struct {
	offset: int,
}

scroll_on_key :: proc(s: ^Scroll_View, k: Key, total, visible: int) -> bool {
	page := max(visible - 1, 1)
	switch {
	case k.code == .Up, is_char(k, 'k'):        s.offset -= 1
	case k.code == .Down, is_char(k, 'j'):      s.offset += 1
	case k.code == .Page_Up, is_char(k, 'b'):   s.offset -= page
	case k.code == .Page_Down, is_char(k, ' '), is_char(k, 'f'): s.offset += page
	case is_char(k, 'u'):                       s.offset -= page / 2
	case is_char(k, 'd'):                       s.offset += page / 2
	case k.code == .Home, is_char(k, 'g'):      s.offset = 0
	case k.code == .End, is_char(k, 'G'):       s.offset = total
	case:                                       return false
	}
	s.offset = clamp(s.offset, 0, max(total - visible, 0))
	return true
}

scroll_on_mouse :: proc(s: ^Scroll_View, m: Mouse, total, visible: int) -> bool {
	switch m.button {
	case .Wheel_Up:   s.offset -= 3
	case .Wheel_Down: s.offset += 3
	case .None, .Left, .Middle, .Right: return false
	}
	s.offset = clamp(s.offset, 0, max(total - visible, 0))
	return true
}

// scroll_draw draws styled lines with a scrollbar.
scroll_draw :: proc(f: ^Frame, r: Rect, s: ^Scroll_View, lines: []Line) {
	s.offset = clamp(s.offset, 0, max(len(lines) - r.h, 0))
	w := len(lines) > r.h ? r.w - 1 : r.w
	for row in 0 ..< r.h {
		i := s.offset + row
		if i >= len(lines) do break
		spans(f, r.x, r.y + row, lines[i], w)
	}
	scrollbar(f, r.x + r.w - 1, r.y, r.h, len(lines), r.h, s.offset)
}

// scroll_percent returns a "42%" style position label.
scroll_percent :: proc(s: ^Scroll_View, total, visible: int) -> string {
	if total <= visible do return "all"
	return fmt.tprintf("%d%%", 100 * clamp(s.offset, 0, total - visible) / (total - visible))
}

// ------------------------------------------------------------ Grid (table)

Column :: struct {
	title: string,
	size:  Size,
	align: Align,
}

// grid_draw draws a table with a header row and a selectable body.
grid_draw :: proc(f: ^Frame, r: Rect, l: ^Pick_List, cols: []Column, cells: [][]string, focused := true, tone: Tone = .Primary) {
	th := f.theme
	if r.h < 2 do return
	sizes := make([]Size, len(cols), context.temp_allocator)
	for c, i in cols do sizes[i] = c.size
	spans := split({r.x + 2, r.y, r.w - 4, 1}, .Horizontal, sizes, 2) // last column: scrollbar
	for c, i in cols {
		text_aligned(f, spans[i].x, r.y, spans[i].w, strings.to_upper(c.title, context.temp_allocator), {fg = th.muted, attrs = {.Bold}}, c.align)
	}
	hline(f, r.x, r.y + 1, r.w, {fg = th.line})
	body := Rect{r.x, r.y + 2, r.w, r.h - 2}
	Ctx :: struct {cols: []Column, spans: []Rect, cells: [][]string, focused: bool, tone: Tone}
	ctx := Ctx{cols, spans, cells, focused, tone}
	pick_draw_custom(f, body, l, len(cells), proc(f: ^Frame, row: Rect, i: int, sel: bool, user: rawptr) {
		c := (^Ctx)(user)
		th := f.theme
		for col, j in c.cols {
			if j >= len(c.cells[i]) do break
			sp := c.spans[j]
			p := Pen{fg = j == 0 ? th.ink : th.muted}
			if sel do p = {fg = c.focused ? th.tones[c.tone] : th.ink, attrs = j == 0 ? {.Bold} : {}}
			text_aligned(f, sp.x, row.y, sp.w, c.cells[i][j], p, col.align)
		}
	}, &ctx, focused, tone)
}

@(private)
_rune_str :: proc(r: rune) -> string {
	buf, n := utf8.encode_rune(r)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

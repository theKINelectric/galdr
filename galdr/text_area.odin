package galdr

import "core:strings"
import "core:unicode/utf8"

// Text_Area: multi-line editing with readline-flavored keys, a sticky column
// for vertical moves, and scrolling in both directions.

Text_Area :: struct {
	lines:       [dynamic][dynamic]rune,
	row, col:    int, // cursor (rune index within the line)
	want_col:    int, // column to return to when moving vertically
	top, left:   int, // scroll offsets (rows, cells)
	view_h:      int, // visible rows at last draw (for page keys)
	placeholder: string,
	max_lines:   int, // 0 = unlimited
}

area_destroy :: proc(ta: ^Text_Area) {
	for l in ta.lines do delete(l)
	delete(ta.lines)
}

@(private)
_area_ensure :: proc(ta: ^Text_Area) {
	if len(ta.lines) == 0 do append(&ta.lines, make([dynamic]rune))
}

area_set :: proc(ta: ^Text_Area, s: string) {
	for l in ta.lines do delete(l)
	clear(&ta.lines)
	_area_ensure(ta)
	ta.row, ta.col = 0, 0
	area_insert(ta, s)
	ta.row, ta.col, ta.top, ta.left = 0, 0, 0, 0
}

// area_text joins the lines with "\n".
area_text :: proc(ta: ^Text_Area, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for l, i in ta.lines {
		if i > 0 do strings.write_byte(&b, '\n')
		for r in l do strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

// area_insert inserts text at the cursor; "\n" splits lines.
area_insert :: proc(ta: ^Text_Area, s: string) {
	_area_ensure(ta)
	for r in s {
		switch {
		case r == '\n':
			if ta.max_lines > 0 && len(ta.lines) >= ta.max_lines do continue
			line := &ta.lines[ta.row]
			tail := make([dynamic]rune)
			append(&tail, ..line[ta.col:])
			resize(line, ta.col)
			inject_at(&ta.lines, ta.row + 1, tail)
			ta.row += 1
			ta.col = 0
		case r == '\r':
		case r == '\t':
			for _ in 0 ..< 4 {
				inject_at(&ta.lines[ta.row], ta.col, ' ')
				ta.col += 1
			}
		case r < 0x20 || (r >= 0x7f && r < 0xa0):
		case:
			inject_at(&ta.lines[ta.row], ta.col, r)
			ta.col += 1
		}
	}
	ta.want_col = ta.col
}

@(private)
_area_join_next :: proc(ta: ^Text_Area, row: int) {
	if row + 1 >= len(ta.lines) do return
	append(&ta.lines[row], ..ta.lines[row + 1][:])
	delete(ta.lines[row + 1])
	ordered_remove(&ta.lines, row + 1)
}

area_on_key :: proc(ta: ^Text_Area, k: Key) -> bool {
	_area_ensure(ta)
	line := &ta.lines[ta.row]
	n := len(line)
	word := .Alt in k.mods || .Ctrl in k.mods
	vertical := false
	switch {
	case k.code == .Enter && k.mods & {.Alt, .Ctrl} == {}:
		area_insert(ta, "\n")
	case k.code == .Left && word:
		for ta.col > 0 && !_is_word(line[ta.col - 1]) do ta.col -= 1
		for ta.col > 0 && _is_word(line[ta.col - 1]) do ta.col -= 1
	case k.code == .Right && word:
		for ta.col < n && !_is_word(line[ta.col]) do ta.col += 1
		for ta.col < n && _is_word(line[ta.col]) do ta.col += 1
	case k.code == .Left, is_ctrl(k, 'b'):
		if ta.col > 0 {
			ta.col = prev_boundary(glyph_spans(line[:]), ta.col)
		} else if ta.row > 0 {
			ta.row -= 1
			ta.col = len(ta.lines[ta.row])
		}
	case k.code == .Right, is_ctrl(k, 'f'):
		if ta.col < n {
			ta.col = next_boundary(glyph_spans(line[:]), ta.col)
		} else if ta.row + 1 < len(ta.lines) {
			ta.row += 1
			ta.col = 0
		}
	case k.code == .Up, is_ctrl(k, 'p'):
		ta.row = max(ta.row - 1, 0)
		vertical = true
	case k.code == .Down, is_ctrl(k, 'n'):
		ta.row = min(ta.row + 1, len(ta.lines) - 1)
		vertical = true
	case k.code == .Page_Up:
		ta.row = max(ta.row - max(ta.view_h - 1, 1), 0)
		vertical = true
	case k.code == .Page_Down:
		ta.row = min(ta.row + max(ta.view_h - 1, 1), len(ta.lines) - 1)
		vertical = true
	case k.code == .Home && .Ctrl in k.mods:
		ta.row, ta.col = 0, 0
	case k.code == .End && .Ctrl in k.mods:
		ta.row = len(ta.lines) - 1
		ta.col = len(ta.lines[ta.row])
	case k.code == .Home, is_ctrl(k, 'a'):
		ta.col = 0
	case k.code == .End, is_ctrl(k, 'e'):
		ta.col = n
	case k.code == .Backspace:
		if ta.col > 0 {
			from := prev_boundary(glyph_spans(line[:]), ta.col)
			remove_range(line, from, ta.col)
			ta.col = from
		} else if ta.row > 0 {
			ta.col = len(ta.lines[ta.row - 1])
			ta.row -= 1
			_area_join_next(ta, ta.row)
		}
	case k.code == .Delete, is_ctrl(k, 'd'):
		if ta.col < n {
			remove_range(line, ta.col, next_boundary(glyph_spans(line[:]), ta.col))
		} else {
			_area_join_next(ta, ta.row)
		}
	case is_ctrl(k, 'k'):
		if ta.col < n do resize(line, ta.col)
		else do _area_join_next(ta, ta.row)
	case is_ctrl(k, 'u'):
		remove_range(line, 0, ta.col)
		ta.col = 0
	case k.code == .Tab && k.mods == {}:
		area_insert(ta, "\t")
	case k.code == .Char && .Ctrl not_in k.mods && .Alt not_in k.mods:
		buf, sz := utf8.encode_rune(k.ch)
		area_insert(ta, string(buf[:sz]))
	case:
		return false
	}
	if vertical {
		ta.col = min(ta.want_col, len(ta.lines[ta.row]))
		// Never land inside a cluster on the new line.
		spans := glyph_spans(ta.lines[ta.row][:])
		if k := span_at(spans, ta.col); k < len(spans) do ta.col = spans[k].start
	} else {
		ta.want_col = ta.col
	}
	return true
}

// area_draw draws the text with an optional line-number gutter and a block
// cursor when focused.
area_draw :: proc(f: ^Frame, r: Rect, ta: ^Text_Area, focused := true, tone: Tone = .Primary, line_numbers := false) {
	th := f.theme
	_area_ensure(ta)
	if r.w <= 2 || r.h <= 0 do return
	fill(f, r, {bg = th.raised})
	gutter := 0
	if line_numbers do gutter = len(fmt_int(len(ta.lines))) + 1
	body := Rect{r.x + gutter, r.y, r.w - gutter, r.h}
	ta.view_h = body.h

	// Keep the cursor visible (cells measured by drawn units).
	if ta.row < ta.top do ta.top = ta.row
	if ta.row >= ta.top + body.h do ta.top = ta.row - body.h + 1
	cursor_x := 0
	for sp in glyph_spans(ta.lines[ta.row][:]) {
		if sp.start >= ta.col do break
		cursor_x += sp.width
	}
	if cursor_x < ta.left do ta.left = cursor_x
	if cursor_x >= ta.left + body.w - 1 do ta.left = cursor_x - body.w + 2

	empty := len(ta.lines) == 1 && len(ta.lines[0]) == 0
	if empty && ta.placeholder != "" {
		text(f, body.x + 1, body.y, truncate(ta.placeholder, body.w - 1), {fg = th.faint, attrs = {.Italic}})
	}
	for row in 0 ..< body.h {
		li := ta.top + row
		if li >= len(ta.lines) do break
		y := body.y + row
		if line_numbers {
			num := fmt_int(li + 1)
			text(f, r.x + gutter - 1 - len(num), y, num, {fg = li == ta.row ? th.muted : th.faint})
		}
		x := 0 // cells from the line start
		for sp in glyph_spans(ta.lines[li][:]) {
			sx := body.x + x - ta.left
			x += sp.width
			if sx < body.x do continue
			if sx + sp.width > body.x + body.w do break
			p := Pen{fg = th.ink}
			if focused && li == ta.row && sp.start == ta.col do p = {fg = th.on_tone[tone], bg = th.tones[tone]}
			put_glyph(f, sx, y, utf8.runes_to_string(ta.lines[li][sp.start:sp.end], context.temp_allocator), sp.width, p)
		}
		if focused && li == ta.row && ta.col == len(ta.lines[li]) {
			sx := body.x + cursor_x - ta.left
			if sx < body.x + body.w do put(f, sx, y, ' ', {bg = th.tones[tone]})
		}
	}
}

@(private)
fmt_int :: proc(n: int) -> string {
	buf := make([]u8, 20, context.temp_allocator)
	i := len(buf)
	v := n
	if v == 0 {
		i -= 1
		buf[i] = '0'
	}
	for v > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	return string(buf[i:])
}

package galdr

import "core:strings"
import "core:unicode/utf8"

// A Frame is the cell grid a paint proc draws into. The runtime diffs
// consecutive frames and sends only what changed to the terminal.

// MAX_CLUSTER_EXTRA codepoints can follow the base in one cell: enough for
// combining marks, skin tones, flags and 4-person ZWJ families.
MAX_CLUSTER_EXTRA :: 7

Cell :: struct {
	ch:    rune,                        // base codepoint
	ext:   [MAX_CLUSTER_EXTRA]rune,     // rest of the grapheme cluster, 0-terminated
	pen:   Pen,
	width: u8, // 1 normal, 2 wide head, 0 continuation of a wide head
}

Rect :: struct {
	x, y, w, h: int,
}

// A Zone names a rectangle painted this frame, so mouse events can say what
// they hit. name should be a string literal (it must outlive the frame).
Zone :: struct {
	name:  string,
	index: int,
	rect:  Rect,
}

Frame :: struct {
	w, h:   int,
	cells:  []Cell,
	clip:   Rect,
	theme:  ^Theme,
	zones:  [dynamic]Zone, // registered during paint, topmost last
	now_ms: i64,           // engine clock at paint time (for time-based effects)
	// Optional hardware cursor (for IME-friendly inputs). Hidden when show is false.
	cursor: struct {x, y: int, show: bool},
}

BLANK :: Cell{ch = ' ', width = 1}

frame_make :: proc(w, h: int, theme: ^Theme, allocator := context.allocator) -> Frame {
	f := Frame{theme = theme}
	frame_resize(&f, w, h, allocator)
	return f
}

frame_resize :: proc(f: ^Frame, w, h: int, allocator := context.allocator) {
	delete(f.cells, allocator)
	f.w, f.h = max(w, 0), max(h, 0)
	f.cells = make([]Cell, f.w * f.h, allocator)
	for &c in f.cells do c = BLANK
	f.clip = {0, 0, f.w, f.h}
}

frame_destroy :: proc(f: ^Frame, allocator := context.allocator) {
	delete(f.cells, allocator)
	delete(f.zones)
	f.cells = nil
}

// frame_reset clears every cell to the theme background and resets clip/cursor.
frame_reset :: proc(f: ^Frame) {
	bg := f.theme != nil ? f.theme.bg : NO_COLOR
	fg := f.theme != nil ? f.theme.ink : NO_COLOR
	for &c in f.cells do c = {ch = ' ', width = 1, pen = {fg = fg, bg = bg}}
	f.clip = {0, 0, f.w, f.h}
	f.cursor = {}
	clear(&f.zones)
}

frame_bounds :: proc(f: ^Frame) -> Rect {
	return {0, 0, f.w, f.h}
}

rect_intersect :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

rect_contains :: proc(r: Rect, x, y: int) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

// push_clip narrows drawing to r; returns the previous clip for pop_clip.
push_clip :: proc(f: ^Frame, r: Rect) -> Rect {
	prev := f.clip
	f.clip = rect_intersect(prev, r)
	return prev
}

pop_clip :: proc(f: ^Frame, prev: Rect) {
	f.clip = prev
}

// clip_scope narrows drawing to r until the end of the enclosing block:
//     inner := gd.panel(f, r, "Crew")
//     gd.clip_scope(f, inner) // nothing below can draw outside the panel
@(deferred_in_out = _clip_scope_end)
clip_scope :: proc(f: ^Frame, r: Rect) -> (prev: Rect) {
	return push_clip(f, r)
}

@(private)
_clip_scope_end :: proc(f: ^Frame, r: Rect, prev: Rect) {
	f.clip = prev
}

// zone registers r (clipped) under name/index for mouse hit-testing. Zones
// registered later sit on top (a dialog painted last wins).
zone :: proc(f: ^Frame, name: string, r: Rect, index := 0) {
	visible := rect_intersect(r, f.clip)
	if visible.w <= 0 || visible.h <= 0 do return
	append(&f.zones, Zone{name, index, visible})
}

// zone_at returns the topmost zone containing (x, y).
zone_at :: proc(zones: []Zone, x, y: int) -> (Zone, bool) {
	#reverse for z in zones {
		if rect_contains(z.rect, x, y) do return z, true
	}
	return {}, false
}

cell_at :: proc(f: ^Frame, x, y: int) -> ^Cell {
	if x < 0 || y < 0 || x >= f.w || y >= f.h do return nil
	return &f.cells[y * f.w + x]
}

// _merge applies p over an existing cell pen: a Default background is
// transparent so text can sit on panels without restating their color.
@(private)
_merge :: proc(under: Pen, p: Pen) -> Pen {
	out := p
	if p.bg.mode == .Default do out.bg = under.bg
	if p.fg.mode == .Default do out.fg = under.fg
	return out
}

// put sets one rune at (x, y). Returns the number of cells advanced.
put :: proc(f: ^Frame, x, y: int, ch: rune, p: Pen) -> int {
	buf, n := utf8.encode_rune(ch)
	return put_glyph(f, x, y, string(buf[:n]), rune_width(ch), p)
}

// put_glyph sets one glyph (a grapheme cluster, or a codepoint with its
// combining marks) occupying `width` cells. Returns cells advanced.
put_glyph :: proc(f: ^Frame, x, y: int, glyph: string, width: int, p: Pen) -> int {
	w := width
	if w <= 0 || len(glyph) == 0 do return 0
	if !rect_contains(f.clip, x, y) do return w
	c := &f.cells[y * f.w + x]
	// Overwriting half of a wide glyph: blank its other half.
	if c.width == 0 && x > 0 {
		left := &f.cells[y * f.w + x - 1]
		left.ch, left.ext, left.width = ' ', {}, 1
	}
	if c.width == 2 && x + 1 < f.w {
		right := &f.cells[y * f.w + x + 1]
		right.ch, right.ext, right.width = ' ', {}, 1
	}
	if w == 2 && !rect_contains(f.clip, x + 1, y) {
		c^ = {ch = ' ', width = 1, pen = _merge(c.pen, p)}
		return 2
	}
	cell := Cell{width = u8(w), pen = _merge(c.pen, p)}
	k := -1
	for r in glyph {
		if _is_control(r) do continue // never store a control character
		if k < 0 {
			cell.ch = r
		} else if k < MAX_CLUSTER_EXTRA {
			cell.ext[k] = r
		}
		k += 1
	}
	c^ = cell
	if w == 2 {
		n := &f.cells[y * f.w + x + 1]
		if n.width == 2 && x + 2 < f.w {
			nn := &f.cells[y * f.w + x + 2]
			nn.ch, nn.ext, nn.width = ' ', {}, 1
		}
		n^ = {ch = 0, width = 0, pen = c.pen}
	}
	return w
}

// write_cell_text appends a cell's full glyph (base plus cluster extras).
write_cell_text :: proc(b: ^strings.Builder, c: Cell) {
	strings.write_rune(b, c.ch)
	for r in c.ext {
		if r == 0 do break
		strings.write_rune(b, r)
	}
}

// text draws s starting at (x, y), stopping after max_w cells (-1 = to clip edge).
// Returns the number of cells written.
text :: proc(f: ^Frame, x, y: int, s: string, p: Pen, max_w := -1) -> int {
	limit := max_w < 0 ? f.clip.x + f.clip.w - x : max_w
	cx := x
	for i := 0; i < len(s); {
		glyph, gw, next, _ := next_glyph(s, i)
		i = next
		if glyph == "\t" {
			if cx - x + 1 <= limit do cx += put(f, cx, y, ' ', p)
			continue
		}
		if gw == 0 do continue // controls, or a stray leading combining mark
		if cx - x + gw > limit do break
		cx += put_glyph(f, cx, y, glyph, gw, p)
	}
	return cx - x
}

Align :: enum u8 {
	Left,
	Center,
	Right,
}

// text_aligned draws s inside a one-line span of width w.
text_aligned :: proc(f: ^Frame, x, y, w: int, s: string, p: Pen, align: Align = .Left) -> int {
	fit := truncate(s, w)
	sw := text_width(fit)
	off := 0
	switch align {
	case .Left:
	case .Center: off = (w - sw) / 2
	case .Right:  off = w - sw
	}
	return text(f, x + off, y, fit, p, w - off)
}

// fill paints r with ch in pen p (background included).
fill :: proc(f: ^Frame, r: Rect, p: Pen, ch: rune = ' ') {
	area := rect_intersect(r, f.clip)
	for y in area.y ..< area.y + area.h {
		for x in area.x ..< area.x + area.w {
			put(f, x, y, ch, p)
		}
	}
}

// tint changes only the background of r (keeps glyphs and foregrounds).
tint :: proc(f: ^Frame, r: Rect, bg: Color) {
	area := rect_intersect(r, f.clip)
	for y in area.y ..< area.y + area.h {
		for x in area.x ..< area.x + area.w {
			f.cells[y * f.w + x].pen.bg = bg
		}
	}
}

// restyle overwrites fg/attrs of r (e.g. to dim a disabled region).
restyle :: proc(f: ^Frame, r: Rect, fg: Color, attrs: Attrs) {
	area := rect_intersect(r, f.clip)
	for y in area.y ..< area.y + area.h {
		for x in area.x ..< area.x + area.w {
			c := &f.cells[y * f.w + x]
			c.pen.fg = fg
			c.pen.attrs = attrs
		}
	}
}

hline :: proc(f: ^Frame, x, y, w: int, p: Pen, ch: rune = '─') {
	for i in 0 ..< w do put(f, x + i, y, ch, p)
}

vline :: proc(f: ^Frame, x, y, h: int, p: Pen, ch: rune = '│') {
	for i in 0 ..< h do put(f, x, y + i, ch, p)
}

// ---------------------------------------------------------------- spans

Span :: struct {
	text: string,
	pen:  Pen,
}

Line :: []Span

// spans draws a styled run of text. Returns cells written.
spans :: proc(f: ^Frame, x, y: int, parts: []Span, max_w := -1) -> int {
	limit := max_w < 0 ? f.clip.x + f.clip.w - x : max_w
	cx := x
	for s in parts {
		if cx - x >= limit do break
		cx += text(f, cx, y, s.text, s.pen, limit - (cx - x))
	}
	return cx - x
}

spans_width :: proc(parts: []Span) -> int {
	w := 0
	for s in parts do w += text_width(s.text)
	return w
}

// ---------------------------------------------------------------- snapshots

// frame_to_text renders the frame's glyphs (no styling) as newline-separated
// rows with trailing spaces trimmed. Used by tests and the headless harness.
frame_to_text :: proc(f: ^Frame, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for y in 0 ..< f.h {
		row := strings.builder_make(context.temp_allocator)
		for x in 0 ..< f.w {
			c := f.cells[y * f.w + x]
			if c.width == 0 do continue
			write_cell_text(&row, c)
		}
		strings.write_string(&b, strings.trim_right_space(strings.to_string(row)))
		if y < f.h - 1 do strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// row_text returns one row's glyphs (trailing spaces trimmed).
row_text :: proc(f: ^Frame, y: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for x in 0 ..< f.w {
		c := f.cells[y * f.w + x]
		if c.width == 0 do continue
		write_cell_text(&b, c)
	}
	return strings.trim_right_space(strings.to_string(b))
}

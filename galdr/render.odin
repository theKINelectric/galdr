package galdr

import "core:mem"
import "core:strings"

// Rendering turns Frames into terminal bytes. Pure: it writes into a
// strings.Builder and never touches a file descriptor.

Color_Depth :: enum u8 {
	True_Color,
	Palette_256,
	Ansi_16, // Linux console and minimal terminals
	Mono,    // NO_COLOR: attributes only; emphasis becomes reverse video
}

Caps :: struct {
	depth:   Color_Depth,
	no_sync:   bool, // terminal said it doesn't know synchronized output (2026)
	no_scroll: bool, // never use scroll margins to shift content
}

@(private)
_write_int :: proc(b: ^strings.Builder, n: int) {
	strings.write_int(b, n)
}

@(private)
_color_params :: proc(b: ^strings.Builder, c: Color, is_bg: bool, caps: Caps) {
	switch c.mode {
	case .Default:
		return
	case .Index:
		strings.write_string(b, is_bg ? ";48;5;" : ";38;5;")
		_write_int(b, int(c.r))
	case .RGB:
		if caps.depth == .Ansi_16 {
			i := int(to_16(c))
			base := is_bg ? 40 : 30
			if i >= 8 do base += 60
			strings.write_byte(b, ';')
			_write_int(b, base + i % 8)
			return
		}
		if caps.depth == .Palette_256 {
			strings.write_string(b, is_bg ? ";48;5;" : ";38;5;")
			_write_int(b, int(to_256(c)))
			return
		}
		strings.write_string(b, is_bg ? ";48;2;" : ";38;2;")
		_write_int(b, int(c.r))
		strings.write_byte(b, ';')
		_write_int(b, int(c.g))
		strings.write_byte(b, ';')
		_write_int(b, int(c.b))
	}
}

// _mono_pen maps a colored pen to attributes only. Cells whose background
// stands out from the page (selections, solid badges, inputs) turn into
// reverse video so they stay visible without color.
@(private)
_mono_pen :: proc(p: Pen, th: ^Theme) -> Pen {
	out := Pen{attrs = p.attrs}
	if th != nil && p.bg.mode == .RGB && p.bg != th.bg && p.bg != th.surface {
		out.attrs ~= {.Reverse}
	}
	if th != nil && p.fg.mode == .RGB && (p.fg == th.faint || p.fg == th.muted) {
		out.attrs += {.Dim}
	}
	return out
}

// write_sgr emits a full reset-and-set SGR sequence for p.
write_sgr :: proc(b: ^strings.Builder, p: Pen, caps: Caps, th: ^Theme = nil) {
	p := p
	if caps.depth == .Mono do p = _mono_pen(p, th)
	strings.write_string(b, "\x1b[0")
	if .Bold in p.attrs do strings.write_string(b, ";1")
	if .Dim in p.attrs do strings.write_string(b, ";2")
	if .Italic in p.attrs do strings.write_string(b, ";3")
	if .Underline in p.attrs do strings.write_string(b, ";4")
	if .Blink in p.attrs do strings.write_string(b, ";5")
	if .Reverse in p.attrs do strings.write_string(b, ";7")
	if .Strike in p.attrs do strings.write_string(b, ";9")
	_color_params(b, p.fg, false, caps)
	_color_params(b, p.bg, true, caps)
	strings.write_byte(b, 'm')
}

write_move :: proc(b: ^strings.Builder, x, y: int) {
	strings.write_string(b, "\x1b[")
	_write_int(b, y + 1)
	strings.write_byte(b, ';')
	_write_int(b, x + 1)
	strings.write_byte(b, 'H')
}

// write_sgr_delta switches the terminal from pen `from` to pen `to` with as
// few bytes as it can: only the attributes and colors that changed, or a
// full reset when that is shorter.
write_sgr_delta :: proc(b: ^strings.Builder, from, to: Pen, caps: Caps, th: ^Theme = nil) {
	f, t := from, to
	if caps.depth == .Mono {
		f, t = _mono_pen(from, th), _mono_pen(to, th)
	}
	if f == t do return
	full := strings.builder_make(context.temp_allocator)
	write_sgr(&full, to, caps, th)

	d := strings.builder_make(context.temp_allocator)
	param :: proc(d: ^strings.Builder, code: int) {
		strings.write_byte(d, ';')
		strings.write_int(d, code)
	}
	removed := f.attrs - t.attrs
	added := t.attrs - f.attrs
	if .Bold in removed || .Dim in removed {
		param(&d, 22) // turns off both: re-add whichever should stay
		if .Bold in t.attrs do added += {.Bold}
		if .Dim in t.attrs do added += {.Dim}
	}
	if .Italic in removed do param(&d, 23)
	if .Underline in removed do param(&d, 24)
	if .Blink in removed do param(&d, 25)
	if .Reverse in removed do param(&d, 27)
	if .Strike in removed do param(&d, 29)
	if .Bold in added do param(&d, 1)
	if .Dim in added do param(&d, 2)
	if .Italic in added do param(&d, 3)
	if .Underline in added do param(&d, 4)
	if .Blink in added do param(&d, 5)
	if .Reverse in added do param(&d, 7)
	if .Strike in added do param(&d, 9)
	if f.fg != t.fg {
		if t.fg.mode == .Default do param(&d, 39)
		else do _color_params(&d, t.fg, false, caps)
	}
	if f.bg != t.bg {
		if t.bg.mode == .Default do param(&d, 49)
		else do _color_params(&d, t.bg, true, caps)
	}
	delta := strings.to_string(d)
	if len(delta) == 0 do return
	if len(delta) + 3 >= strings.builder_len(full) {
		strings.write_string(b, strings.to_string(full))
		return
	}
	strings.write_string(b, "\x1b[")
	strings.write_string(b, delta[1:]) // drop the leading ';'
	strings.write_byte(b, 'm')
}

// Cursor state while rendering: x == w means "just wrote the last column"
// (pending wrap), -1 means unknown.
@(private)
_Cursor :: struct {
	x, y: int,
}

// _move positions the cursor at (x, y) as cheaply as possible, possibly by
// reprinting unchanged cells that share the current pen.
@(private)
_move :: proc(b: ^strings.Builder, cur: ^_Cursor, x, y: int, next: ^Frame, pen: Pen, pen_known: bool) {
	if cur.x == x && cur.y == y do return
	if cur.y == y && cur.x >= 0 && cur.x < x && cur.x < next.w {
		gap := x - cur.x
		// Reprinting a few plain cells beats an escape sequence.
		if gap <= 4 && pen_known {
			ok := true
			for i in cur.x ..< x {
				c := next.cells[y * next.w + i]
				if c.width != 1 || c.pen != pen || c.ch < 0x20 || c.ch > 0x7e || c.ext[0] != 0 {
					ok = false
					break
				}
			}
			if ok {
				for i in cur.x ..< x do strings.write_byte(b, u8(next.cells[y * next.w + i].ch))
				cur.x = x
				return
			}
		}
		strings.write_string(b, "\x1b[")
		if gap > 1 do strings.write_int(b, gap)
		strings.write_byte(b, 'C')
		cur.x = x
		return
	}
	if x == 0 && cur.y >= 0 && y == cur.y + 1 && cur.x >= 0 {
		strings.write_string(b, "\r\n")
		cur.x, cur.y = 0, y
		return
	}
	switch {
	case x == 0 && y == 0: strings.write_string(b, "\x1b[H")
	case x == 0:
		strings.write_string(b, "\x1b[")
		strings.write_int(b, y + 1)
		strings.write_byte(b, 'H')
	case: write_move(b, x, y)
	}
	cur.x, cur.y = x, y
}

// ------------------------------------------------------------ scrolling

@(private)
_row_equal :: proc(a: ^Frame, ya: int, b: ^Frame, yb: int) -> bool {
	w := a.w
	ra := a.cells[ya * w:(ya + 1) * w]
	rb := b.cells[yb * w:(yb + 1) * w]
	for i in 0 ..< w do if ra[i] != rb[i] do return false
	return true
}

#assert(size_of(Cell) % 4 == 0)

// _row_hashes hashes each row 32 bits at a time (cells are plain data).
@(private)
_row_hashes :: proc(f: ^Frame) -> []u64 {
	out := make([]u64, f.h, context.temp_allocator)
	words_per_row := f.w * size_of(Cell) / 4
	words := ([^]u32)(raw_data(f.cells))
	for y in 0 ..< f.h {
		h: u64 = 0xcbf29ce484222325
		row := words[y * words_per_row:(y + 1) * words_per_row]
		for word in row {
			h = (h ~ u64(word)) * 0x100000001b3
		}
		out[y] = h
	}
	return out
}

@(private)
Scroll_Plan :: struct {
	top, bottom: int, // region rows, inclusive
	amount:      int, // > 0 scroll up (content moves up), < 0 down
}

// plan_scroll finds the band of rows that moved vertically between prev and
// next and is worth shifting in the terminal instead of redrawing.
@(private)
plan_scroll :: proc(prev, next: ^Frame) -> (plan: Scroll_Plan, ok: bool) {
	if prev.h < 6 || prev.w != next.w || prev.h != next.h do return {}, false
	h := next.h
	// Only worth searching when a good part of the screen changed; a row
	// memcmp is far cheaper than hashing, so check that first.
	changed := 0
	row_bytes := next.w * size_of(Cell)
	for y in 0 ..< h {
		if mem.compare_ptrs(&prev.cells[y * prev.w], &next.cells[y * next.w], row_bytes) != 0 do changed += 1
	}
	if changed < 4 do return {}, false
	hp, hn := _row_hashes(prev), _row_hashes(next)
	best_gain := 0
	for k in 1 ..= h / 2 {
		for dir in ([2]int{1, -1}) {
			// Runs where next[y] == prev[y + dir*k].
			y := 0
			for y < h {
				src := y + dir * k
				if src < 0 || src >= h || hn[y] != hp[src] || !_row_equal(next, y, prev, src) {
					y += 1
					continue
				}
				start := y
				already := 0
				for y < h {
					s2 := y + dir * k
					if s2 < 0 || s2 >= h || hn[y] != hp[s2] || !_row_equal(next, y, prev, s2) do break
					if hn[y] == hp[y] && _row_equal(next, y, prev, y) do already += 1
					y += 1
				}
				gain := (y - start) - already - k // rows saved, minus the rows revealed
				if gain > best_gain && y - start >= 3 {
					best_gain = gain
					if dir == 1 {
						plan = {top = start, bottom = y - 1 + k, amount = k}
					} else {
						plan = {top = start - k, bottom = y - 1, amount = -k}
					}
				}
			}
		}
	}
	return plan, best_gain >= 2
}

// _apply_scroll emits the scroll and returns what the screen now shows.
@(private)
_apply_scroll :: proc(b: ^strings.Builder, prev: ^Frame, plan: Scroll_Plan) -> Frame {
	shown := Frame{w = prev.w, h = prev.h, theme = prev.theme}
	shown.cells = make([]Cell, len(prev.cells), context.temp_allocator)
	copy(shown.cells, prev.cells)
	w := prev.w
	blank := Cell{ch = ' ', width = 1}
	k := abs(plan.amount)
	strings.write_string(b, "\x1b[0m\x1b[")
	strings.write_int(b, plan.top + 1)
	strings.write_byte(b, ';')
	strings.write_int(b, plan.bottom + 1)
	strings.write_byte(b, 'r')
	if plan.amount > 0 {
		write_move(b, 0, plan.bottom)
		for _ in 0 ..< k do strings.write_byte(b, '\n')
		for y in plan.top ..= plan.bottom {
			src := y + k
			for x in 0 ..< w do shown.cells[y * w + x] = src <= plan.bottom ? prev.cells[src * w + x] : blank
		}
	} else {
		write_move(b, 0, plan.top)
		for _ in 0 ..< k do strings.write_string(b, "\x1bM")
		for y := plan.bottom; y >= plan.top; y -= 1 {
			src := y - k
			for x in 0 ..< w do shown.cells[y * w + x] = src >= plan.top ? prev.cells[src * w + x] : blank
		}
	}
	strings.write_string(b, "\x1b[r")
	return shown
}

// render_diff writes the bytes that turn `prev` into `next` on screen.
// When full is true (first frame, resize) every cell is emitted.
// prev and next must have equal dimensions unless full is set.
render_diff :: proc(b: ^strings.Builder, prev, next: ^Frame, full: bool, caps: Caps) {
	full := full
	if prev == nil || prev.w != next.w || prev.h != next.h do full = true
	if !caps.no_sync do strings.write_string(b, "\x1b[?2026h") // begin synchronized update
	strings.write_string(b, "\x1b[?25l")
	if full do strings.write_string(b, "\x1b[0m\x1b[2J")

	base := prev
	shown: Frame
	cur := _Cursor{-1, -1}
	cur_pen: Pen
	pen_known := false
	if !full && !caps.no_scroll {
		if plan, ok := plan_scroll(prev, next); ok {
			shown = _apply_scroll(b, prev, plan)
			base = &shown
			pen_known = true // reset by the scroll
		}
	}

	for y in 0 ..< next.h {
		row := y * next.w
		for x in 0 ..< next.w {
			c := next.cells[row + x]
			if c.width == 0 do continue
			if !full && base.cells[row + x] == c {
				// A wide glyph whose tail changed must be re-emitted too.
				if !(c.width == 2 && x + 1 < next.w && base.cells[row + x + 1] != next.cells[row + x + 1]) {
					continue
				}
			}
			_move(b, &cur, x, y, next, cur_pen, pen_known)
			if !pen_known {
				write_sgr(b, c.pen, caps, next.theme)
				cur_pen, pen_known = c.pen, true
			} else if cur_pen != c.pen {
				write_sgr_delta(b, cur_pen, c.pen, caps, next.theme)
				cur_pen = c.pen
			}
			if c.ch == 0 || c.ch < 0x20 {
				strings.write_byte(b, ' ')
			} else {
				write_cell_text(b, c)
			}
			cur.x = x + int(c.width)
			if cur.x > next.w do cur.x = -1 // a clipped wide glyph: position unknown
		}
	}
	strings.write_string(b, "\x1b[0m")
	if next.cursor.show {
		write_move(b, next.cursor.x, next.cursor.y)
		strings.write_string(b, "\x1b[?25h")
	}
	if !caps.no_sync do strings.write_string(b, "\x1b[?2026l") // end synchronized update
}

// render_inline redraws a frame in-place below the shell prompt. The cursor
// is expected at the region's top-left and is returned there afterwards.
render_inline :: proc(b: ^strings.Builder, f: ^Frame, caps: Caps) {
	if !caps.no_sync do strings.write_string(b, "\x1b[?2026h")
	strings.write_string(b, "\x1b[?25l\r")
	_write_rows(b, f, caps, "\x1b[0m\x1b[K\r\n")
	strings.write_string(b, "\x1b[0m\x1b[K")
	if f.h > 1 {
		strings.write_string(b, "\x1b[")
		_write_int(b, f.h - 1)
		strings.write_byte(b, 'A')
	}
	strings.write_byte(b, '\r')
	if f.cursor.show {
		if f.cursor.y > 0 {
			strings.write_string(b, "\x1b[")
			_write_int(b, f.cursor.y)
			strings.write_byte(b, 'B')
		}
		if f.cursor.x > 0 {
			strings.write_string(b, "\x1b[")
			_write_int(b, f.cursor.x)
			strings.write_byte(b, 'C')
		}
		strings.write_string(b, "\x1b[?25h")
	}
	if !caps.no_sync do strings.write_string(b, "\x1b[?2026l")
}

@(private)
_write_rows :: proc(b: ^strings.Builder, f: ^Frame, caps: Caps, row_sep: string) {
	for y in 0 ..< f.h {
		pen_known := false
		cur: Pen
		for x in 0 ..< f.w {
			c := f.cells[y * f.w + x]
			if c.width == 0 do continue
			if !pen_known || cur != c.pen {
				write_sgr(b, c.pen, caps, f.theme)
				cur, pen_known = c.pen, true
			}
			if c.ch == 0 || c.ch < 0x20 {
				strings.write_byte(b, ' ')
			} else {
				write_cell_text(b, c)
			}
		}
		if y < f.h - 1 do strings.write_string(b, row_sep)
	}
}

// frame_to_ansi renders a whole frame as printable ANSI text (for piping to
// stdout, e.g. `galdr design`). Rows end with a reset and a newline.
frame_to_ansi :: proc(f: ^Frame, caps: Caps, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	_write_rows(&b, f, caps, "\x1b[0m\n")
	strings.write_string(&b, "\x1b[0m\n")
	return strings.to_string(b)
}

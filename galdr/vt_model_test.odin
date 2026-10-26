package galdr

import "core:fmt"
import "core:math/rand"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

// A minimal VT emulator: just enough of xterm to interpret what the renderer
// emits (CUP, CUF, CR, LF, RI, DECSTBM, SGR incl. deltas, ED, EL, modes).
// The round-trip property: render(prev → next) applied to a screen showing
// prev must produce a screen that shows next, cell for cell.

@(private = "file")
VT :: struct {
	w, h:       int,
	cells:      []Cell,
	x, y:       int,
	pen:        Pen,
	top, bot:   int, // scroll margins (inclusive)
	pending_wrap: bool,
}

@(private = "file")
vt_make :: proc(w, h: int) -> VT {
	v := VT{w = w, h = h, bot = h - 1}
	v.cells = make([]Cell, w * h, context.temp_allocator)
	for &c in v.cells do c = BLANK
	return v
}

@(private = "file")
vt_blank :: proc(v: ^VT) -> Cell {
	// Erased cells take the current background (xterm's bce behavior).
	return Cell{ch = ' ', width = 1, pen = {bg = v.pen.bg}}
}

@(private = "file")
vt_scroll_up :: proc(v: ^VT, n: int) {
	for _ in 0 ..< n {
		for y in v.top ..< v.bot do copy(v.cells[y * v.w:(y + 1) * v.w], v.cells[(y + 1) * v.w:(y + 2) * v.w])
		for x in 0 ..< v.w do v.cells[v.bot * v.w + x] = vt_blank(v)
	}
}

@(private = "file")
vt_scroll_down :: proc(v: ^VT, n: int) {
	for _ in 0 ..< n {
		for y := v.bot; y > v.top; y -= 1 do copy(v.cells[y * v.w:(y + 1) * v.w], v.cells[(y - 1) * v.w:y * v.w])
		for x in 0 ..< v.w do v.cells[v.top * v.w + x] = vt_blank(v)
	}
}

@(private = "file")
vt_params :: proc(body: string) -> [dynamic]int {
	out := make([dynamic]int, context.temp_allocator)
	if body == "" do return out
	for p in strings.split(body, ";", context.temp_allocator) {
		n, _ := strconv.parse_int(p)
		append(&out, n)
	}
	return out
}

@(private = "file")
vt_sgr :: proc(v: ^VT, body: string) {
	ps := vt_params(body)
	if len(ps) == 0 do append(&ps, 0)
	for i := 0; i < len(ps); i += 1 {
		p := ps[i]
		switch p {
		case 0:  v.pen = {}
		case 1:  v.pen.attrs += {.Bold}
		case 2:  v.pen.attrs += {.Dim}
		case 3:  v.pen.attrs += {.Italic}
		case 4:  v.pen.attrs += {.Underline}
		case 5:  v.pen.attrs += {.Blink}
		case 7:  v.pen.attrs += {.Reverse}
		case 9:  v.pen.attrs += {.Strike}
		case 22: v.pen.attrs -= {.Bold, .Dim}
		case 23: v.pen.attrs -= {.Italic}
		case 24: v.pen.attrs -= {.Underline}
		case 25: v.pen.attrs -= {.Blink}
		case 27: v.pen.attrs -= {.Reverse}
		case 29: v.pen.attrs -= {.Strike}
		case 39: v.pen.fg = {}
		case 49: v.pen.bg = {}
		case 38, 48:
			c: Color
			if ps[i + 1] == 2 {
				c = rgb(u8(ps[i + 2]), u8(ps[i + 3]), u8(ps[i + 4]))
				i += 4
			} else {
				c = indexed(u8(ps[i + 2]))
				i += 2
			}
			if p == 38 do v.pen.fg = c
			else do v.pen.bg = c
		}
	}
}

@(private = "file")
vt_feed :: proc(v: ^VT, data: string) {
	i := 0
	for i < len(data) {
		b := data[i]
		switch b {
		case 0x1b:
			if data[i + 1] == 'M' { // RI: reverse index
				if v.y == v.top do vt_scroll_down(v, 1)
				else do v.y = max(v.y - 1, 0)
				i += 2
				continue
			}
			assert(data[i + 1] == '[', "only CSI and RI are expected")
			j := i + 2
			for !(data[j] >= 0x40 && data[j] <= 0x7e) do j += 1
			body, final := data[i + 2:j], data[j]
			i = j + 1
			private := len(body) > 0 && body[0] == '?'
			if private do continue // ?25, ?2026 ... don't change the grid
			ps := vt_params(body)
			arg :: proc(ps: [dynamic]int, k: int, def: int) -> int {
				return k < len(ps) && ps[k] != 0 ? ps[k] : def
			}
			v.pending_wrap = false
			switch final {
			case 'H':
				v.y = clamp(arg(ps, 0, 1) - 1, 0, v.h - 1)
				v.x = clamp(arg(ps, 1, 1) - 1, 0, v.w - 1)
			case 'C': v.x = min(v.x + arg(ps, 0, 1), v.w - 1)
			case 'A': v.y = max(v.y - arg(ps, 0, 1), 0)
			case 'B': v.y = min(v.y + arg(ps, 0, 1), v.h - 1)
			case 'm': vt_sgr(v, body)
			case 'r':
				v.top = arg(ps, 0, 1) - 1
				v.bot = arg(ps, 1, v.h) - 1
				v.x, v.y = 0, 0
			case 'J':
				if arg(ps, 0, 0) == 2 do for &c in v.cells do c = vt_blank(v)
			case 'K':
				for x in v.x ..< v.w do v.cells[v.y * v.w + x] = vt_blank(v)
			case 'S': vt_scroll_up(v, arg(ps, 0, 1))
			case 'T': vt_scroll_down(v, arg(ps, 0, 1))
			case: panic(fmt.tprintf("unexpected CSI %q", final))
			}
		case '\r':
			v.x = 0
			v.pending_wrap = false
			i += 1
		case '\n':
			if v.y == v.bot do vt_scroll_up(v, 1)
			else do v.y = min(v.y + 1, v.h - 1)
			v.pending_wrap = false
			i += 1
		case:
			// A glyph. A clustering terminal segments by UAX #29 (escape
			// sequences are Controls, so they always end a cluster); a legacy
			// one attaches zero-width codepoints to the previous character.
			start := i
			end: int
			if width_mode == .Grapheme {
				end = grapheme_end(data, start)
			} else {
				_, n0 := utf8.decode_rune_in_string(data[start:])
				end = start + n0
				for end < len(data) {
					r2, n2 := utf8.decode_rune_in_string(data[end:])
					if r2 < 0x20 || rune_width(r2) != 0 do break
					end += n2
				}
			}
			glyph := data[start:end]
			i = end
			if v.pending_wrap {
				v.x = 0
				if v.y == v.bot do vt_scroll_up(v, 1)
				else do v.y += 1
				v.pending_wrap = false
			}
			cell := Cell{pen = v.pen}
			k := -1
			for r in glyph {
				if k < 0 do cell.ch = r
				else if k < MAX_CLUSTER_EXTRA do cell.ext[k] = r
				k += 1
			}
			cell.width = u8(max(cluster_width(glyph), 1))
			v.cells[v.y * v.w + v.x] = cell
			if cell.width == 2 && v.x + 1 < v.w {
				v.cells[v.y * v.w + v.x + 1] = {ch = 0, width = 0, pen = v.pen}
			}
			v.x += int(cell.width)
			if v.x >= v.w {
				v.x = v.w - 1
				v.pending_wrap = true
			}
		}
	}
}

// Compare the emulated screen with a frame: glyph, width and pen per cell.
@(private = "file")
vt_matches :: proc(t: ^testing.T, v: ^VT, f: ^Frame, label: string) -> bool {
	for y in 0 ..< f.h {
		for x in 0 ..< f.w {
			want := f.cells[y * f.w + x]
			got := v.cells[y * v.w + x]
			if want.width == 0 && got.width == 0 do continue
			if want.ch == 0 do want.ch = ' '
			if want.ch != got.ch || want.ext != got.ext || want.width != got.width || want.pen != got.pen {
				testing.expectf(t, false, "%s: cell (%d,%d) want %q%v %v w%d, got %q%v %v w%d",
					label, x, y, want.ch, want.ext, want.pen.attrs, want.width, got.ch, got.ext, got.pen.attrs, got.width)
				return false
			}
		}
	}
	return true
}

// ------------------------------------------------------------ random frames

@(private = "file")
GLYPHS := [?]string{"a", "b", "Z", "7", " ", ".", "─", "█", "日", "本", "é", "é", "🚀", "\U0001F468‍\U0001F469"}

@(private = "file")
random_pen :: proc(th: ^Theme) -> Pen {
	colors := [?]Color{th.bg, th.surface, th.ink, th.tones[.Primary], th.tones[.Danger], NO_COLOR}
	p := Pen{fg = rand.choice(colors[:]), bg = rand.choice(colors[:])}
	for a in Attr do if rand.float32() < 0.12 do p.attrs += {a}
	if p.fg.mode == .Default do p.fg = th.ink
	if p.bg.mode == .Default do p.bg = th.bg
	return p
}

@(private = "file")
random_paint :: proc(f: ^Frame, th: ^Theme) {
	frame_reset(f)
	for _ in 0 ..< rand.int_max(12) + 1 {
		r := Rect{rand.int_max(f.w), rand.int_max(f.h), rand.int_max(f.w) + 1, rand.int_max(f.h) + 1}
		fill(f, r, random_pen(th))
	}
	for _ in 0 ..< rand.int_max(30) {
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< rand.int_max(12) + 1 do strings.write_string(&b, rand.choice(GLYPHS[:]))
		text(f, rand.int_max(f.w), rand.int_max(f.h), strings.to_string(b), random_pen(th))
	}
}

// Next frame = prev scrolled by k rows inside a band, with a few edits:
// the pattern pagers and logs produce.
@(private = "file")
scrolled_copy :: proc(prev, next: ^Frame, th: ^Theme) {
	copy(next.cells, prev.cells)
	top := rand.int_max(max(prev.h / 3, 1))
	bot := prev.h - rand.int_max(max(prev.h / 3, 1)) // exclusive
	k := rand.int_max(3) + 1
	if bot - top <= k do return
	up := rand.float32() < 0.5
	for y in top ..< bot {
		src := up ? y + k : y - k
		for x in 0 ..< prev.w {
			next.cells[y * next.w + x] = src >= top && src < bot ? prev.cells[src * prev.w + x] : Cell{ch = ' ', width = 1, pen = {fg = th.ink, bg = th.surface}}
		}
	}
	for _ in 0 ..< rand.int_max(3) do text(next, rand.int_max(next.w), rand.int_max(next.h), rand.choice(GLYPHS[:]), random_pen(th))
}

@(private = "file")
round_trip :: proc(t: ^testing.T, mode: Width_Mode, iterations: int, caps: Caps) {
	saved := width_mode
	width_mode = mode
	defer width_mode = saved
	th := theme_nightfall()
	w, h := 24, 10
	prev := frame_make(w, h, &th, context.temp_allocator)
	next := frame_make(w, h, &th, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	scrolls := 0
	defer testing.expectf(t, scrolls > iterations / 20, "scroll optimization exercised (%d of %d)", scrolls, iterations / 2)
	for i in 0 ..< iterations {
		vt := vt_make(w, h)
		random_paint(&prev, &th)
		strings.builder_reset(&sb)
		render_diff(&sb, nil, &prev, true, caps)
		vt_feed(&vt, strings.to_string(sb))
		if !vt_matches(t, &vt, &prev, fmt.tprintf("full render #%d", i)) do return

		if i % 2 == 0 {
			scrolled_copy(&prev, &next, &th)
			if _, ok := plan_scroll(&prev, &next); ok do scrolls += 1
		} else {
			random_paint(&next, &th)
		}
		strings.builder_reset(&sb)
		render_diff(&sb, &prev, &next, false, caps)
		vt_feed(&vt, strings.to_string(sb))
		if !vt_matches(t, &vt, &next, fmt.tprintf("diff render #%d (%s)", i, i % 2 == 0 ? "scroll" : "random")) do return
	}
}

@(test)
test_render_round_trip_legacy :: proc(t: ^testing.T) {
	round_trip(t, .Legacy, 400, {depth = .True_Color})
}

@(test)
test_render_round_trip_graphemes :: proc(t: ^testing.T) {
	round_trip(t, .Grapheme, 400, {depth = .True_Color})
}

package galdr

// Borders and Blocks: the declarative styling layer. A Block describes
// padding, border, title and fill; `block` draws it and hands back the
// content rect. `paragraph` flows styled text inside a rect.

Border :: enum u8 {
	None,
	Rounded,
	Sharp,
	Thick,
	Double,
	Dashed,
	Heavy_Dashed,
	Block,
	Inner_Half, // ▗▄▖ ▐ ▌ ▝▀▘ — reads as a filled card edge
	Ascii,
}

// Glyph order: top-left, top, top-right, right, bottom-right, bottom, bottom-left, left.
Border_Glyphs :: [8]rune

border_glyphs :: proc "contextless" (b: Border) -> Border_Glyphs {
	switch b {
	case .None:         return {' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '}
	case .Rounded:      return {'╭', '─', '╮', '│', '╯', '─', '╰', '│'}
	case .Sharp:        return {'┌', '─', '┐', '│', '┘', '─', '└', '│'}
	case .Thick:        return {'┏', '━', '┓', '┃', '┛', '━', '┗', '┃'}
	case .Double:       return {'╔', '═', '╗', '║', '╝', '═', '╚', '║'}
	case .Dashed:       return {'┌', '╌', '┐', '╎', '┘', '╌', '└', '╎'}
	case .Heavy_Dashed: return {'┏', '╍', '┓', '╏', '┛', '╍', '┗', '╏'}
	case .Block:        return {'█', '▀', '█', '█', '█', '▄', '█', '█'}
	case .Inner_Half:   return {'▗', '▄', '▖', '▌', '▘', '▀', '▝', '▐'}
	case .Ascii:        return {'+', '-', '+', '|', '+', '-', '+', '|'}
	}
	return {}
}

// border_parse maps a name ("rounded", "thick", ...) to a Border.
border_parse :: proc(name: string) -> (Border, bool) {
	switch name {
	case "none":         return .None, true
	case "rounded":      return .Rounded, true
	case "sharp", "normal": return .Sharp, true
	case "thick":        return .Thick, true
	case "double":       return .Double, true
	case "dashed":       return .Dashed, true
	case "heavy-dashed": return .Heavy_Dashed, true
	case "block":        return .Block, true
	case "half", "inner-half": return .Inner_Half, true
	case "ascii":        return .Ascii, true
	}
	return .None, false
}

// stroke draws a border around r. Returns the interior rect.
stroke :: proc(f: ^Frame, r: Rect, b: Border, p: Pen) -> Rect {
	if b == .None || r.w < 2 || r.h < 2 do return r
	g := border_glyphs(b)
	x1, y1 := r.x + r.w - 1, r.y + r.h - 1
	put(f, r.x, r.y, g[0], p)
	put(f, x1, r.y, g[2], p)
	put(f, x1, y1, g[4], p)
	put(f, r.x, y1, g[6], p)
	for x in r.x + 1 ..< x1 {
		put(f, x, r.y, g[1], p)
		put(f, x, y1, g[5], p)
	}
	for y in r.y + 1 ..< y1 {
		put(f, x1, y, g[3], p)
		put(f, r.x, y, g[7], p)
	}
	return inset(r, 1)
}

Block :: struct {
	border:       Border,
	border_pen:   Pen,
	fill:         Color, // NO_COLOR = leave background as is
	title:        string,
	title_pen:    Pen,
	title_align:  Align,
	footer:       string,
	footer_pen:   Pen,
	footer_align: Align,
	pad_x, pad_y: int,
}

// block draws the box described by b and returns the content rect.
block :: proc(f: ^Frame, r: Rect, b: Block) -> Rect {
	if r.w <= 0 || r.h <= 0 do return {r.x, r.y, 0, 0}
	if b.fill.mode != .Default do fill(f, r, {bg = b.fill})
	inner := stroke(f, r, b.border, b.border_pen)
	has_edge := b.border != .None && r.w >= 2 && r.h >= 2
	if has_edge && b.title != "" {
		_edge_label(f, r, r.y, b.title, b.title_pen, b.title_align)
	}
	if has_edge && b.footer != "" {
		_edge_label(f, r, r.y + r.h - 1, b.footer, b.footer_pen, b.footer_align)
	}
	return inset(inner, b.pad_x, b.pad_y)
}

@(private)
_edge_label :: proc(f: ^Frame, r: Rect, y: int, label: string, p: Pen, align: Align) {
	room := r.w - 4
	if room <= 2 do return
	s := truncate(label, room - 2)
	w := text_width(s) + 2
	x := r.x + 2
	switch align {
	case .Left:
	case .Center: x = r.x + (r.w - w) / 2
	case .Right:  x = r.x + r.w - 2 - w
	}
	put(f, x, y, ' ', p)
	text(f, x + 1, y, s, p)
	put(f, x + 1 + text_width(s), y, ' ', p)
}

// paragraph word-wraps s into r with the given alignment. Returns rows used.
paragraph :: proc(f: ^Frame, r: Rect, s: string, p: Pen, align: Align = .Left) -> int {
	lines := wrap(s, r.w)
	n := min(len(lines), r.h)
	for i in 0 ..< n {
		text_aligned(f, r.x, r.y + i, r.w, lines[i], p, align)
	}
	return n
}

// measure_paragraph reports how many rows s needs at width w.
measure_paragraph :: proc(s: string, w: int) -> int {
	return len(wrap(s, w))
}

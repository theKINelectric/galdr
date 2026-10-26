package galdr

// Layout is plain arithmetic over Rects: constraint splits plus "cut" helpers
// that carve pieces off a rect you own.

Size_Kind :: enum u8 {
	Fixed,   // exactly n cells
	Percent, // n percent of the available space
	Fill,    // share of what remains, weighted by n
}

Size :: struct {
	kind: Size_Kind,
	n:    int,
}

fixed :: proc "contextless" (n: int) -> Size { return {.Fixed, n} }
percent :: proc "contextless" (n: int) -> Size { return {.Percent, n} }
grow :: proc "contextless" (weight := 1) -> Size { return {.Fill, max(weight, 1)} }

Axis :: enum u8 {
	Horizontal, // children side by side (columns)
	Vertical,   // children stacked (rows)
}

// split divides r along axis. gap cells are left between children.
// Result is allocated in the temp allocator.
split :: proc(r: Rect, axis: Axis, sizes: []Size, gap := 0) -> []Rect {
	n := len(sizes)
	out := make([]Rect, n, context.temp_allocator)
	if n == 0 do return out
	total := axis == .Horizontal ? r.w : r.h
	avail := max(0, total - gap * (n - 1))

	lengths := make([]int, n, context.temp_allocator)
	used := 0
	weights := 0
	for s, i in sizes {
		switch s.kind {
		case .Fixed:   lengths[i] = max(0, s.n)
		case .Percent: lengths[i] = avail * clamp(s.n, 0, 100) / 100
		case .Fill:    weights += s.n
		}
		used += lengths[i]
	}
	// Over-subscribed: shrink fixed/percent pieces from the end.
	for i := n - 1; used > avail && i >= 0; i -= 1 {
		take := min(lengths[i], used - avail)
		lengths[i] -= take
		used -= take
	}
	remaining := avail - used
	if weights > 0 {
		given := 0
		last_fill := -1
		for s, i in sizes {
			if s.kind != .Fill do continue
			lengths[i] = remaining * s.n / weights
			given += lengths[i]
			last_fill = i
		}
		lengths[last_fill] += remaining - given // rounding slack to the last filler
	}

	pos := axis == .Horizontal ? r.x : r.y
	for i in 0 ..< n {
		if axis == .Horizontal {
			out[i] = {pos, r.y, lengths[i], r.h}
		} else {
			out[i] = {r.x, pos, r.w, lengths[i]}
		}
		pos += lengths[i] + gap
	}
	return out
}

columns :: proc(r: Rect, sizes: []Size, gap := 0) -> []Rect {
	return split(r, .Horizontal, sizes, gap)
}

rows :: proc(r: Rect, sizes: []Size, gap := 0) -> []Rect {
	return split(r, .Vertical, sizes, gap)
}

inset :: proc "contextless" (r: Rect, dx: int, dy := -1) -> Rect {
	dy := dy < 0 ? dx : dy
	return {r.x + dx, r.y + dy, max(0, r.w - 2 * dx), max(0, r.h - 2 * dy)}
}

center :: proc "contextless" (r: Rect, w, h: int) -> Rect {
	cw, ch := min(w, r.w), min(h, r.h)
	return {r.x + (r.w - cw) / 2, r.y + (r.h - ch) / 2, cw, ch}
}

// cut_* carve n cells off one side of r, shrinking r, and return the piece.
cut_top :: proc "contextless" (r: ^Rect, n: int) -> Rect {
	k := clamp(n, 0, r.h)
	out := Rect{r.x, r.y, r.w, k}
	r.y += k
	r.h -= k
	return out
}

cut_bottom :: proc "contextless" (r: ^Rect, n: int) -> Rect {
	k := clamp(n, 0, r.h)
	r.h -= k
	return {r.x, r.y + r.h, r.w, k}
}

cut_left :: proc "contextless" (r: ^Rect, n: int) -> Rect {
	k := clamp(n, 0, r.w)
	out := Rect{r.x, r.y, k, r.h}
	r.x += k
	r.w -= k
	return out
}

cut_right :: proc "contextless" (r: ^Rect, n: int) -> Rect {
	k := clamp(n, 0, r.w)
	r.w -= k
	return {r.x + r.w, r.y, k, r.h}
}

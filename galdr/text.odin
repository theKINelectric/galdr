package galdr

import "core:strings"
import "core:unicode/utf8"

// ------------------------------------------------------------ widths

// How the terminal measures text. Legacy terminals advance the cursor per
// codepoint (wcwidth); terminals with grapheme clustering (DEC mode 2027)
// advance per extended grapheme cluster. The session sets this after
// probing; everything that measures or draws text follows it.
//
// It is thread-local: the UI thread's value is set by the session, and the
// task hub hands the same value to each spawned task.
Width_Mode :: enum u8 {
	Legacy,   // the zero value, so fresh threads start here
	Grapheme,
}

@(thread_local)
width_mode: Width_Mode

@(private)
_in_ranges :: proc "contextless" (table: []$T, r: rune) -> int {
	c := u32(r)
	lo, hi := 0, len(table) - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		if c < table[mid][0] {
			hi = mid - 1
		} else if c > table[mid][1] {
			lo = mid + 1
		} else {
			return mid
		}
	}
	return -1
}

@(private)
_is_control :: proc "contextless" (r: rune) -> bool {
	return r < 0x20 || (r >= 0x7f && r < 0xa0)
}

// Display width of a single codepoint in cells: 0, 1 or 2 (Unicode 16 tables).
rune_width :: proc "contextless" (r: rune) -> int {
	if r < 0x20 || (r >= 0x7f && r < 0xa0) do return 0
	if r < 0x300 do return 1 // fast path: Latin and friends
	if _in_ranges(_ZERO[:], r) >= 0 do return 0
	if _in_ranges(_WIDE[:], r) >= 0 do return 2
	return 1
}

grapheme_break_of :: proc "contextless" (r: rune) -> Grapheme_Break {
	i := _in_ranges(_GBP[:], r)
	return i < 0 ? .Other : Grapheme_Break(_GBP[i][2])
}

@(private)
_is_extpict :: proc "contextless" (r: rune) -> bool {
	return r >= 0xA9 && _in_ranges(_EXTPICT[:], r) >= 0
}

@(private)
_incb :: proc "contextless" (r: rune) -> InCB {
	if r < 0x300 do return .None
	i := _in_ranges(_INCB[:], r)
	return i < 0 ? .None : InCB(_INCB[i][2])
}

// grapheme_end returns the byte index where the extended grapheme cluster
// starting at `start` ends (UAX #29, rules GB3–GB13).
grapheme_end :: proc(s: string, start: int) -> int {
	if start >= len(s) do return len(s)
	r0, n0 := utf8.decode_rune_in_string(s[start:])
	i := start + n0
	prev := grapheme_break_of(r0)
	ri_run := prev == .Regional_Indicator ? 1 : 0
	emoji := _is_extpict(r0) ? 1 : 0 // 1: ExtPict Extend*   2: ... ZWJ
	incb_cons := _incb(r0) == .Consonant
	incb_link := false
	for i < len(s) {
		r, n := utf8.decode_rune_in_string(s[i:])
		cur := grapheme_break_of(r)
		joins := false
		switch {
		case prev == .CR && cur == .LF:                                  joins = true  // GB3
		case prev == .Control || prev == .CR || prev == .LF:             joins = false // GB4
		case cur == .Control || cur == .CR || cur == .LF:                joins = false // GB5
		case prev == .L && (cur == .L || cur == .V || cur == .LV || cur == .LVT): joins = true // GB6
		case (prev == .LV || prev == .V) && (cur == .V || cur == .T):   joins = true  // GB7
		case (prev == .LVT || prev == .T) && cur == .T:                  joins = true  // GB8
		case cur == .Extend || cur == .ZWJ:                              joins = true  // GB9
		case cur == .SpacingMark:                                        joins = true  // GB9a
		case prev == .Prepend:                                           joins = true  // GB9b
		case incb_cons && incb_link && _incb(r) == .Consonant:           joins = true  // GB9c
		case emoji == 2 && _is_extpict(r):                               joins = true  // GB11
		case prev == .Regional_Indicator && cur == .Regional_Indicator && ri_run % 2 == 1: joins = true // GB12/13
		}
		if !joins do break

		ri_run = cur == .Regional_Indicator ? ri_run + 1 : 0
		switch {
		case _is_extpict(r):                  emoji = 1
		case emoji == 1 && cur == .Extend:    // stays 1
		case emoji == 1 && cur == .ZWJ:       emoji = 2
		case:                                 emoji = 0
		}
		switch ic := _incb(r); {
		case ic == .Consonant:                 incb_cons, incb_link = true, false
		case incb_cons && ic == .Linker:       incb_link = true
		case incb_cons && ic == .Extend:       // keep state
		case:                                  incb_cons, incb_link = false, false
		}
		prev = cur
		i += n
	}
	return i
}

// cluster_width is the width of one grapheme cluster under the given mode.
cluster_width :: proc(cluster: string, mode := width_mode) -> int {
	if mode == .Legacy {
		w := 0
		for r in cluster do w += rune_width(r)
		return w
	}
	first, _ := utf8.decode_rune_in_string(cluster)
	w := rune_width(first)
	for r in cluster {
		switch {
		case r == 0xFE0F: w = 2                               // emoji presentation
		case r >= 0x1F1E6 && r <= 0x1F1FF && w > 0: w = 2     // flags
		}
	}
	return min(w, 2)
}

// next_glyph returns the next unit that occupies cells: a whole grapheme
// cluster in Grapheme mode, or a codepoint plus its zero-width followers in
// Legacy mode (exactly what a wcwidth terminal does). ok is false at the end.
next_glyph :: proc(s: string, i: int, mode := width_mode) -> (glyph: string, width: int, next: int, ok: bool) {
	if i >= len(s) do return "", 0, i, false
	if mode == .Grapheme {
		end := grapheme_end(s, i)
		return s[i:end], cluster_width(s[i:end], .Grapheme), end, true
	}
	r, n := utf8.decode_rune_in_string(s[i:])
	end := i + n
	for end < len(s) {
		r2, n2 := utf8.decode_rune_in_string(s[end:])
		if rune_width(r2) != 0 || _is_control(r2) do break
		end += n2
	}
	return s[i:end], rune_width(r), end, true
}

// Display width of a string in cells.
text_width :: proc(s: string) -> int {
	w := 0
	for i := 0; i < len(s); {
		_, gw, next, _ := next_glyph(s, i)
		w += gw
		i = next
	}
	return w
}

// truncate clips s to at most width cells, adding an ellipsis when clipped.
truncate :: proc(s: string, width: int, ellipsis := "…") -> string {
	if width <= 0 do return ""
	if text_width(s) <= width do return s
	ew := text_width(ellipsis)
	if ew >= width do return _clip(ellipsis, width)
	return strings.concatenate({_clip(s, width - ew), ellipsis}, context.temp_allocator)
}

// _clip returns the longest prefix of s that fits in width cells.
@(private)
_clip :: proc(s: string, width: int) -> string {
	w := 0
	for i := 0; i < len(s); {
		_, gw, next, _ := next_glyph(s, i)
		if w + gw > width do return s[:i]
		w += gw
		i = next
	}
	return s
}

// clip_to_width is the public form of the prefix clip (no ellipsis).
clip_to_width :: proc(s: string, width: int) -> string {
	return _clip(s, width)
}

// pad_right pads s with spaces to exactly width cells (clipping if longer).
pad_right :: proc(s: string, width: int) -> string {
	clipped := _clip(s, width)
	w := text_width(clipped)
	if w >= width do return clipped
	return strings.concatenate({clipped, strings.repeat(" ", width - w, context.temp_allocator)}, context.temp_allocator)
}

// wrap word-wraps text to width cells. Explicit newlines are honored and
// words longer than width are hard-broken. Result lives in the temp allocator.
wrap :: proc(text: string, width: int, allocator := context.temp_allocator) -> []string {
	lines := make([dynamic]string, 0, 8, allocator)
	if width <= 0 do return lines[:]
	rest := text
	for para in strings.split_lines_iterator(&rest) {
		if len(strings.trim_space(para)) == 0 {
			append(&lines, "")
			continue
		}
		line_start := -1 // byte index in para
		line_end := 0
		line_w := 0
		i := 0
		for i < len(para) {
			// skip spaces
			for i < len(para) && para[i] == ' ' do i += 1
			if i >= len(para) do break
			word_start := i
			word_w := 0
			for i < len(para) && para[i] != ' ' {
				_, gw, next, _ := next_glyph(para, i)
				word_w += gw
				i = next
			}
			word := para[word_start:i]
			if line_start >= 0 && line_w + 1 + word_w <= width {
				line_end = i
				line_w += 1 + word_w
				continue
			}
			if line_start >= 0 {
				append(&lines, para[line_start:line_end])
				line_start = -1
			}
			// hard-break words that are too long on their own
			for text_width(word) > width {
				head := _clip(word, width)
				if len(head) == 0 { // single glyph wider than the column
					_, _, next, _ := next_glyph(word, 0)
					head = word[:next]
				}
				append(&lines, head)
				word = word[len(head):]
			}
			line_start = i - len(word)
			line_end = i
			line_w = text_width(word)
		}
		if line_start >= 0 do append(&lines, para[line_start:line_end])
	}
	return lines[:]
}

// sanitize removes C0/C1 control characters and DEL, so a string can be
// embedded in an escape sequence (window title, hyperlink) without injecting
// its own sequences. Frames never need this: control runes have zero width
// and are dropped when drawn.
sanitize :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	for r in s {
		if r < 0x20 || (r >= 0x7f && r <= 0x9f) do continue
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

// Glyph_Span is one drawn unit inside a rune slice: runes [start, end) that
// occupy `width` cells. Editors move and delete by these, so a cursor never
// lands inside an emoji sequence or between a letter and its accent.
Glyph_Span :: struct {
	start, end, width: int,
}

// glyph_spans splits runes into drawn units under the current width_mode.
// With a mask (passwords) every rune is its own unit.
glyph_spans :: proc(runes: []rune, mask: rune = 0, allocator := context.temp_allocator) -> []Glyph_Span {
	out := make([dynamic]Glyph_Span, 0, len(runes), allocator)
	if mask != 0 {
		w := rune_width(mask)
		for i in 0 ..< len(runes) do append(&out, Glyph_Span{i, i + 1, w})
		return out[:]
	}
	s := utf8.runes_to_string(runes, context.temp_allocator)
	ri := 0
	for bi := 0; bi < len(s); {
		glyph, gw, next, _ := next_glyph(s, bi)
		n := utf8.rune_count_in_string(glyph)
		append(&out, Glyph_Span{ri, ri + n, gw})
		ri += n
		bi = next
	}
	return out[:]
}

// span_at returns the index of the span containing rune index i (len at end).
span_at :: proc(spans: []Glyph_Span, i: int) -> int {
	for sp, k in spans do if i < sp.end do return k
	return len(spans)
}

// prev_boundary / next_boundary: the unit boundaries around rune index i.
prev_boundary :: proc(spans: []Glyph_Span, i: int) -> int {
	k := span_at(spans, i)
	if k < len(spans) && spans[k].start < i do return spans[k].start // inside: go to its start
	return k > 0 ? spans[k - 1].start : 0
}

next_boundary :: proc(spans: []Glyph_Span, i: int) -> int {
	k := span_at(spans, i)
	if k >= len(spans) do return i
	return spans[k].end
}

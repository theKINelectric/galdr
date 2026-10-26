package galdr

import "core:fmt"
import "core:slice"
import "core:unicode"
import "core:unicode/utf8"

// Fuzzy filtering: type to narrow a list. Matching is a case-insensitive
// subsequence; scoring prefers word starts, consecutive runs and early
// matches, so "ms" ranks "Mission Status" above "atoms".

// fuzzy_match scores text against pattern. positions (optional) receives the
// rune indices in text that matched, for highlighting.
fuzzy_match :: proc(pattern, text: string, positions: ^[dynamic]int = nil) -> (score: int, ok: bool) {
	if len(pattern) == 0 do return 0, true
	pat := utf8.string_to_runes(pattern, context.temp_allocator)
	runes := utf8.string_to_runes(text, context.temp_allocator)
	if positions != nil do clear(positions)

	// Greedy, but prefer a word-start occurrence of each pattern rune when one
	// exists before the next plain occurrence would force a worse path.
	p := 0
	last := -2
	for i := 0; i < len(runes) && p < len(pat); i += 1 {
		if unicode.to_lower(runes[i]) != unicode.to_lower(pat[p]) do continue
		if !_word_start(runes, i) && last != i - 1 {
			// Look ahead for a word-start match of the same rune.
			for j := i + 1; j < len(runes); j += 1 {
				if unicode.to_lower(runes[j]) == unicode.to_lower(pat[p]) && _word_start(runes, j) {
					if _subsequence_fits(pat[p + 1:], runes[j + 1:]) do i = j
					break
				}
			}
		}
		score += 16
		if _word_start(runes, i) do score += 24
		if i == 0 do score += 12
		if last == i - 1 do score += 18
		else if last >= 0 do score -= min(i - last - 1, 10)
		if runes[i] == pat[p] do score += 1 // exact case
		if positions != nil do append(positions, i)
		last = i
		p += 1
	}
	if p < len(pat) do return 0, false
	score -= len(runes) / 8 // shorter candidates rank a little higher
	return score, true
}

@(private)
_word_start :: proc(runes: []rune, i: int) -> bool {
	if i == 0 do return true
	prev, cur := runes[i - 1], runes[i]
	if prev == ' ' || prev == '_' || prev == '-' || prev == '/' || prev == '.' do return true
	// camelCase: lower→Upper followed by lower ("saveFile"), not "sAVe".
	next_lower := i + 1 >= len(runes) || unicode.is_lower(runes[i + 1])
	return unicode.is_lower(prev) && unicode.is_upper(cur) && next_lower
}

@(private)
_subsequence_fits :: proc(pat, runes: []rune) -> bool {
	p := 0
	for r in runes {
		if p == len(pat) do break
		if unicode.to_lower(r) == unicode.to_lower(pat[p]) do p += 1
	}
	return p == len(pat)
}

// ------------------------------------------------------------ Filter

Filter_Match :: struct {
	index: int, // into the caller's items
	score: int,
	first: int, // into Filter.positions
	count: int,
}

Filter :: struct {
	query:     Text_Field,
	list:      Pick_List,
	matches:   [dynamic]Filter_Match,
	positions: [dynamic]int,
	last:      string, // query the matches were computed for (owned)
	last_n:    int,    // item count they were computed for
	computed:  bool,
}

// filter_invalidate forces a recompute (call it when the items change).
filter_invalidate :: proc(fl: ^Filter) {
	fl.computed = false
}

filter_destroy :: proc(fl: ^Filter) {
	field_destroy(&fl.query)
	delete(fl.matches)
	delete(fl.positions)
	delete(fl.last)
}

// filter_update recomputes matches when the query (or item count) changed.
filter_update :: proc(fl: ^Filter, items: []string) {
	q := field_text(&fl.query)
	if fl.computed && q == fl.last && fl.last_n == len(items) do return
	delete(fl.last)
	fl.last = fmt.aprint(q)
	fl.last_n = len(items)
	fl.computed = true
	clear(&fl.matches)
	clear(&fl.positions)
	pos := make([dynamic]int, context.temp_allocator)
	for item, i in items {
		score, ok := fuzzy_match(q, item, &pos)
		if !ok do continue
		append(&fl.matches, Filter_Match{i, score, len(fl.positions), len(pos)})
		append(&fl.positions, ..pos[:])
	}
	if len(q) > 0 {
		slice.stable_sort_by(fl.matches[:], proc(a, b: Filter_Match) -> bool { return a.score > b.score })
	}
	fl.list.cursor = 0
	fl.list.offset = 0
}

// filter_on_key: arrows move the selection; everything else edits the query.
filter_on_key :: proc(fl: ^Filter, k: Key, items: []string) -> bool {
	switch {
	case k.code == .Up, k.code == .Down, k.code == .Page_Up, k.code == .Page_Down,
	     is_ctrl(k, 'p'), is_ctrl(k, 'n'):
		return pick_on_key(&fl.list, k, len(fl.matches))
	}
	if field_on_key(&fl.query, k) {
		filter_update(fl, items)
		return true
	}
	return false
}

// filter_selected returns the item index under the cursor.
filter_selected :: proc(fl: ^Filter) -> (index: int, ok: bool) {
	if fl.list.cursor < 0 || fl.list.cursor >= len(fl.matches) do return -1, false
	return fl.matches[fl.list.cursor].index, true
}

// filter_draw draws the query line, a match counter and the ranked list with
// matched characters highlighted.
filter_draw :: proc(f: ^Frame, r: Rect, fl: ^Filter, items: []string, focused := true, tone: Tone = .Primary) {
	th := f.theme
	filter_update(fl, items)
	if r.h < 2 do return
	counter := fmt.tprintf("%d/%d", len(fl.matches), len(items))
	field_draw(f, {r.x, r.y, r.w - text_width(counter) - 1, 1}, &fl.query, focused, tone)
	text(f, r.x + r.w - text_width(counter), r.y, counter, {fg = th.faint})
	Ctx :: struct {fl: ^Filter, items: []string, tone: Tone}
	ctx := Ctx{fl, items, tone}
	pick_draw_custom(f, {r.x, r.y + 1, r.w, r.h - 1}, &fl.list, len(fl.matches), proc(f: ^Frame, row: Rect, i: int, sel: bool, user: rawptr) {
		c := (^Ctx)(user)
		th := f.theme
		m := c.fl.matches[i]
		hits := c.fl.positions[m.first:m.first + m.count]
		base := sel ? Pen{fg = th.ink, attrs = {.Bold}} : Pen{fg = th.ink}
		hit := Pen{fg = th.tones[c.tone], attrs = {.Bold, .Underline}}
		item := c.items[m.index]
		x := row.x
		k := 0
		ri := 0
		// Walk glyphs, not runes, so clusters (emoji families, e + accent)
		// draw as one unit like everywhere else.
		for gi := 0; gi < len(item); {
			glyph, gw, next, _ := next_glyph(item, gi)
			gi = next
			n := utf8.rune_count_in_string(glyph)
			is_hit := false
			for j in 0 ..< n {
				if k < len(hits) && hits[k] == ri + j {
					is_hit = true
					k += 1
				}
			}
			if x + gw > row.x + row.w do break
			x += put_glyph(f, x, row.y, glyph, gw, is_hit ? hit : base)
			ri += n
		}
	}, &ctx, focused, tone)
}

// palette draws a command palette: a modal with a filter inside.
palette :: proc(f: ^Frame, fl: ^Filter, items: []string, title := "Commands", width := 60, height := 16) {
	inner := modal(f, min(width, f.w - 4), min(height, f.h - 2), title, .Primary, "⏎ run · esc close")
	filter_draw(f, inner, fl, items, true)
}

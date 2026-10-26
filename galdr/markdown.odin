package galdr

import "core:mem/virtual"
import "core:strings"

// Markdown → styled Lines, laid out for a given width. Covers the everyday
// subset: headings, paragraphs with **bold** *italic* `code` ~~strike~~ and
// [links](url), bullet / ordered / task lists, block quotes, fenced code,
// rules and pipe tables.

// Md_Doc owns everything it shows: a private copy of the source and every
// line, all in one arena. Re-render on resize or theme change by destroying
// the old doc and rendering a new one.
Md_Doc :: struct {
	lines: []Line,
	arena: ^virtual.Arena,
}

md_render :: proc(src: string, width: int, th: ^Theme) -> Md_Doc {
	arena := new(virtual.Arena)
	if virtual.arena_init_growing(arena) != nil {
		free(arena)
		return {}
	}
	alloc := virtual.arena_allocator(arena)
	own := strings.clone(src, alloc)
	return {lines = md_lines(own, width, th, alloc), arena = arena}
}

md_destroy :: proc(doc: ^Md_Doc) {
	if doc.arena != nil {
		virtual.arena_destroy(doc.arena)
		free(doc.arena)
	}
	doc^ = {}
}

// md_lines is the low-level form: strings in the result point into `src` or
// `allocator`, so keep both alive while you display the lines.
md_lines :: proc(src: string, width: int, th: ^Theme, allocator := context.allocator) -> []Line {
	context.allocator = allocator
	r := _Md{th = th, width = max(width, 10)}
	lines := strings.split_lines(src, context.temp_allocator)

	i := 0
	for i < len(lines) {
		raw := strings.trim_right(lines[i], " \t\r")
		trimmed := strings.trim_left_space(raw)
		indent := len(raw) - len(trimmed)

		switch {
		case trimmed == "":
			i += 1
			continue

		case strings.has_prefix(trimmed, "```") || strings.has_prefix(trimmed, "~~~"):
			fence := trimmed[:3]
			lang := strings.trim_space(trimmed[3:])
			i += 1
			start := i
			for i < len(lines) && !strings.has_prefix(strings.trim_left_space(lines[i]), fence) do i += 1
			_md_code(&r, lines[start:i], lang)
			if i < len(lines) do i += 1

		case _is_rule(trimmed):
			_md_gap(&r)
			append(&r.out, _line(Span{strings.repeat("─", r.width, allocator), {fg = th.line}}))
			i += 1

		case trimmed[0] == '#':
			level := 0
			for level < len(trimmed) && trimmed[level] == '#' do level += 1
			if level <= 6 && level < len(trimmed) && trimmed[level] == ' ' {
				_md_heading(&r, level, strings.trim_space(trimmed[level:]))
				i += 1
				continue
			}
			i = _md_paragraph(&r, lines, i)

		case trimmed[0] == '>':
			start := i
			for i < len(lines) && strings.has_prefix(strings.trim_left_space(lines[i]), ">") do i += 1
			_md_quote(&r, lines[start:i])

		case trimmed[0] == '|' && i + 1 < len(lines) && _is_table_sep(lines[i + 1]):
			start := i
			for i < len(lines) && strings.has_prefix(strings.trim_space(lines[i]), "|") do i += 1
			_md_table(&r, lines[start:i])

		case _list_marker(trimmed) > 0:
			i = _md_list_item(&r, lines, i, indent)

		case:
			i = _md_paragraph(&r, lines, i)
		}
	}
	return r.out[:]
}

@(private)
_Md :: struct {
	th:        ^Theme,
	width:     int,
	out:       [dynamic]Line,
	last_kind: enum {None, Block, List_Item},
}

@(private)
_line :: proc(parts: ..Span) -> Line {
	out := make([]Span, len(parts))
	copy(out, parts)
	return out
}

@(private)
_md_gap :: proc(r: ^_Md) {
	if len(r.out) > 0 && len(r.out[len(r.out) - 1]) > 0 do append(&r.out, Line{})
}

@(private)
_is_rule :: proc(s: string) -> bool {
	if len(s) < 3 do return false
	c := s[0]
	if c != '-' && c != '*' && c != '_' do return false
	count := 0
	for ch in s {
		if ch == rune(c) do count += 1
		else if ch != ' ' do return false
	}
	return count >= 3
}

@(private)
_is_table_sep :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	if len(t) < 3 || t[0] != '|' do return false
	for ch in t do if !(ch == '|' || ch == '-' || ch == ':' || ch == ' ') do return false
	return strings.contains(t, "-")
}

// _list_marker returns the byte length of a list marker ("- ", "12. ") or 0.
@(private)
_list_marker :: proc(s: string) -> int {
	if len(s) >= 2 && (s[0] == '-' || s[0] == '*' || s[0] == '+') && s[1] == ' ' do return 2
	n := 0
	for n < len(s) && s[n] >= '0' && s[n] <= '9' do n += 1
	if n > 0 && n + 1 < len(s) && (s[n] == '.' || s[n] == ')') && s[n + 1] == ' ' do return n + 2
	return 0
}

@(private)
_md_heading :: proc(r: ^_Md, level: int, title: string) {
	th := r.th
	_md_gap(r)
	switch level {
	case 1:
		label := strings.concatenate({" ", strings.to_upper(title), " "})
		append(&r.out, _line(Span{label, tone_pen(th, .Primary, .Solid)}))
	case 2:
		append(&r.out, _line(Span{"▍", {fg = th.tones[.Primary]}}, Span{title, {fg = th.tones[.Primary], attrs = {.Bold}}}))
	case 3:
		append(&r.out, _line(Span{"◆ ", {fg = th.tones[.Secondary]}}, Span{title, {fg = th.tones[.Secondary], attrs = {.Bold}}}))
	case:
		append(&r.out, _line(Span{title, {fg = th.ink, attrs = {.Bold, .Underline}}}))
	}
	append(&r.out, Line{})
	r.last_kind = .Block
}

@(private)
_md_paragraph :: proc(r: ^_Md, lines: []string, i: int) -> int {
	i := i
	b := strings.builder_make(context.temp_allocator)
	for i < len(lines) {
		t := strings.trim_space(lines[i])
		if t == "" || t[0] == '#' || t[0] == '>' || strings.has_prefix(t, "```") || _is_rule(t) || _list_marker(t) > 0 {
			break
		}
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
		strings.write_string(&b, t)
		i += 1
	}
	if r.last_kind == .List_Item do _md_gap(r)
	text := strings.clone(strings.to_string(b))
	_wrap_into(r, _inline(r.th, text, {fg = r.th.ink}), r.width, nil, nil)
	append(&r.out, Line{})
	r.last_kind = .Block
	return i
}

@(private)
_md_list_item :: proc(r: ^_Md, lines: []string, i: int, indent: int) -> int {
	th := r.th
	i := i
	t := strings.trim_left_space(lines[i])
	m := _list_marker(t)
	marker := t[:m]
	body := t[m:]
	depth := indent / 2

	bullet: Span
	if marker[0] >= '0' && marker[0] <= '9' {
		bullet = {strings.clone(marker), {fg = th.tones[.Accent], attrs = {.Bold}}}
	} else {
		glyphs := [3]string{"• ", "◦ ", "▪ "}
		bullet = {glyphs[depth % 3], {fg = th.tones[.Accent]}}
	}
	if strings.has_prefix(body, "[ ] ") {
		bullet = {"☐ ", {fg = th.muted}}
		body = body[4:]
	} else if strings.has_prefix(body, "[x] ") || strings.has_prefix(body, "[X] ") {
		bullet = {"☑ ", {fg = th.tones[.Success]}}
		body = body[4:]
	}
	// Continuation lines (indented, not a new item) join the item.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, body)
	i += 1
	for i < len(lines) {
		nt := strings.trim_left_space(lines[i])
		ni := len(lines[i]) - len(nt)
		if nt == "" || _list_marker(nt) > 0 || ni <= indent do break
		strings.write_byte(&b, ' ')
		strings.write_string(&b, strings.trim_space(nt))
		i += 1
	}
	if r.last_kind == .Block && len(r.out) > 0 && len(r.out[len(r.out) - 1]) > 0 do append(&r.out, Line{})

	pad := strings.repeat(" ", depth * 2)
	first := []Span{{pad, {}}, bullet}
	hang := []Span{{strings.repeat(" ", depth * 2 + text_width(bullet.text)), {}}}
	text := strings.clone(strings.to_string(b))
	_wrap_into(r, _inline(th, text, {fg = th.ink}), r.width, first, hang)
	r.last_kind = .List_Item
	// A blank line after the list closes it.
	if i >= len(lines) || strings.trim_space(lines[i]) == "" {
		append(&r.out, Line{})
		r.last_kind = .Block
	}
	return i
}

@(private)
_md_quote :: proc(r: ^_Md, lines: []string) {
	th := r.th
	b := strings.builder_make(context.temp_allocator)
	for l in lines {
		t := strings.trim_left_space(l)[1:]
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
		strings.write_string(&b, strings.trim_space(t))
	}
	bar := []Span{{"┃ ", {fg = th.tones[.Secondary]}}}
	text := strings.clone(strings.to_string(b))
	_wrap_into(r, _inline(th, text, {fg = th.muted, attrs = {.Italic}}), r.width, bar, bar)
	append(&r.out, Line{})
	r.last_kind = .Block
}

@(private)
_md_code :: proc(r: ^_Md, body: []string, lang: string) {
	th := r.th
	bg := th.raised
	w := r.width
	head := lang != "" ? strings.concatenate({" ", lang, " "}) : ""
	append(&r.out, _line(
		Span{strings.repeat(" ", max(w - text_width(head), 0)), {bg = bg}},
		Span{head, {fg = th.muted, bg = bg, attrs = {.Italic}}},
	))
	for l in body {
		s := strings.expand_tabs(l, 4)
		s = clip_to_width(s, w - 2)
		fill_n := max(w - 2 - text_width(s), 0)
		append(&r.out, _line(
			Span{"  ", {bg = bg}},
			Span{s, {fg = th.tones[.Info], bg = bg}},
			Span{strings.repeat(" ", fill_n), {bg = bg}},
		))
	}
	append(&r.out, _line(Span{strings.repeat(" ", w), {bg = bg}}))
	append(&r.out, Line{})
	r.last_kind = .Block
}

@(private)
_split_row :: proc(row: string) -> []string {
	t := strings.trim_space(row)
	t = strings.trim_prefix(t, "|")
	t = strings.trim_suffix(t, "|")
	cells := strings.split(t, "|", context.temp_allocator)
	for &c in cells do c = strings.trim_space(c)
	return cells
}

@(private)
_md_table :: proc(r: ^_Md, rows: []string) {
	th := r.th
	header := _split_row(rows[0])
	ncol := len(header)
	body := make([dynamic][]string, context.temp_allocator)
	for row in rows[2:] do append(&body, _split_row(row))
	widths := make([]int, ncol, context.temp_allocator)
	for h, c in header do widths[c] = spans_width(_inline(th, h, {}))
	for row in body {
		for c in 0 ..< min(ncol, len(row)) do widths[c] = max(widths[c], spans_width(_inline(th, row[c], {})))
	}
	// Squeeze the widest columns until the table fits.
	total :: proc(ws: []int) -> int {
		t := 0
		for w in ws do t += w + 3
		return t
	}
	for total(widths) > r.width {
		wi := 0
		for w, c in widths do if w > widths[wi] do wi = c
		if widths[wi] <= 3 do break
		widths[wi] -= 1
	}
	emit :: proc(r: ^_Md, cells: []string, widths: []int, p: Pen, sep: Pen) {
		parts := make([dynamic]Span)
		for w, c in widths {
			cell := c < len(cells) ? cells[c] : ""
			append(&parts, Span{c == 0 ? " " : " │ ", sep})
			used := 0
			for sp in _inline(r.th, strings.clone(cell), p) {
				if used >= w do break
				piece := truncate(sp.text, w - used)
				append(&parts, Span{strings.clone(piece), sp.pen})
				used += text_width(piece)
			}
			if used < w do append(&parts, Span{strings.repeat(" ", w - used), {}})
		}
		append(&r.out, parts[:])
	}
	emit(r, header, widths, {fg = th.tones[.Primary], attrs = {.Bold}}, {fg = th.line})
	rule := make([dynamic]Span)
	for w, c in widths {
		append(&rule, Span{c == 0 ? "─" : "─┼─", {fg = th.line}})
		append(&rule, Span{strings.repeat("─", w), {fg = th.line}})
	}
	append(&r.out, rule[:])
	for row in body do emit(r, row, widths, {fg = th.ink}, {fg = th.line})
	append(&r.out, Line{})
	r.last_kind = .Block
}

// _inline parses emphasis, code and links into spans over `s`.
@(private)
_inline :: proc(th: ^Theme, s: string, base: Pen) -> []Span {
	out := make([dynamic]Span)
	bold, italic, strike := false, false, false
	start := 0
	cur :: proc(base: Pen, bold, italic, strike: bool) -> Pen {
		p := base
		if bold do p.attrs += {.Bold}
		if italic do p.attrs += {.Italic}
		if strike do p.attrs += {.Strike}
		return p
	}
	flush :: proc(out: ^[dynamic]Span, s: string, start, end: int, p: Pen) {
		if end > start do append(out, Span{s[start:end], p})
	}
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '`':
			end := strings.index_byte(s[i + 1:], '`')
			if end < 0 do break
			flush(&out, s, start, i, cur(base, bold, italic, strike))
			append(&out, Span{s[i + 1:i + 1 + end], {fg = th.tones[.Accent], bg = th.raised}})
			i += end + 2
			start = i
			continue
		case c == '*' && i + 1 < len(s) && s[i + 1] == '*', c == '_' && i + 1 < len(s) && s[i + 1] == '_':
			flush(&out, s, start, i, cur(base, bold, italic, strike))
			bold = !bold
			i += 2
			start = i
			continue
		case c == '~' && i + 1 < len(s) && s[i + 1] == '~':
			flush(&out, s, start, i, cur(base, bold, italic, strike))
			strike = !strike
			i += 2
			start = i
			continue
		case c == '*' || (c == '_' && (i == 0 || s[i - 1] == ' ' || italic)):
			flush(&out, s, start, i, cur(base, bold, italic, strike))
			italic = !italic
			i += 1
			start = i
			continue
		case c == '[':
			close := strings.index_byte(s[i:], ']')
			if close > 0 && i + close + 1 < len(s) && s[i + close + 1] == '(' {
				paren := strings.index_byte(s[i + close + 1:], ')')
				if paren > 0 {
					flush(&out, s, start, i, cur(base, bold, italic, strike))
					append(&out, Span{s[i + 1:i + close], {fg = th.tones[.Primary], attrs = {.Underline}}})
					i += close + 1 + paren + 1
					start = i
					continue
				}
			}
		}
		i += 1
	}
	flush(&out, s, start, len(s), cur(base, bold, italic, strike))
	return out[:]
}

// _wrap_into word-wraps styled spans to width, prefixing the first line with
// `first` and following lines with `hang`. Pieces not separated by a space
// (e.g. `code` followed by a comma) stay together as one word.
@(private)
_wrap_into :: proc(r: ^_Md, parts: []Span, width: int, first, hang: []Span) {
	Word :: struct {
		pieces:       [dynamic]Span,
		w:            int,
		space_before: bool,
	}
	words := make([dynamic]Word, context.temp_allocator)
	pending_space := false
	for part in parts {
		rest := part.text
		for len(rest) > 0 {
			if rest[0] == ' ' {
				pending_space = true
				rest = rest[1:]
				continue
			}
			end := strings.index_byte(rest, ' ')
			if end < 0 do end = len(rest)
			piece := Span{rest[:end], part.pen}
			rest = rest[end:]
			if len(words) == 0 || pending_space {
				append(&words, Word{pieces = make([dynamic]Span, context.temp_allocator), space_before = pending_space})
			}
			wd := &words[len(words) - 1]
			append(&wd.pieces, piece)
			wd.w += text_width(piece.text)
			pending_space = false
		}
	}

	line := make([dynamic]Span)
	for p in first do append(&line, p)
	hang_w := spans_width(hang)
	w := spans_width(first)
	at_start := true
	for wd in words {
		space := wd.space_before && !at_start ? 1 : 0
		if !at_start && w + space + wd.w > width {
			append(&r.out, line[:])
			line = make([dynamic]Span)
			for p in hang do append(&line, p)
			w, at_start, space = hang_w, true, 0
		}
		if space == 1 do append(&line, Span{" ", {}})
		for piece in wd.pieces {
			text := piece.text
			// Hard-break a piece that cannot fit even on an empty line.
			for text_width(text) > width - w && at_start && width - w > 0 {
				head := clip_to_width(text, width - w)
				if len(head) == 0 do break
				append(&line, Span{head, piece.pen})
				append(&r.out, line[:])
				line = make([dynamic]Span)
				for p in hang do append(&line, p)
				w = hang_w
				text = text[len(head):]
			}
			append(&line, Span{text, piece.pen})
			w += text_width(text)
		}
		w += space
		at_start = false
	}
	if !at_start || len(words) == 0 do append(&r.out, line[:])
}

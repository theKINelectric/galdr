package galdr

import "core:fmt"

// Stateless components. Each draws into a Frame using the Frame's Theme and
// returns what a caller needs for layout (usually the cells it used).

// panel is the standard card: themed border, surface fill, title chip.
// Returns the content rect.
panel :: proc(f: ^Frame, r: Rect, title := "", tone: Tone = .Primary, focused := false, footer := "") -> Rect {
	th := f.theme
	edge := focused ? th.tones[tone] : th.line
	title_pen := focused ? tone_pen(th, tone, .Solid) : Pen{fg = th.tones[tone], attrs = {.Bold}}
	return block(f, r, {
		border = th.corners, border_pen = {fg = edge}, fill = th.surface,
		title = title, title_pen = title_pen,
		footer = footer, footer_pen = {fg = th.muted}, footer_align = .Right,
		pad_x = 1,
	})
}

// badge draws " label " in the tone/variant. Outline wraps it in brackets.
badge :: proc(f: ^Frame, x, y: int, label: string, tone: Tone = .Neutral, variant: Variant = .Soft) -> int {
	th := f.theme
	p := tone_pen(th, tone, variant)
	switch variant {
	case .Outline:
		s := fmt.tprintf("[%s]", label)
		return text(f, x, y, s, p)
	case .Ghost:
		return text(f, x, y, label, p)
	case .Solid, .Soft:
		s := fmt.tprintf(" %s ", label)
		return text(f, x, y, s, p)
	}
	return 0
}

badge_width :: proc(label: string, variant: Variant = .Soft) -> int {
	return variant == .Ghost ? text_width(label) : text_width(label) + 2
}

// button draws a pill; focused buttons are Solid, others use `variant`.
button :: proc(f: ^Frame, x, y: int, label: string, tone: Tone = .Primary, variant: Variant = .Soft, focused := false) -> Rect {
	th := f.theme
	v := focused ? Variant.Solid : variant
	p := tone_pen(th, tone, v)
	s := fmt.tprintf("  %s  ", label)
	if v == .Outline do s = fmt.tprintf("[ %s ]", label)
	w := text(f, x, y, s, p)
	return {x, y, w, 1}
}

// kbd draws a keycap such as ⏎ or ctrl+c.
kbd :: proc(f: ^Frame, x, y: int, key: string) -> int {
	th := f.theme
	return text(f, x, y, fmt.tprintf(" %s ", key), {fg = th.ink, bg = th.raised, attrs = {.Bold}})
}

Key_Hint :: struct {
	key, desc: string,
}

// help_bar draws "key desc · key desc" hints, dropping ones that don't fit.
help_bar :: proc(f: ^Frame, x, y, w: int, hints: []Key_Hint) {
	th := f.theme
	cx := x
	for h, i in hints {
		need := text_width(h.key) + 1 + text_width(h.desc) + (i > 0 ? 3 : 0)
		if cx - x + need > w do break
		if i > 0 do cx += text(f, cx, y, " · ", {fg = th.faint})
		cx += text(f, cx, y, h.key, {fg = th.tones[.Primary], attrs = {.Bold}})
		cx += text(f, cx, y, " ", {})
		cx += text(f, cx, y, h.desc, {fg = th.muted})
	}
}

// ------------------------------------------------------------ gauges

@(private)
EIGHTHS := [9]rune{' ', '▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'}

// progress draws a smooth bar (1/8-cell resolution) for value in 0..1.
progress :: proc(f: ^Frame, x, y, w: int, value: f32, tone: Tone = .Primary, show_pct := false) {
	th := f.theme
	bar_w := show_pct ? w - 5 : w
	if bar_w <= 0 do return
	v := clamp(value, 0, 1)
	track := mix(th.surface, th.line, 0.6)
	eighths := int(v * f32(bar_w * 8) + 0.5)
	for i in 0 ..< bar_w {
		cell := clamp(eighths - i * 8, 0, 8)
		put(f, x + i, y, EIGHTHS[cell], {fg = th.tones[tone], bg = track})
	}
	if show_pct {
		text_aligned(f, x + bar_w + 1, y, 4, fmt.tprintf("%d%%", int(v * 100 + 0.5)), {fg = th.muted}, .Right)
	}
}

// meter draws discrete pips: ▮▮▮▮▯▯
meter :: proc(f: ^Frame, x, y, count, filled: int, tone: Tone = .Success) -> int {
	th := f.theme
	for i in 0 ..< count {
		on := i < filled
		put(f, x + i, y, on ? '▮' : '▯', {fg = on ? th.tones[tone] : th.faint})
	}
	return count
}

@(private)
SPARKS := [8]rune{'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

// sparkline plots values (0..1) as block heights, newest on the right.
sparkline :: proc(f: ^Frame, x, y, w: int, values: []f32, tone: Tone = .Primary) {
	th := f.theme
	n := min(w, len(values))
	start := len(values) - n
	for i in 0 ..< n {
		v := clamp(values[start + i], 0, 1)
		put(f, x + w - n + i, y, SPARKS[int(v * 7 + 0.5)], {fg = th.tones[tone]})
	}
}

// bars draws a vertical bar chart filling r (values 0..1).
bars :: proc(f: ^Frame, r: Rect, values: []f32, tone: Tone = .Primary, gap := 0) {
	th := f.theme
	if r.h <= 0 do return
	step := 1 + gap
	n := min(len(values), (r.w + gap) / step)
	for i in 0 ..< n {
		v := clamp(values[len(values) - n + i], 0, 1)
		total := int(v * f32(r.h * 8) + 0.5)
		x := r.x + i * step
		for row in 0 ..< r.h {
			fill8 := clamp(total - row * 8, 0, 8)
			if fill8 == 0 do break
			ch := fill8 == 8 ? '█' : SPARKS[fill8 - 1]
			put(f, x, r.y + r.h - 1 - row, ch, {fg = th.tones[tone]})
		}
	}
}

// heatstrip shades one row of cells by intensity (0..1) toward the tone.
heatstrip :: proc(f: ^Frame, x, y, w: int, values: []f32, tone: Tone = .Success) {
	th := f.theme
	base := mix(th.surface, th.line, 0.35)
	n := min(w, len(values))
	start := len(values) - n
	for i in 0 ..< n {
		v := clamp(values[start + i], 0, 1)
		ch: rune = v > 0.66 ? '█' : v > 0.33 ? '▓' : v > 0.08 ? '▒' : '░'
		put(f, x + w - n + i, y, ch, {fg = mix(base, th.tones[tone], 0.25 + 0.75 * v)})
	}
}

// ------------------------------------------------------------ motion

Spinner_Kind :: enum u8 {
	Dots,
	Line,
	Orbit,
	Pulse,
	Bounce,
	Arc,
}

@(private) _spin_dots   := [?]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
@(private) _spin_line   := [?]string{"-", "\\", "|", "/"}
@(private) _spin_orbit  := [?]string{"◐", "◓", "◑", "◒"}
@(private) _spin_pulse  := [?]string{"█", "▓", "▒", "░", "▒", "▓"}
@(private) _spin_bounce := [?]string{"⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈"}
@(private) _spin_arc    := [?]string{"◜", "◠", "◝", "◞", "◡", "◟"}

// spinner_frame returns the glyph for animation step `tick`.
spinner_frame :: proc(kind: Spinner_Kind, tick: int) -> string {
	t := reduced_motion() ? 0 : max(tick, 0)
	switch kind {
	case .Dots:   return _spin_dots[t % len(_spin_dots)]
	case .Line:   return _spin_line[t % len(_spin_line)]
	case .Orbit:  return _spin_orbit[t % len(_spin_orbit)]
	case .Pulse:  return _spin_pulse[t % len(_spin_pulse)]
	case .Bounce: return _spin_bounce[t % len(_spin_bounce)]
	case .Arc:    return _spin_arc[t % len(_spin_arc)]
	}
	return " "
}

// SPINNER_MS is a good frame interval for spinner_frame.
SPINNER_MS :: 80

spinner :: proc(f: ^Frame, x, y: int, tick: int, kind: Spinner_Kind = .Dots, tone: Tone = .Primary, label := "") -> int {
	th := f.theme
	w := text(f, x, y, spinner_frame(kind, tick), {fg = th.tones[tone], attrs = {.Bold}})
	if label != "" {
		w += text(f, x + w, y, " ", {})
		w += text(f, x + w, y, label, {fg = th.ink})
	}
	return w
}

// ------------------------------------------------------------ navigation

// tabs draws a tab strip; returns each tab's rect (temp) for mouse hit tests.
tabs :: proc(f: ^Frame, r: Rect, labels: []string, active: int, tone: Tone = .Primary) -> []Rect {
	th := f.theme
	hits := make([]Rect, len(labels), context.temp_allocator)
	fill(f, {r.x, r.y, r.w, 1}, {bg = th.surface})
	if r.h > 1 do hline(f, r.x, r.y + 1, r.w, {fg = th.line})
	x := r.x + 1
	for label, i in labels {
		s := fmt.tprintf(" %s ", label)
		w := text_width(s)
		if x + w > r.x + r.w do break
		is_on := i == active
		p := is_on ? tone_pen(th, tone, .Solid) : Pen{fg = th.muted}
		text(f, x, r.y, s, p)
		if r.h > 1 {
			if is_on do hline(f, x, r.y + 1, w, {fg = th.tones[tone]}, '▀')
		}
		hits[i] = {x, r.y, w, 1}
		x += w + 1
	}
	return hits
}

// steps draws a progress stepper: ● done ◉ current ○ todo, joined by rules.
steps :: proc(f: ^Frame, x, y, w: int, labels: []string, current: int, tone: Tone = .Primary) {
	th := f.theme
	n := len(labels)
	if n == 0 || w <= 0 do return
	seg := w / n
	for label, i in labels {
		cx := x + i * seg + seg / 2
		done := i < current
		on := i == current
		dot: rune = done ? '●' : on ? '◉' : '○'
		c := done || on ? th.tones[tone] : th.faint
		if i > 0 {
			hline(f, x + (i - 1) * seg + seg / 2 + 1, y, seg - 1, {fg = done || on ? th.tones[tone] : th.line}, '━' if done || on else '─')
		}
		put(f, cx, y, dot, {fg = c, attrs = {.Bold}})
		lw := text_width(label)
		text(f, cx - lw / 2, y + 1, truncate(label, seg), {fg = on ? th.ink : th.muted})
	}
}

// ------------------------------------------------------------ feedback

// alert draws a tinted callout with an icon and wrapped message.
alert :: proc(f: ^Frame, r: Rect, tone: Tone, title: string, message := "") -> int {
	th := f.theme
	icon := "●"
	#partial switch tone {
	case .Info:    icon = "ℹ"
	case .Success: icon = "✔"
	case .Warning: icon = "▲"
	case .Danger:  icon = "✖"
	}
	body_w := r.w - 4
	msg_lines := message == "" ? 0 : measure_paragraph(message, body_w)
	h := min(r.h, 1 + msg_lines)
	area := Rect{r.x, r.y, r.w, h}
	fill(f, area, {bg = soft_bg(th, tone, 0.22)})
	vline(f, r.x, r.y, h, {fg = th.tones[tone]}, '▌')
	text(f, r.x + 1, r.y, icon, {fg = th.tones[tone], attrs = {.Bold}})
	text(f, r.x + 3, r.y, truncate(title, r.w - 4), {fg = th.ink, attrs = {.Bold}})
	if msg_lines > 0 && h > 1 {
		paragraph(f, {r.x + 3, r.y + 1, body_w, h - 1}, message, {fg = th.muted})
	}
	return h
}

// divider draws a rule with an optional centered label.
divider :: proc(f: ^Frame, x, y, w: int, label := "") {
	th := f.theme
	hline(f, x, y, w, {fg = th.line})
	if label != "" {
		text_aligned(f, x, y, w, fmt.tprintf(" %s ", label), {fg = th.muted}, .Center)
	}
}

// stat draws a label / big value / caption block (3 rows).
stat :: proc(f: ^Frame, x, y, w: int, label, value: string, caption := "", tone: Tone = .Primary) {
	th := f.theme
	text(f, x, y, truncate(label, w), {fg = th.muted})
	text(f, x, y + 1, truncate(value, w), {fg = th.tones[tone], attrs = {.Bold}})
	if caption != "" do text(f, x, y + 2, truncate(caption, w), {fg = th.faint})
}

// status_dot draws a colored ◆ / ◇ with a label.
status_dot :: proc(f: ^Frame, x, y: int, label: string, tone: Tone, filled := true) -> int {
	th := f.theme
	w := text(f, x, y, filled ? "◆" : "◇", {fg = th.tones[tone]})
	w += text(f, x + w, y, " ", {})
	w += text(f, x + w, y, label, {fg = th.ink})
	return w
}

// toggle draws a switch: ━━● on / ●━━ off.
toggle :: proc(f: ^Frame, x, y: int, on: bool, label := "", tone: Tone = .Primary) -> int {
	th := f.theme
	w := 0
	if on {
		w += text(f, x, y, "━━", {fg = th.tones[tone]})
		w += text(f, x + w, y, "●", {fg = th.tones[tone], attrs = {.Bold}})
	} else {
		w += text(f, x, y, "●", {fg = th.faint})
		w += text(f, x + w, y, "━━", {fg = th.line})
	}
	if label != "" {
		w += text(f, x + w, y, " ", {})
		w += text(f, x + w, y, label, {fg = on ? th.ink : th.muted})
	}
	return w
}

// checkbox draws ☑ / ☐ with a label.
checkbox :: proc(f: ^Frame, x, y: int, checked: bool, label: string, tone: Tone = .Primary, focused := false) -> int {
	th := f.theme
	w := text(f, x, y, checked ? "☑" : "☐", {fg = checked ? th.tones[tone] : th.muted})
	w += text(f, x + w, y, " ", {})
	w += text(f, x + w, y, label, {fg = focused ? th.tones[tone] : th.ink, attrs = focused ? {.Bold} : {}})
	return w
}

// scrollbar draws a thin vertical thumb for `offset` within `total` rows.
scrollbar :: proc(f: ^Frame, x, y, h, total, visible, offset: int) {
	th := f.theme
	if total <= visible || h <= 0 do return
	thumb_h := max(1, h * visible / total)
	max_off := total - visible
	thumb_y := (h - thumb_h) * clamp(offset, 0, max_off) / max(max_off, 1)
	for i in 0 ..< h {
		on := i >= thumb_y && i < thumb_y + thumb_h
		put(f, x, y + i, on ? '┃' : '│', {fg = on ? th.muted : th.line})
	}
}

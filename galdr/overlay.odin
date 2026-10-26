package galdr

import "core:fmt"

// Layers. Immediate mode makes layering simple: whatever paints last is on
// top, and zones registered last win hit-tests. These helpers give overlays
// a consistent look.

// backdrop dims everything painted so far and registers a full-screen
// "backdrop" zone (clicks outside a dialog land there).
backdrop :: proc(f: ^Frame, amount: f32 = 0.6) {
	th := f.theme
	for &c in f.cells {
		if c.pen.fg.mode == .RGB do c.pen.fg = mix(c.pen.fg, th.bg, amount)
		if c.pen.bg.mode == .RGB do c.pen.bg = mix(c.pen.bg, th.bg, amount * 0.7)
	}
	zone(f, "backdrop", frame_bounds(f))
}

// shadow darkens a one-cell drop shadow to the right of and below r.
shadow :: proc(f: ^Frame, r: Rect) {
	th := f.theme
	dark := mix(th.bg, rgb(0, 0, 0), 0.5)
	area := rect_intersect({r.x + 1, r.y + 1, r.w, r.h}, f.clip)
	for y in area.y ..< area.y + area.h {
		for x in area.x ..< area.x + area.w {
			if rect_contains(r, x, y) do continue
			c := &f.cells[y * f.w + x]
			c.pen.bg = dark
			if c.pen.fg.mode == .RGB do c.pen.fg = mix(c.pen.fg, dark, 0.6)
		}
	}
}

// modal dims the screen and draws a centered dialog. Returns its content
// rect; the dialog registers the "modal" zone.
modal :: proc(f: ^Frame, w, h: int, title: string, tone: Tone = .Primary, footer := "") -> Rect {
	backdrop(f)
	r := center(frame_bounds(f), w, h)
	shadow(f, r)
	zone(f, "modal", r)
	return panel(f, r, title, tone, true, footer)
}

// popover draws a small panel next to anchor: below it if there is room,
// otherwise above; kept inside the screen. Registers the "popover" zone.
popover :: proc(f: ^Frame, anchor: Rect, w, h: int, title := "", tone: Tone = .Primary) -> Rect {
	b := frame_bounds(f)
	pw, ph := min(w, b.w), min(h, b.h)
	x := clamp(anchor.x, 0, b.w - pw)
	y := anchor.y + anchor.h
	if y + ph > b.h do y = max(anchor.y - ph, 0)
	r := Rect{x, y, pw, ph}
	shadow(f, r)
	zone(f, "popover", r)
	return panel(f, r, title, tone, true)
}

// ------------------------------------------------------------ toasts

MAX_TOASTS :: 4

Toast :: struct {
	buf:   [120]u8,
	text:  string, // points into buf
	tone:  Tone,
	until: i64,
}

// Toasts is a small stack of expiring notifications, newest at the bottom.
Toasts :: struct {
	items: [MAX_TOASTS]Toast,
	count: int,
}

// toast adds a notification that lasts ms milliseconds from now_ms.
// Returns ms so the app can schedule a repaint for when it disappears:
//     gd.after(fx, gd.toast(&s.toasts, fx.now_ms, .Success, "Saved"), Msg(Redraw{}))
toast :: proc(t: ^Toasts, now_ms: i64, tone: Tone, text: string, ms := 3000) -> int {
	if t.count == MAX_TOASTS {
		copy(t.items[:], t.items[1:])
		t.count -= 1
	}
	item := &t.items[t.count]
	item^ = {tone = tone, until = now_ms + i64(ms)}
	item.text = fmt.bprint(item.buf[:], truncate(text, len(item.buf) - 4))
	t.count += 1
	return ms
}

// toasts_prune drops expired toasts.
toasts_prune :: proc(t: ^Toasts, now_ms: i64) {
	kept := 0
	for i in 0 ..< t.count {
		if t.items[i].until > now_ms {
			t.items[kept] = t.items[i]
			t.items[kept].text = string(t.items[kept].buf[:len(t.items[i].text)])
			kept += 1
		}
	}
	t.count = kept
}

// toasts_draw stacks live toasts in the bottom-right corner.
toasts_draw :: proc(f: ^Frame, t: ^Toasts, bottom_margin := 1) {
	toasts_prune(t, f.now_ms)
	y := f.h - 1 - bottom_margin
	#reverse for item in t.items[:t.count] {
		w := min(text_width(item.text) + 6, f.w - 2)
		r := Rect{f.w - w - 1, y, w, 1}
		alert(f, r, item.tone, item.text)
		shadow(f, r)
		y -= 2
		if y < 0 do break
	}
}

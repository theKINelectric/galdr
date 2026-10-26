package galdr

import "core:math"

// Colors, text attributes and the Pen (the style of a single cell).

Color_Mode :: enum u8 {
	Default, // terminal default (for backgrounds: "transparent", keeps what is below)
	RGB,
	Index,   // xterm 256 palette index stored in r
}

Color :: struct {
	r, g, b: u8,
	mode:    Color_Mode,
}

NO_COLOR :: Color{}

Attr :: enum u8 {
	Bold,
	Dim,
	Italic,
	Underline,
	Blink,
	Reverse,
	Strike,
}
Attrs :: bit_set[Attr; u8]

Pen :: struct {
	fg, bg: Color,
	attrs:  Attrs,
}

rgb :: proc "contextless" (r, g, b: u8) -> Color {
	return {r, g, b, .RGB}
}

indexed :: proc "contextless" (i: u8) -> Color {
	return {i, 0, 0, .Index}
}

// hex parses "#rrggbb", "rrggbb" or "#rgb". Invalid input yields NO_COLOR.
hex :: proc "contextless" (s: string) -> Color {
	s := s
	if len(s) > 0 && s[0] == '#' do s = s[1:]
	nib :: proc "contextless" (c: u8) -> (u8, bool) {
		switch c {
		case '0' ..= '9': return c - '0', true
		case 'a' ..= 'f': return c - 'a' + 10, true
		case 'A' ..= 'F': return c - 'A' + 10, true
		}
		return 0, false
	}
	switch len(s) {
	case 6:
		out: [3]u8
		for i in 0 ..< 3 {
			hi, ok1 := nib(s[i * 2])
			lo, ok2 := nib(s[i * 2 + 1])
			if !ok1 || !ok2 do return NO_COLOR
			out[i] = hi << 4 | lo
		}
		return rgb(out[0], out[1], out[2])
	case 3:
		out: [3]u8
		for i in 0 ..< 3 {
			v, ok := nib(s[i])
			if !ok do return NO_COLOR
			out[i] = v << 4 | v
		}
		return rgb(out[0], out[1], out[2])
	}
	return NO_COLOR
}

// mix blends a toward b by t (0 = a, 1 = b). Non-RGB inputs return a.
mix :: proc "contextless" (a, b: Color, t: f32) -> Color {
	if a.mode != .RGB || b.mode != .RGB do return a
	k := clamp(t, 0, 1)
	lerp :: proc "contextless" (x, y: u8, t: f32) -> u8 {
		return u8(f32(x) + (f32(y) - f32(x)) * t + 0.5)
	}
	return rgb(lerp(a.r, b.r, k), lerp(a.g, b.g, k), lerp(a.b, b.b, k))
}

// Nearest xterm-256 index for an RGB color (6x6x6 cube or grey ramp).
to_256 :: proc "contextless" (c: Color) -> u8 {
	if c.mode == .Index do return c.r
	cube :: proc "contextless" (v: u8) -> int {
		if v < 48 do return 0
		if v < 115 do return 1
		return (int(v) - 35) / 40
	}
	LEVELS := [6]int{0, 95, 135, 175, 215, 255}
	ri, gi, bi := cube(c.r), cube(c.g), cube(c.b)
	cr, cg, cb := LEVELS[ri], LEVELS[gi], LEVELS[bi]
	dist :: proc "contextless" (a, b, c, x, y, z: int) -> int {
		return (a - x) * (a - x) + (b - y) * (b - y) + (c - z) * (c - z)
	}
	avg := (int(c.r) + int(c.g) + int(c.b)) / 3
	gi2 := avg > 238 ? 23 : max(0, (avg - 3) / 10)
	gv := 8 + gi2 * 10
	if dist(int(c.r), int(c.g), int(c.b), gv, gv, gv) < dist(int(c.r), int(c.g), int(c.b), cr, cg, cb) {
		return u8(232 + gi2)
	}
	return u8(16 + 36 * ri + 6 * gi + bi)
}

pen :: proc "contextless" (fg: Color, bg := NO_COLOR, attrs: Attrs = {}) -> Pen {
	return {fg, bg, attrs}
}

// The xterm defaults for the 16 ANSI colors.
@(private)
ANSI_16 := [16][3]int{
	{0, 0, 0}, {205, 0, 0}, {0, 205, 0}, {205, 205, 0},
	{0, 0, 238}, {205, 0, 205}, {0, 205, 205}, {229, 229, 229},
	{127, 127, 127}, {255, 0, 0}, {0, 255, 0}, {255, 255, 0},
	{92, 92, 255}, {255, 0, 255}, {0, 255, 255}, {255, 255, 255},
}

// Nearest of the 16 ANSI colors (0-7 normal, 8-15 bright).
to_16 :: proc(c: Color) -> u8 {
	if c.mode == .Index && c.r < 16 do return c.r
	best, best_d := 0, max(int)
	for p, i in ANSI_16 {
		dr, dg, db := int(c.r) - p[0], int(c.g) - p[1], int(c.b) - p[2]
		d := dr * dr * 3 + dg * dg * 4 + db * db * 2
		if d < best_d do best, best_d = i, d
	}
	return u8(best)
}

// WCAG 2.x relative luminance (linearized sRGB).
relative_luminance :: proc(c: Color) -> f64 {
	lin :: proc(v: u8) -> f64 {
		s := f64(v) / 255
		return s <= 0.04045 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

// contrast_ratio is the WCAG contrast between two colors (1..21).
contrast_ratio :: proc(a, b: Color) -> f64 {
	la, lb := relative_luminance(a), relative_luminance(b)
	return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

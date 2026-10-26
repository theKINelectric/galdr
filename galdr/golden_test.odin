package galdr

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Golden snapshots: a fixed gallery of components, rendered in every theme,
// compared with testdata/golden/*.txt (glyphs plus a styling summary).
// After an intended visual change, regenerate with:
//   odin test galdr -define:GALDR_UPDATE_GOLDEN=true

UPDATE_GOLDEN :: #config(GALDR_UPDATE_GOLDEN, false)
GOLDEN_DIR :: #directory + "/testdata/golden"

@(private = "file")
gallery :: proc(f: ^Frame) {
	th := f.theme
	frame_reset(f)
	area := frame_bounds(f)
	cols := columns(area, {grow(), grow()}, gap = 1)

	left := panel(f, cols[0], "COMPONENTS", .Primary, true, "footer")
	saved_clip := push_clip(f, left) // widgets don't clip themselves
	defer pop_clip(f, saved_clip)
	y := left.y
	x := left.x
	for tone in Tone {
		x += badge(f, x, y, fmt.tprintf("%v", tone)[:2], tone, .Solid) + 1
	}
	y += 1
	x = left.x
	for v in Variant do x += badge(f, x, y, fmt.tprintf("%v", v), .Primary, v) + 1
	y += 2
	bx := left.x
	bx += button(f, bx, y, "Go", .Success, .Soft, true).w + 1
	button(f, bx, y, "Stop", .Danger, .Outline)
	y += 2
	progress(f, left.x, y, left.w, 0.62, .Primary, true)
	y += 1
	meter(f, left.x, y, 8, 5, .Success)
	sparkline(f, left.x + 10, y, 12, {0, 0.2, 0.4, 0.6, 0.8, 1, 0.5, 0.3, 0.1, 0.9, 0.7, 0.4}, .Info)
	y += 2
	toggle(f, left.x, y, true, "on")
	checkbox(f, left.x + 10, y, false, "off")
	y += 2
	steps(f, left.x, y, left.w, {"one", "two", "three"}, 1)
	y += 3
	alert(f, {left.x, y, left.w, 2}, .Warning, "Heads up", "Wrapped message text.")

	pop_clip(f, saved_clip)
	rr := rows(cols[1], {fixed(10), grow()})
	right := panel(f, rr[0], "STATEFUL", .Secondary)
	l := Pick_List{cursor = 1}
	pick_draw(f, {right.x, right.y, right.w, 3}, &l, {"alpha", "beta", "gamma", "delta"}, true, .Secondary)
	tf: Text_Field
	field_set(&tf, "héllo 日本")
	field_draw(f, {right.x, right.y + 4, right.w, 1}, &tf, true, .Secondary)
	field_destroy(&tf)
	g := Pick_List{}
	grid_draw(f, {right.x, right.y + 5, right.w, 3}, &g, {{title = "name", size = grow()}, {title = "n", size = fixed(3), align = .Right}}, {{"a", "1"}}, false)

	md := panel(f, rr[1], "MARKDOWN", .Accent)
	lines := md_lines("## Title\n\n- **bold** item\n- `code`\n\n> quote", md.w, th, context.temp_allocator)
	for line, i in lines {
		if i >= md.h do break
		spans(f, md.x, md.y + i, line)
	}
	tabs(f, {0, f.h - 2, f.w, 2}, {"one", "two", "three"}, 1)
}

// snapshot writes the glyphs, then one style line per row: runs of
// "count×fg/bg/attrs" so color and attribute changes are reviewable.
@(private = "file")
snapshot :: proc(f: ^Frame) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, frame_to_text(f))
	strings.write_string(&b, "\n--- styles ---\n")
	color :: proc(c: Color) -> string {
		switch c.mode {
		case .Default: return "-"
		case .Index:   return fmt.tprintf("i%d", c.r)
		case .RGB:     return fmt.tprintf("%02x%02x%02x", c.r, c.g, c.b)
		}
		return "?"
	}
	for y in 0 ..< f.h {
		fmt.sbprintf(&b, "%02d:", y)
		run := 0
		cur: Pen
		for x in 0 ..< f.w {
			p := f.cells[y * f.w + x].pen
			if x > 0 && p != cur {
				fmt.sbprintf(&b, " %d×%s/%s/%v", run, color(cur.fg), color(cur.bg), transmute(u8)cur.attrs)
				run = 0
			}
			cur = p
			run += 1
		}
		fmt.sbprintf(&b, " %d×%s/%s/%v\n", run, color(cur.fg), color(cur.bg), transmute(u8)cur.attrs)
	}
	return strings.to_string(b)
}

@(test)
test_golden_gallery :: proc(t: ^testing.T) {
	saved := width_mode
	width_mode = .Legacy
	defer width_mode = saved
	for i in 0 ..< THEME_COUNT {
		th := theme_by_index(i)
		f := frame_make(80, 24, &th, context.temp_allocator)
		gallery(&f)
		got := snapshot(&f)
		path := fmt.tprintf("%s/gallery_%s.txt", GOLDEN_DIR, th.name)
		when UPDATE_GOLDEN {
			os.make_directory_all(GOLDEN_DIR)
			werr := os.write_entire_file_from_string(path, got)
			testing.expectf(t, werr == nil, "writing %s: %v", path, werr)
			continue
		}
		want, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {
			testing.expectf(t, false, "missing golden %s (run with -define:GALDR_UPDATE_GOLDEN=true)", path)
			continue
		}
		if string(want) != got {
			// Point at the first differing line to make review easy.
			wl := strings.split_lines(string(want), context.temp_allocator)
			gl := strings.split_lines(got, context.temp_allocator)
			for k in 0 ..< max(len(wl), len(gl)) {
				a := k < len(wl) ? wl[k] : "<none>"
				c := k < len(gl) ? gl[k] : "<none>"
				if a != c {
					testing.expectf(t, false, "%s differs at line %d:\n want: %s\n  got: %s", th.name, k + 1, a, c)
					break
				}
			}
		}
	}
}

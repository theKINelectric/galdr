package mission

import gd "galdr:galdr"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import "core:time"

// Rendering benchmarks on the real app. Budgets are generous upper bounds so
// CI catches regressions (e.g. losing the diff or the scroll path), not noise.
// Run with -define:ODIN_TEST_LOG_LEVEL=info to see the numbers.

@(private = "file")
Scenario :: struct {
	name:  string,
	bytes: int, // average bytes per frame
	us:    f64, // average microseconds per frame (paint + diff)
}

@(private = "file")
measure :: proc(h: ^gd.Harness(State, Msg), frames: int, step: proc(h: ^gd.Harness(State, Msg), i: int), caps := gd.Caps{depth = .True_Color}) -> (bytes: int, us: f64) {
	prev := gd.frame_make(h.frame.w, h.frame.h, &h.engine.theme, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	copy(prev.cells, gd.harness_paint(h).cells)
	total := 0
	start := time.tick_now()
	for i in 0 ..< frames {
		step(h, i)
		next := gd.harness_paint(h)
		strings.builder_reset(&sb)
		gd.render_diff(&sb, &prev, next, false, caps)
		total += strings.builder_len(sb)
		copy(prev.cells, next.cells)
	}
	elapsed := time.duration_microseconds(time.tick_since(start))
	return total / frames, elapsed / f64(frames)
}

@(test)
test_render_budgets :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s: State
	h: gd.Harness(State, Msg)
	gd.harness_init(&h, gd.App(State, Msg){boot = boot, react = react, paint = paint}, &s, 160, 48)

	sb := strings.builder_make()
	gd.render_diff(&sb, nil, gd.harness_paint(&h), true, {depth = .True_Color})
	full := strings.builder_len(sb)

	results: [dynamic]Scenario
	b, us := measure(&h, 50, proc(h: ^gd.Harness(State, Msg), i: int) {})
	append(&results, Scenario{"idle (nothing changed)", b, us})
	idle := b

	b, us = measure(&h, 50, proc(h: ^gd.Harness(State, Msg), i: int) {gd.harness_advance(h, gd.SPINNER_MS)})
	append(&results, Scenario{"dashboard animating (80 ms tick)", b, us})
	animating := b

	gd.harness_type(&h, "3")
	gd.harness_paint(&h)
	b, us = measure(&h, 40, proc(h: ^gd.Harness(State, Msg), i: int) {gd.harness_type(h, "j")})
	append(&results, Scenario{"docs scroll by one line", b, us})
	scrolling := b
	b, us = measure(&h, 40, proc(h: ^gd.Harness(State, Msg), i: int) {gd.harness_type(h, "k")}, {depth = .True_Color, no_scroll = true})
	append(&results, Scenario{"  same, scroll optimization off", b, us})

	log.infof("full redraw: %d bytes", full)
	for r in results {
		log.infof("%-34s %6d bytes/frame (%4.1f%% of full)  %7.1f µs/frame", r.name, r.bytes, 100 * f64(r.bytes) / f64(full), r.us)
	}
	testing.expectf(t, idle < 64, "idle frames send almost nothing (%d bytes)", idle)
	testing.expectf(t, animating < full / 5, "animation sends a fraction of a redraw (%d of %d)", animating, full)
	testing.expectf(t, scrolling < full / 4, "scrolling uses the terminal's scroll (%d of %d)", scrolling, full)
	_ = fmt.tprint
}

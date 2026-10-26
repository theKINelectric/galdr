package mission

import gd "galdr:galdr"
import "core:log"
import "core:mem"
import "core:testing"

// Ten minutes of virtual time with realistic activity (animation, pulses,
// tab switches, theme changes, docs relayout and scrolling). Live memory at
// the end must not exceed live memory after the first minute.
@(test)
test_soak_no_growth :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	s: State
	h: gd.Harness(State, Msg)
	gd.harness_init(&h, gd.App(State, Msg){boot = boot, react = react, paint = paint}, &s, 140, 40)

	baseline: i64
	for second in 1 ..= 600 {
		gd.harness_advance(&h, 1000)
		switch second % 20 {
		case 5:  gd.harness_type(&h, "2")
		case 10: gd.harness_type(&h, "3")
		case 12: gd.harness_type(&h, "jjjjG")
		case 15: gd.harness_type(&h, "t")
		case 18: gd.harness_type(&h, "1")
		}
		gd.harness_paint(&h)
		free_all(context.temp_allocator)
		if second == 60 do baseline = track.current_memory_allocated
	}
	final := track.current_memory_allocated
	log.infof("live memory: %d bytes after 1 min, %d after 10 min (peak %d)", baseline, final, track.peak_memory_allocated)
	testing.expectf(t, final <= baseline, "memory grew from %d to %d bytes over 9 minutes", baseline, final)

	// The complete teardown must return every owned byte (audit A8: this test
	// used to pass while leaking the file picker). A leak here fails CI, not
	// just prints a warning.
	state_destroy(&s)
	gd.harness_destroy(&h)
	testing.expectf(t, track.current_memory_allocated == 0,
		"%d bytes of owned memory survived teardown", track.current_memory_allocated)
}

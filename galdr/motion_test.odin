package galdr

import "core:testing"

@(test)
test_spring_and_tween :: proc(t: ^testing.T) {
	set_reduced_motion(false)
	defer set_reduced_motion(false)
	s := Spring{value = 0, target = 10}
	steps := 0
	for !spring_settled(s) && steps < 200 {
		spring_step(&s, 16)
		steps += 1
		testing.expect(t, s.value <= 10.05, "the default spring barely overshoots")
	}
	testing.expect(t, spring_settled(s))
	testing.expect_value(t, s.value, 10)
	testing.expectf(t, steps > 5 && steps < 60, "settles in a sensible time (%d frames)", steps)

	// Frame time doesn't change where it ends up.
	a, b := Spring{target = 1}, Spring{target = 1}
	for _ in 0 ..< 100 do spring_step(&a, 10)
	for _ in 0 ..< 10 do spring_step(&b, 100)
	testing.expect(t, abs(a.value - b.value) < 0.01)

	tw := tween_start(0, 100, 1000, 200)
	testing.expect_value(t, tween_value(tw, 1000), 0)
	mid := tween_value(tw, 1100)
	testing.expect(t, mid > 50 && mid < 100, "ease-out is past halfway at half time")
	testing.expect_value(t, tween_value(tw, 5000), 100)
	testing.expect(t, tween_done(tw, 1200))

	set_reduced_motion(true)
	r := Spring{target = 5}
	spring_step(&r, 1)
	testing.expect_value(t, r.value, 5) // snaps
	testing.expect_value(t, tween_value(tw, 1000), 100)
	testing.expect_value(t, spinner_frame(.Dots, 7), spinner_frame(.Dots, 0))
}

package galdr

import "core:os"

// Motion: springs for things that should feel physical, tweens for things on
// a schedule, and a reduced-motion switch (GALDR_REDUCED_MOTION=1) that makes
// every animation jump to its end and freezes spinners.

@(private) _reduced_checked: bool
@(private) _reduced: bool

// reduced_motion reports whether the user asked for less motion.
reduced_motion :: proc() -> bool {
	if !_reduced_checked {
		v := os.get_env("GALDR_REDUCED_MOTION", context.temp_allocator)
		_reduced = v != "" && v != "0"
		_reduced_checked = true
	}
	return _reduced
}

// set_reduced_motion overrides the environment (e.g. from an app setting).
set_reduced_motion :: proc(on: bool) {
	_reduced, _reduced_checked = on, true
}

// ------------------------------------------------------------ springs

Spring :: struct {
	value, velocity, target: f32,
	stiffness:               f32, // 0 = 170
	damping:                 f32, // 0 = 26 (close to critical: no wobble)
}

// spring_step advances the spring by dt_ms. Stable for any frame time.
spring_step :: proc(s: ^Spring, dt_ms: f32) {
	if reduced_motion() {
		s.value, s.velocity = s.target, 0
		return
	}
	k := s.stiffness != 0 ? s.stiffness : 170
	c := s.damping != 0 ? s.damping : 26
	remaining := max(dt_ms, 0) / 1000
	for remaining > 0 {
		dt := min(remaining, 0.004) // fixed 4 ms substeps
		force := -k * (s.value - s.target) - c * s.velocity
		s.velocity += force * dt
		s.value += s.velocity * dt
		remaining -= dt
	}
	if spring_settled(s^) {
		s.value, s.velocity = s.target, 0
	}
}

spring_settled :: proc(s: Spring) -> bool {
	// A hundredth of a cell is invisible in a terminal grid.
	return abs(s.value - s.target) < 0.01 && abs(s.velocity) < 0.05
}

// ------------------------------------------------------------ easing & tweens

Easing :: #type proc(t: f32) -> f32

ease_linear :: proc(t: f32) -> f32 { return t }
ease_out_cubic :: proc(t: f32) -> f32 { u := 1 - t; return 1 - u * u * u }
ease_in_out_cubic :: proc(t: f32) -> f32 {
	if t < 0.5 do return 4 * t * t * t
	u := -2 * t + 2
	return 1 - u * u * u / 2
}
ease_out_back :: proc(t: f32) -> f32 {
	c1: f32 = 1.70158
	c3 := c1 + 1
	u := t - 1
	return 1 + c3 * u * u * u + c1 * u * u
}

Tween :: struct {
	from, to:    f32,
	start_ms:    i64,
	duration_ms: i64,
	ease:        Easing, // nil = ease_out_cubic
}

tween_start :: proc(from, to: f32, now_ms: i64, duration_ms: i64 = 250, ease: Easing = nil) -> Tween {
	return {from, to, now_ms, max(duration_ms, 1), ease}
}

tween_value :: proc(tw: Tween, now_ms: i64) -> f32 {
	if reduced_motion() do return tw.to
	t := clamp(f32(now_ms - tw.start_ms) / f32(tw.duration_ms), 0, 1)
	ease: Easing = ease_out_cubic
	if tw.ease != nil do ease = tw.ease
	return tw.from + (tw.to - tw.from) * ease(t)
}

tween_done :: proc(tw: Tween, now_ms: i64) -> bool {
	return reduced_motion() || now_ms - tw.start_ms >= tw.duration_ms
}

package galdr

import "core:sync"
import "core:testing"
import "core:time"

@(private = "file")
Hub_State :: struct {
	results: int,
}

@(private = "file")
hub_app :: App(Hub_State, int){
	react = proc(s: ^Hub_State, ev: Event(int), fx: ^Fx(int)) {
		if _, ok := ev.(int); ok do s.results += 1
	},
}

@(private = "file")
live_tasks: i64

@(private = "file")
slow_work :: proc(data: rawptr) -> int {
	sync.atomic_add(&live_tasks, 1)
	time.sleep(time.Duration(int(uintptr(data))) * time.Millisecond)
	sync.atomic_sub(&live_tasks, 1)
	return 1
}

@(test)
test_task_hub_bounded_and_complete :: proc(t: ^testing.T) {
	s: Hub_State
	e: Engine(Hub_State, int)
	engine_init(&e, hub_app, &s, theme_nightfall())
	for _ in 0 ..< 20 do spawn(&e.fx, slow_work, rawptr(uintptr(15)))
	engine_dispatch(&e, Resize{1, 1}) // applies the queued spawns
	workers, queued := engine_task_stats(&e)
	testing.expect(t, workers <= MAX_WORKERS, "worker threads are bounded")
	testing.expect(t, queued > 0, "excess tasks queue instead of spawning threads")

	deadline := time.tick_now()
	for s.results < 20 && time.duration_seconds(time.tick_since(deadline)) < 5 {
		engine_drain_inbox(&e)
		time.sleep(2 * time.Millisecond)
	}
	testing.expect_value(t, s.results, 20)
	engine_destroy(&e)
}

@(test)
test_task_hub_quit_does_not_wait :: proc(t: ^testing.T) {
	s: Hub_State
	e: Engine(Hub_State, int)
	engine_init(&e, hub_app, &s, theme_nightfall())
	spawn(&e.fx, slow_work, rawptr(uintptr(300)))
	engine_dispatch(&e, Resize{1, 1})
	time.sleep(20 * time.Millisecond) // let the worker start
	start := time.tick_now()
	engine_destroy(&e)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < 50, "destroy returns immediately")
	// The worker finishes later against the still-alive (refcounted) hub.
	for sync.atomic_load(&live_tasks) > 0 do time.sleep(10 * time.Millisecond)
	time.sleep(20 * time.Millisecond)
}

// ------------------------------------------------------------ shutdown ownership
// Audit A9: queued tasks are canceled (never run), late results are disposed
// of through on_result_drop — nothing that owns memory silently leaks when
// the engine is destroyed.

@(private = "file")
canceled_queued: i64
@(private = "file")
dropped_late: i64
@(private = "file")
dropped_inbox: i64

@(private = "file")
count_cancel :: proc(data: rawptr) {
	sync.atomic_add(&canceled_queued, 1)
}

@(private = "file")
count_late :: proc(m: int) {
	sync.atomic_add(&dropped_late, 1)
}

@(private = "file")
count_inbox :: proc(m: int) {
	sync.atomic_add(&dropped_inbox, 1)
}

// gated_work parks until gated_released is set, so exactly MAX_WORKERS tasks
// run (and only they run) no matter how loaded the test runner is.
@(private = "file")
gated_running: i64
@(private = "file")
gated_released: i64

@(private = "file")
gated_work :: proc(data: rawptr) -> int {
	sync.atomic_add(&gated_running, 1)
	for sync.atomic_load(&gated_released) == 0 do time.sleep(2 * time.Millisecond)
	sync.atomic_sub(&gated_running, 1)
	return 1
}

@(private = "file")
wait_for :: proc(goal: ^i64, want: i64, seconds: f64) -> bool {
	deadline := time.tick_now()
	for sync.atomic_load(goal) < want && time.duration_seconds(time.tick_since(deadline)) < seconds {
		time.sleep(5 * time.Millisecond)
	}
	return sync.atomic_load(goal) >= want
}

@(test)
test_task_hub_close_cancels_queued_and_drops_late_results :: proc(t: ^testing.T) {
	s: Hub_State
	e: Engine(Hub_State, int)
	engine_init(&e, hub_app, &s, theme_nightfall())
	e.on_result_drop = count_late
	for _ in 0..<20 do spawn(&e.fx, gated_work, nil, count_cancel)
	engine_dispatch(&e, Resize{1, 1})
	// Let every worker pick up a task first, so queued is deterministic.
	testing.expect(t, wait_for(&gated_running, MAX_WORKERS, 5), "workers started")
	workers, queued := engine_task_stats(&e)
	testing.expect_value(t, workers, MAX_WORKERS)
	testing.expect_value(t, queued, 20 - MAX_WORKERS)

	engine_destroy(&e)
	testing.expect_value(t, sync.atomic_load(&canceled_queued), 20 - MAX_WORKERS)

	// Release the 4 started tasks: they finish against the closed hub, and
	// their results are disposed of, not leaked.
	sync.atomic_store(&gated_released, 1)
	testing.expect(t, wait_for(&dropped_late, MAX_WORKERS, 5), "late results disposed of")
	testing.expect_value(t, sync.atomic_load(&dropped_late), MAX_WORKERS)
}

@(test)
test_task_hub_close_drops_undelivered_inbox :: proc(t: ^testing.T) {
	s: Hub_State
	e: Engine(Hub_State, int)
	engine_init(&e, hub_app, &s, theme_nightfall())
	e.on_result_drop = count_inbox
	spawn(&e.fx, slow_work, rawptr(uintptr(40)))
	engine_dispatch(&e, Resize{1, 1})
	// Let the result arrive without draining it into the app.
	time.sleep(400 * time.Millisecond)
	engine_destroy(&e)
	testing.expect_value(t, sync.atomic_load(&dropped_inbox), 1)
	for sync.atomic_load(&live_tasks) > 0 do time.sleep(10 * time.Millisecond)
}

// ------------------------------------------------------------ disposal safety
// Re-review follow-up: disposal callbacks must run OUTSIDE the hub lock (a
// disposer that re-enters an engine API used to deadlock), App.drop must be
// wired through engine_init, and a quit mid-drain must dispose of pending
// results instead of dropping them silently.

@(private = "file")
dropped_reenter: i64
@(private = "file")
canceled_blocking: i64
@(private = "file")
probe_engine: ^Engine(Hub_State, int)

// Dedicated gate for the off-lock test: file-level gates are shared by every
// test in the package, and the runner is parallel.
@(private = "file")
gate_b_running: i64
@(private = "file")
gate_b_released: i64

@(private = "file")
gated_b_work :: proc(data: rawptr) -> int {
	sync.atomic_add(&gate_b_running, 1)
	for sync.atomic_load(&gate_b_released) == 0 do time.sleep(2 * time.Millisecond)
	sync.atomic_sub(&gate_b_running, 1)
	return 1
}

@(private = "file")
reenter_drop :: proc(m: int) {
	// Legal per the contract: may call back into engine APIs. The engine is
	// mid-close here (engine_destroy has not returned), so this takes the hub
	// lock — deadlocking unless disposal runs off the lock.
	_, _ = engine_task_stats(probe_engine)
	sync.atomic_add(&dropped_reenter, 1)
}

@(private = "file")
blocking_cancel :: proc(data: rawptr) {
	// Releases the running workers, then holds the close loop open long
	// enough for their late results to be disposed of mid-close.
	sync.atomic_store(&gate_b_released, 1)
	deadline := time.tick_now()
	for sync.atomic_load(&dropped_reenter) < MAX_WORKERS && time.duration_seconds(time.tick_since(deadline)) < 3 {
		time.sleep(2 * time.Millisecond)
	}
	sync.atomic_add(&canceled_blocking, 1)
}

@(test)
test_task_hub_drop_runs_off_the_lock :: proc(t: ^testing.T) {
	// Regression (re-review): the worker used to call the disposer while
	// holding h.mu; a disposer touching engine_task_stats then deadlocked.
	s: Hub_State
	e: Engine(Hub_State, int)
	engine_init(&e, hub_app, &s, theme_nightfall())
	e.on_result_drop = reenter_drop
	probe_engine = &e
	for _ in 0..<MAX_WORKERS do spawn(&e.fx, gated_b_work, nil)
	for _ in 0..<8 do spawn(&e.fx, slow_work, rawptr(uintptr(50)), blocking_cancel)
	engine_dispatch(&e, Resize{1, 1})
	deadline := time.tick_now()
	for sync.atomic_load(&gate_b_running) < MAX_WORKERS && time.duration_seconds(time.tick_since(deadline)) < 5 {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, sync.atomic_load(&gate_b_running), MAX_WORKERS)

	engine_destroy(&e) // close blocks in the cancels while the workers finish
	testing.expect_value(t, sync.atomic_load(&dropped_reenter), MAX_WORKERS)
	testing.expect_value(t, sync.atomic_load(&canceled_blocking), 8)
	for sync.atomic_load(&live_tasks) > 0 do time.sleep(10 * time.Millisecond)
}

@(private = "file")
dropped_wired: i64

@(private = "file")
wired_drop :: proc(m: int) {
	sync.atomic_add(&dropped_wired, 1)
}

@(test)
test_app_drop_is_wired_through_engine_init :: proc(t: ^testing.T) {
	s: Hub_State
	e: Engine(Hub_State, int)
	engine_init(&e, App(Hub_State, int){react = hub_app.react, drop = wired_drop}, &s, theme_nightfall())
	testing.expect(t, e.on_result_drop != nil, "engine_init copies App.drop")
	spawn(&e.fx, slow_work, rawptr(uintptr(30)))
	engine_dispatch(&e, Resize{1, 1})
	time.sleep(300 * time.Millisecond) // the result lands in the inbox
	engine_destroy(&e)
	testing.expect(t, sync.atomic_load(&dropped_wired) >= 1)
	for sync.atomic_load(&live_tasks) > 0 do time.sleep(10 * time.Millisecond)
}

@(private = "file")
dropped_quit_drain: i64

@(private = "file")
quit_drain_drop :: proc(m: int) {
	sync.atomic_add(&dropped_quit_drain, 1)
}

@(test)
test_quit_mid_drain_disposes_pending_results :: proc(t: ^testing.T) {
	s: Hub_State
	e: Engine(Hub_State, int)
	engine_init(&e, hub_app, &s, theme_nightfall())
	e.on_result_drop = quit_drain_drop
	for _ in 0..<3 do spawn(&e.fx, slow_work, rawptr(uintptr(40)))
	engine_dispatch(&e, Resize{1, 1})
	time.sleep(400 * time.Millisecond) // three results wait in the inbox
	e.quit = true
	engine_drain_inbox(&e) // the app never reacts: all three are disposed of
	testing.expect_value(t, sync.atomic_load(&dropped_quit_drain), 3)
	engine_destroy(&e)
	for sync.atomic_load(&live_tasks) > 0 do time.sleep(10 * time.Millisecond)
}

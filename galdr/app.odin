package galdr

import "base:runtime"
import "core:slice"
import "core:sync"
import "core:thread"

// The runtime vocabulary:
//
//   boot  — once, before the first paint: set up state, schedule work
//   react — an Event arrived: change state, request effects through Fx
//   paint — draw state into a Frame (immediate mode; no effects here)
//
// Effects are *requests* recorded in Fx and carried out by the Engine after
// react returns. Tests can run the very same Engine headlessly (see Harness).

App :: struct($S, $M: typeid) {
	boot:  proc(s: ^S, fx: ^Fx(M)),
	react: proc(s: ^S, ev: Event(M), fx: ^Fx(M)),
	paint: proc(s: ^S, f: ^Frame),
	// drop disposes of result messages the app will never react to: tasks
	// still in flight when the engine is destroyed (quit while running,
	// completed after close). Optional — required if your messages own memory.
	// It can run on a worker thread, concurrently with other teardown: keep it
	// quick, and it may call back into engine APIs (but not react).
	drop:  proc(m: M),
}

// No_Msg is the message type for apps that have no custom messages.
No_Msg :: struct {}

// VERSION follows semver. 0.x: the API may still change between minors.
VERSION :: "0.2.0"

Timer_Req :: struct($M: typeid) {
	ms:  int,
	msg: M,
}

// A Task runs `work` on a worker thread; its result comes back as a message.
// Ownership contract:
//   - `data` must outlive the work (the app state it references) or be freed
//     by `work` itself.
//   - If the task is still queued when the engine is destroyed, it never
//     runs: `cancel` (optional) is called with `data` so it can be freed.
//   - A task that already started is not interrupted.
Task_Req :: struct($M: typeid) {
	work:   proc(data: rawptr) -> M,
	data:   rawptr,
	cancel: proc(data: rawptr), // optional: disposal if the task is dropped unstarted
}

Fx :: struct($M: typeid) {
	now_ms:    i64, // read-only: the engine clock when this event is handled
	quit:      bool,
	sends:     [dynamic]M,
	timers:    [dynamic]Timer_Req(M),
	tasks:     [dynamic]Task_Req(M),
	theme:     Maybe(Theme),
}

// quit ends the program after the current event.
quit :: proc(fx: ^Fx($M)) {
	fx.quit = true
}

// send queues msg to be reacted to right after the current event.
send :: proc(fx: ^Fx($M), msg: M) {
	append(&fx.sends, msg)
}

// after delivers msg once, ms milliseconds from now. Re-arm it in react for a
// repeating clock: `case Tick: s.frame += 1; after(fx, 80, Tick{})`.
after :: proc(fx: ^Fx($M), ms: int, msg: M) {
	append(&fx.timers, Timer_Req(M){max(ms, 0), msg})
}

// spawn runs work(data) on a worker thread and delivers its returned message.
// cancel (optional) disposes of data if the engine is destroyed while the
// task is still queued (it never runs then).
spawn :: proc(fx: ^Fx($M), work: proc(data: rawptr) -> M, data: rawptr = nil, cancel: proc(data: rawptr) = nil) {
	append(&fx.tasks, Task_Req(M){work, data, cancel})
}

// set_theme swaps the active theme (takes effect on the next paint).
set_theme :: proc(fx: ^Fx($M), th: Theme) {
	fx.theme = th
}

// ------------------------------------------------------------ engine

Timer :: struct($M: typeid) {
	due: i64,
	seq: u64,
	msg: M,
}

Engine :: struct($S, $M: typeid) {
	app:              App(S, M),
	state:            ^S,
	fx:               Fx(M),
	theme:            Theme,
	now_ms:           i64,
	timers:           [dynamic]Timer(M),
	timer_seq:        u64,
	hub:              ^Task_Hub(M), // created on the first async spawn
	// Disposal for task results the app never sees: undelivered at shutdown,
	// completed after close, or dropped because the engine quit mid-drain.
	// Set it before the first spawn (in boot) if your messages own memory.
	on_result_drop:   proc(m: M),
	wake:             proc(data: rawptr),
	wake_data:        rawptr,
	synchronous_tasks: bool,
	quit:             bool,
	dirty:            bool,
	zones:            [dynamic]Zone, // zones of the last painted frame
}

engine_init :: proc(e: ^Engine($S, $M), app: App(S, M), state: ^S, theme: Theme) {
	e.app = app
	e.state = state
	e.theme = theme
	e.on_result_drop = app.drop
	e.dirty = true
}

engine_destroy :: proc(e: ^Engine($S, $M)) {
	// Never waits for running tasks: quitting stays instant, and instant
	// shutdown does not mean all work has stopped. Queued tasks never run
	// (their `cancel` disposes of their data); results that arrive too late
	// for the app go to on_result_drop instead of leaking. Workers finish on
	// their own; the hub frees itself last.
	if e.hub != nil do _hub_close(e.hub)
	e.hub = nil
	delete(e.timers)
	delete(e.zones)
	delete(e.fx.sends)
	delete(e.fx.timers)
	delete(e.fx.tasks)
}

engine_boot :: proc(e: ^Engine($S, $M)) {
	e.fx.now_ms = e.now_ms
	if e.app.boot != nil do e.app.boot(e.state, &e.fx)
	_engine_apply(e)
	e.dirty = true
}

engine_dispatch :: proc(e: ^Engine($S, $M), ev: Event(M)) {
	if e.app.react == nil do return
	ev := ev
	if m, is_mouse := ev.(Mouse); is_mouse {
		if z, ok := zone_at(e.zones[:], m.x, m.y); ok {
			m.zone = z
			m.local = {m.x - z.rect.x, m.y - z.rect.y}
		}
		ev = m
	}
	e.fx.now_ms = e.now_ms
	e.app.react(e.state, ev, &e.fx)
	e.dirty = true
	_engine_apply(e)
}

engine_paint :: proc(e: ^Engine($S, $M), f: ^Frame) {
	f.theme = &e.theme
	frame_reset(f)
	f.now_ms = e.now_ms
	if e.app.paint != nil do e.app.paint(e.state, f)
	clear(&e.zones)
	append(&e.zones, ..f.zones[:])
}

// Milliseconds until the next timer is due; -1 when there are none.
engine_next_timeout :: proc(e: ^Engine($S, $M)) -> int {
	if len(e.timers) == 0 do return -1
	due := e.timers[0].due
	for t in e.timers do due = min(due, t.due)
	return int(max(due - e.now_ms, 0))
}

// Fire every timer due at or before now, in due order (ties: scheduling order).
// Fairness: only timers that existed when this call started are dispatched in
// it — a handler that rearms itself with `after(fx, 0, msg)` runs again on the
// NEXT turn (the run loop notices a due timer and iterates without blocking),
// so input and paint always get a turn between timer storms. The 1,024-per-call
// budget bounds a pathological pile of distinct due timers, like _engine_apply
// bounds sends.
engine_fire_timers :: proc(e: ^Engine($S, $M)) {
	entry_seq := e.timer_seq
	dispatched := 0
	for !e.quit {
		best := -1
		for t, i in e.timers {
			if t.seq > entry_seq do continue // scheduled this turn: next turn
			if t.due > e.now_ms do continue
			if best < 0 || t.due < e.timers[best].due ||
			   (t.due == e.timers[best].due && t.seq < e.timers[best].seq) {
				best = i
			}
		}
		if best < 0 do return
		if dispatched >= MAX_TIMERS_PER_TURN do return
		dispatched += 1
		msg := e.timers[best].msg
		ordered_remove(&e.timers, best)
		engine_dispatch(e, msg)
	}
}

// Per-call bound on timer dispatch (see engine_fire_timers).
MAX_TIMERS_PER_TURN :: 1024

// Deliver messages posted by worker threads.
engine_drain_inbox :: proc(e: ^Engine($S, $M)) {
	if e.hub == nil do return
	pending := _hub_take(e.hub)
	for m, i in pending {
		if e.quit {
			// The app will not react to the rest; dispose of them.
			for late in pending[i:] do if e.on_result_drop != nil do e.on_result_drop(late)
			return
		}
		engine_dispatch(e, m)
	}
}

// ------------------------------------------------------------ task hub

// At most this many worker threads run spawned tasks; more tasks queue.
MAX_WORKERS :: 4

// Task_Hub is shared by the engine and its worker threads and reference
// counted, so workers never touch freed memory even if the app has quit.
Task_Hub :: struct($M: typeid) {
	mu:        sync.Mutex,
	cond:      sync.Cond,
	queue:     [dynamic]Task_Req(M),
	inbox:     [dynamic]M,
	closed:    bool,
	refs:      int, // the engine + each live worker
	workers:   int,
	idle:      int,
	wake:      proc(data: rawptr),
	wake_data: rawptr,
	drop:      proc(m: M), // disposal for results the app will never receive
	on_assert: runtime.Assertion_Failure_Proc,
	allocator: runtime.Allocator,
	widths:    Width_Mode, // the UI thread's width mode, applied in workers
}

@(private)
_hub_new :: proc(e: ^Engine($S, $M)) -> ^Task_Hub(M) {
	h := new(Task_Hub(M), runtime.heap_allocator())
	h.allocator = runtime.heap_allocator()
	h.queue = make([dynamic]Task_Req(M), h.allocator)
	h.inbox = make([dynamic]M, h.allocator)
	h.refs = 1
	h.wake = e.wake
	h.wake_data = e.wake_data
	h.drop = e.on_result_drop
	h.on_assert = context.assertion_failure_proc
	return h
}

@(private)
_hub_submit :: proc(h: ^Task_Hub($M), req: Task_Req(M)) {
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	append(&h.queue, req)
	h.widths = width_mode
	if h.idle == 0 && h.workers < MAX_WORKERS {
		h.workers += 1
		h.refs += 1
		// Thread objects free themselves when the worker exits, possibly long
		// after the caller's allocator is gone: allocate them from the hub's.
		context.allocator = h.allocator
		fn: proc(^Task_Hub(M)) = _hub_worker
		thread.create_and_start_with_poly_data(h, fn, self_cleanup = true)
	}
	sync.cond_signal(&h.cond)
}

@(private)
_hub_worker :: proc(h: ^Task_Hub($M)) {
	// A fresh context: thread-local temp allocator, but our crash handler so a
	// failed assertion in a task still restores the terminal.
	context = runtime.default_context()
	context.allocator = h.allocator
	if h.on_assert != nil do context.assertion_failure_proc = h.on_assert

	sync.mutex_lock(&h.mu)
	for {
		for len(h.queue) == 0 && !h.closed {
			h.idle += 1
			sync.cond_wait(&h.cond, &h.mu)
			h.idle -= 1
		}
		if h.closed do break
		req := h.queue[0]
		ordered_remove(&h.queue, 0)
		width_mode = h.widths
		sync.mutex_unlock(&h.mu)
		msg := req.work(req.data)
		free_all(context.temp_allocator)
		sync.mutex_lock(&h.mu)
		if !h.closed {
			append(&h.inbox, msg)
			if h.wake != nil do h.wake(h.wake_data)
		} else {
			drop := h.drop
			if drop != nil {
				sync.mutex_unlock(&h.mu)
				// User code runs off the hub lock — a disposer may re-enter
				// engine APIs (engine_task_stats) — and this worker's
				// reference keeps the hub alive through the callback.
				drop(msg)
				sync.mutex_lock(&h.mu)
			}
		}
	}
	h.workers -= 1
	_hub_release_locked(h)
}

@(private)
_hub_take :: proc(h: ^Task_Hub($M)) -> []M {
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	if len(h.inbox) == 0 do return nil
	out := slice.clone(h.inbox[:], context.temp_allocator)
	clear(&h.inbox)
	return out
}

@(private)
_hub_close :: proc(h: ^Task_Hub($M)) {
	sync.mutex_lock(&h.mu)
	h.closed = true
	h.wake = nil // the wake pipe is about to be closed
	// Queued tasks never run: hand their data back for disposal. Undelivered
	// results are disposed of too. The callbacks run after unlocking (the hub
	// may be freed before they return), so copy what they need.
	cancel_me := slice.clone(h.queue[:], context.temp_allocator)
	clear(&h.queue)
	drop_me := slice.clone(h.inbox[:], context.temp_allocator)
	clear(&h.inbox)
	drop := h.drop
	sync.cond_broadcast(&h.cond)
	_hub_release_locked(h)
	for req in cancel_me do if req.cancel != nil do req.cancel(req.data)
	for m in drop_me do if drop != nil do drop(m)
}

// Called with h.mu held; unlocks it.
@(private)
_hub_release_locked :: proc(h: ^Task_Hub($M)) {
	h.refs -= 1
	last := h.refs == 0
	sync.mutex_unlock(&h.mu)
	if last {
		delete(h.queue)
		delete(h.inbox)
		free(h, h.allocator)
	}
}

// Worker count and queue depth, for diagnostics and tests.
engine_task_stats :: proc(e: ^Engine($S, $M)) -> (workers, queued: int) {
	if e.hub == nil do return
	sync.mutex_lock(&e.hub.mu)
	defer sync.mutex_unlock(&e.hub.mu)
	return e.hub.workers, len(e.hub.queue)
}

@(private)
_engine_apply :: proc(e: ^Engine($S, $M)) {
	// Bounded: a react that sends to itself forever cannot hang the loop.
	for _ in 0 ..< 1024 {
		if th, ok := e.fx.theme.?; ok {
			e.theme = th
			e.fx.theme = nil
		}
		if e.fx.quit do e.quit = true
		for t in e.fx.timers {
			e.timer_seq += 1
			append(&e.timers, Timer(M){due = e.now_ms + i64(t.ms), seq = e.timer_seq, msg = t.msg})
		}
		clear(&e.fx.timers)

		if len(e.fx.tasks) > 0 {
			tasks := slice.clone(e.fx.tasks[:], context.temp_allocator)
			clear(&e.fx.tasks)
			for t in tasks {
				if e.synchronous_tasks {
					append(&e.fx.sends, t.work(t.data))
				} else {
					if e.hub == nil do e.hub = _hub_new(e)
					_hub_submit(e.hub, t)
				}
			}
		}

		if len(e.fx.sends) == 0 do return
		pending := slice.clone(e.fx.sends[:], context.temp_allocator)
		clear(&e.fx.sends)
		for m in pending {
			e.fx.now_ms = e.now_ms
			e.app.react(e.state, m, &e.fx)
		}
	}
}

// ------------------------------------------------------------ harness

// Harness drives an App without a terminal: send events, advance virtual
// time, and snapshot what would be on screen. Tasks run synchronously so
// results are deterministic.
Harness :: struct($S, $M: typeid) {
	engine: Engine(S, M),
	frame:  Frame,
}

harness_init :: proc(h: ^Harness($S, $M), app: App(S, M), state: ^S, w, height: int, theme: Theme = {}) {
	th := theme.name == "" ? theme_nightfall() : theme
	engine_init(&h.engine, app, state, th)
	h.engine.synchronous_tasks = true
	h.frame = frame_make(w, height, &h.engine.theme)
	engine_boot(&h.engine)
	engine_dispatch(&h.engine, Resize{w, height})
}

harness_destroy :: proc(h: ^Harness($S, $M)) {
	engine_destroy(&h.engine)
	frame_destroy(&h.frame)
}

harness_send :: proc(h: ^Harness($S, $M), ev: Event(M)) {
	engine_dispatch(&h.engine, ev)
}

harness_key :: proc(h: ^Harness($S, $M), code: Key_Code, mods: Mods = {}) {
	engine_dispatch(&h.engine, Key{code = code, mods = mods})
}

// harness_click sends a left press at (x, y), resolved against the last paint.
harness_click :: proc(h: ^Harness($S, $M), x, y: int) {
	engine_dispatch(&h.engine, Mouse{x = x, y = y, button = .Left, action = .Press})
}

// harness_type sends each rune of s as a Char key.
harness_type :: proc(h: ^Harness($S, $M), s: string) {
	for r in s do engine_dispatch(&h.engine, Key{code = .Char, ch = r})
}

// harness_advance moves virtual time forward, firing timers in due order.
// Turns where the clock does not move (a zero-delay timer storm: a handler
// rearming with after(fx, 0, …)) are bounded per call; turns that advance the
// clock are not — ten virtual minutes at an 80 ms tick is 7,500 turns and all
// of them run. If the bound stops a storm, the clock stays where it stopped
// rather than claiming the whole span elapsed.
harness_advance :: proc(h: ^Harness($S, $M), ms: int) {
	target := h.engine.now_ms + i64(ms)
	stalled := 0
	for !h.engine.quit {
		next := engine_next_timeout(&h.engine)
		if next < 0 do break
		if h.engine.now_ms + i64(next) > target do break
		if next == 0 {
			stalled += 1
			if stalled >= MAX_STALLED_TURNS do return // clock stays honest: now_ms unchanged
		} else {
			stalled = 0
		}
		h.engine.now_ms += i64(next)
		engine_fire_timers(&h.engine)
	}
	h.engine.now_ms = target
}

// Per-call bound on zero-progress turns (see harness_advance).
MAX_STALLED_TURNS :: 1024

// harness_paint paints and returns the frame (styled cells are inspectable).
harness_paint :: proc(h: ^Harness($S, $M)) -> ^Frame {
	engine_paint(&h.engine, &h.frame)
	return &h.frame
}

// harness_snapshot paints and returns the screen as plain text.
harness_snapshot :: proc(h: ^Harness($S, $M)) -> string {
	return frame_to_text(harness_paint(h))
}


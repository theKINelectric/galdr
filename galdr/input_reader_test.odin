package galdr

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
drain :: proc(r: ^Input_Reader, now: i64) -> []Input {
	out := make([dynamic]Input, context.temp_allocator)
	reader_drain(r, now, &out)
	return out[:]
}

@(test)
test_reader_large_paste_in_chunks :: proc(t: ^testing.T) {
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	body := strings.repeat("x", 12_000, context.temp_allocator)
	full := strings.concatenate({"\x1b[200~", body, "\x1b[201~", "q"}, context.temp_allocator)
	bytes := transmute([]u8)full
	// Arrives in 4 KB reads with pauses shorter than the paste grace period.
	now: i64 = 0
	got := make([dynamic]Input, context.temp_allocator)
	for i := 0; i < len(bytes); i += 4096 {
		reader_feed(&r, bytes[i:min(i + 4096, len(bytes))], now)
		reader_drain(&r, now, &got)
		now += 200
	}
	testing.expect_value(t, len(got), 2)
	p := got[0].(Paste)
	testing.expect_value(t, len(p.text), 12_000)
	testing.expect(t, !p.truncated)
	testing.expect_value(t, got[1].(Key).ch, 'q')
}

@(test)
test_reader_oversized_paste_is_truncated_not_typed :: proc(t: ^testing.T) {
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	body := strings.repeat("y", MAX_INPUT_BYTES + 5000, context.temp_allocator)
	full := strings.concatenate({"\x1b[200~", body, "\x1b[201~", "z"}, context.temp_allocator)
	bytes := transmute([]u8)full
	got := make([dynamic]Input, context.temp_allocator)
	for i := 0; i < len(bytes); i += 65536 {
		reader_feed(&r, bytes[i:min(i + 65536, len(bytes))], 0)
		reader_drain(&r, 0, &got)
	}
	testing.expect_value(t, len(got), 2) // one truncated paste, then 'z' — no stray 'y' keys
	p := got[0].(Paste)
	testing.expect(t, p.truncated)
	testing.expect(t, len(p.text) >= MAX_INPUT_BYTES - 8)
	testing.expect_value(t, got[1].(Key).ch, 'z')
}

@(test)
test_reader_oversized_paste_fed_whole_is_capped :: proc(t: ^testing.T) {
	// Regression (audit A2): a complete 2 MiB paste with both delimiters,
	// fed before draining, used to bypass the cap entirely (delivered whole,
	// truncated=false). The cap must hold however the bytes arrive.
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	body := strings.repeat("x", 2 * MAX_INPUT_BYTES, context.temp_allocator)
	full := strings.concatenate({PASTE_START, body, PASTE_END, "q"}, context.temp_allocator)
	reader_feed(&r, transmute([]u8)full, 0)
	testing.expect(t, len(r.buf) <= MAX_INPUT_BYTES + 1,
		fmt.tprintf("buffer holds %d bytes, cap is %d", len(r.buf), MAX_INPUT_BYTES))
	evs := drain(&r, 0)
	testing.expect_value(t, len(evs), 2) // the truncated paste, then the key after the terminator
	p := evs[0].(Paste)
	testing.expect(t, p.truncated)
	testing.expect_value(t, len(p.text), MAX_INPUT_BYTES - len(PASTE_START))
	testing.expect_value(t, evs[1].(Key).ch, 'q')
}

@(test)
test_reader_many_feeds_before_drain_stay_capped :: proc(t: ^testing.T) {
	// Regression (audit A2): repeated feeds before draining used to grow the
	// buffer without bound; the runtime itself reads several chunks per drain.
	// This feeds a whole oversized paste — terminator and trailing key
	// included — in chunks, draining only at the end.
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	body := strings.repeat("y", MAX_INPUT_BYTES + 5000, context.temp_allocator)
	full := strings.concatenate({PASTE_START, body, PASTE_END, "q"}, context.temp_allocator)
	bytes := transmute([]u8)full
	for i := 0; i < len(bytes); i += 16384 {
		reader_feed(&r, bytes[i:min(i + 16384, len(bytes))], 0)
		testing.expect(t, len(r.buf) <= MAX_INPUT_BYTES + INPUT_SLACK,
			fmt.tprintf("buffer grew to %d bytes at feed %d", len(r.buf), i))
	}
	evs := drain(&r, 0)
	testing.expect_value(t, len(evs), 2) // truncated paste, then the key after the terminator
	p := evs[0].(Paste)
	testing.expect(t, p.truncated)
	testing.expect_value(t, len(p.text), MAX_INPUT_BYTES - len(PASTE_START))
	testing.expect_value(t, evs[1].(Key).ch, 'q')
}

@(test)
test_reader_late_opener_near_cap_does_not_crash :: proc(t: ^testing.T) {
	// Re-review case 1: garbage followed by a paste opener near the end of a
	// buffer just past the cap used to slice out of range and crash.
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	data := strings.concatenate({"abc", PASTE_START, strings.repeat("x", MAX_INPUT_BYTES, context.temp_allocator)}, context.temp_allocator)
	reader_feed(&r, transmute([]u8)data, 0)
	testing.expect(t, len(r.buf) <= MAX_INPUT_BYTES + INPUT_SLACK)
	evs := drain(&r, 0)
	testing.expect_value(t, len(evs), 1)
	p := evs[0].(Paste)
	testing.expect(t, p.truncated)
	testing.expect_value(t, len(p.text), MAX_INPUT_BYTES - len(PASTE_START))
}

@(test)
test_reader_split_terminator_survives_byte_feeds :: proc(t: ^testing.T) {
	// Re-review case 2: after truncation, a terminator fed one byte at a
	// time used to never accumulate; the following key was swallowed.
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	paste := strings.concatenate({PASTE_START, strings.repeat("x", MAX_INPUT_BYTES + 100, context.temp_allocator)}, context.temp_allocator)
	reader_feed(&r, transmute([]u8)paste, 0) // crosses the cap: truncated, discarding
	testing.expect(t, r.discarding)
	for b in transmute([]u8)string(PASTE_END) do reader_feed(&r, []u8{b}, 1)
	testing.expect(t, !r.discarding, "the split terminator was recognized")
	reader_feed(&r, transmute([]u8)string("q"), 1)
	evs := drain(&r, 1)
	testing.expect(t, len(evs) >= 1 && evs[0].(Paste).truncated)
	testing.expect_value(t, evs[len(evs) - 1].(Key).ch, 'q')
}

@(test)
test_reader_partial_terminator_at_cap_boundary :: proc(t: ^testing.T) {
	// Re-review case 3: the feed that first crosses the cap used to lose its
	// own partial terminator suffix; the terminator and following key vanished.
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	paste := strings.concatenate({PASTE_START, strings.repeat("x", MAX_INPUT_BYTES, context.temp_allocator), "\x1b[20"}, context.temp_allocator)
	reader_feed(&r, transmute([]u8)paste, 0) // ends mid-terminator
	testing.expect(t, r.discarding)
	reader_feed(&r, transmute([]u8)string("1~q"), 0)
	testing.expect(t, !r.discarding)
	evs := drain(&r, 0)
	testing.expect(t, len(evs) >= 1 && evs[0].(Paste).truncated)
	testing.expect_value(t, evs[len(evs) - 1].(Key).ch, 'q')
}

@(test)
test_reader_exactly_cap_complete_paste_decodes_whole :: proc(t: ^testing.T) {
	// Re-review case 4: a complete paste of exactly MAX_INPUT_BYTES bytes,
	// with one more key in the same feed, used to be truncated instead of
	// decoded, losing the key.
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	content := MAX_INPUT_BYTES - len(PASTE_START) - len(PASTE_END)
	paste := strings.concatenate({PASTE_START, strings.repeat("z", content, context.temp_allocator), PASTE_END, "q"}, context.temp_allocator)
	testing.expect_value(t, len(paste), MAX_INPUT_BYTES + 1)
	reader_feed(&r, transmute([]u8)paste, 0)
	testing.expect(t, !r.oversize, "a complete paste is never truncated")
	evs := drain(&r, 0)
	testing.expect_value(t, len(evs), 2)
	p := evs[0].(Paste)
	testing.expect(t, !p.truncated)
	testing.expect_value(t, len(p.text), content)
	testing.expect_value(t, evs[1].(Key).ch, 'q')
}

@(test)
test_reader_complete_short_paste_not_absorbed_by_flood :: proc(t: ^testing.T) {
	// Re-review case 5: a complete short paste followed by a large ordinary
	// suffix used to be reinterpreted as one oversized paste.
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	data := strings.concatenate({PASTE_START, "ok", PASTE_END, strings.repeat("a", 2 * MAX_INPUT_BYTES, context.temp_allocator)}, context.temp_allocator)
	reader_feed(&r, transmute([]u8)data, 0)
	testing.expect(t, !r.oversize, "the completed paste stays normal input")
	testing.expect(t, len(r.buf) <= MAX_INPUT_BYTES + INPUT_SLACK,
		fmt.tprintf("buffer grew to %d bytes", len(r.buf)))
	evs := drain(&r, 0)
	p := evs[0].(Paste)
	testing.expect_value(t, p.text, "ok")
	testing.expect(t, !p.truncated)
	testing.expect(t, len(evs) <= MAX_INPUT_BYTES + INPUT_SLACK, fmt.tprintf("%d events", len(evs)))
}

@(test)
test_reader_oversize_pending_queue_stays_bounded :: proc(t: ^testing.T) {
	// Re-review case 6: with a capped paste waiting for delivery, a further
	// 2 MiB feed used to append without bound.
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	paste := strings.concatenate({PASTE_START, strings.repeat("x", MAX_INPUT_BYTES + 1000, context.temp_allocator)}, context.temp_allocator)
	reader_feed(&r, transmute([]u8)paste, 0) // crosses the cap: truncated, discarding, no terminator yet
	flood := strings.repeat("y", 2 * MAX_INPUT_BYTES, context.temp_allocator)
	reader_feed(&r, transmute([]u8)flood, 1)
	testing.expect(t, len(r.buf) <= MAX_INPUT_BYTES + INPUT_SLACK,
		fmt.tprintf("buffer grew to %d bytes with a paste pending", len(r.buf)))
	evs := drain(&r, 1)
	testing.expect_value(t, len(evs), 1)
	testing.expect(t, evs[0].(Paste).truncated)
	// The quiet-gap recovery lets input resume after the lost terminator.
	reader_feed(&r, transmute([]u8)string("k"), 1 + PASTE_WAIT_MS + 1)
	evs = drain(&r, 1 + PASTE_WAIT_MS + 1)
	testing.expect_value(t, len(evs), 1)
	testing.expect_value(t, evs[0].(Key).ch, 'k')
}

@(test)
test_reader_terminator_straddling_truncation_point :: proc(t: ^testing.T) {
	// Re-review round 2: a terminator starting one to four bytes BEFORE the
	// cap used to be lost — the split-terminator tail was kept from the
	// overflow only, not from the retained side of the truncation point.
	end := transmute([]u8)string(PASTE_END)
	for before in 1 ..= 4 {
		r: Input_Reader
		reader_init(&r)
		defer reader_destroy(&r)
		content := MAX_INPUT_BYTES - len(PASTE_START) - before
		feed1 := strings.concatenate({PASTE_START, strings.repeat("x", content, context.temp_allocator), string(end[:before + 1])}, context.temp_allocator)
		testing.expect_value(t, len(feed1), MAX_INPUT_BYTES + 1)
		reader_feed(&r, transmute([]u8)feed1, 0)
		testing.expect(t, r.discarding)
		tail_feed := strings.concatenate({string(end[before + 1:]), "q"}, context.temp_allocator)
		reader_feed(&r, transmute([]u8)tail_feed, 0)
		testing.expectf(t, !r.discarding, "terminator %d bytes before the cap was lost", before)
		evs := drain(&r, 0)
		testing.expectf(t, len(evs) == 2 && evs[0].(Paste).truncated, "feed %d: %d events", before, len(evs))
		testing.expectf(t, evs[len(evs) - 1].(Key).ch == 'q', "feed %d lost the trailing key", before)
	}
}

@(test)
test_reader_delivered_paste_text_stays_within_bound :: proc(t: ^testing.T) {
	// Re-review round 2: a complete paste can carry up to INPUT_SLACK more
	// than MAX_INPUT_BYTES of text (it fits the buffered bound) and is
	// delivered whole. The delivered text must never exceed the bound.
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	content := MAX_INPUT_BYTES + INPUT_SLACK - len(PASTE_START) - len(PASTE_END)
	paste := strings.concatenate({PASTE_START, strings.repeat("w", content, context.temp_allocator), PASTE_END}, context.temp_allocator)
	testing.expect_value(t, len(paste), MAX_INPUT_BYTES + INPUT_SLACK)
	reader_feed(&r, transmute([]u8)paste, 0)
	testing.expect(t, len(r.buf) <= MAX_INPUT_BYTES + INPUT_SLACK)
	evs := drain(&r, 0)
	testing.expect_value(t, len(evs), 1)
	p := evs[0].(Paste)
	testing.expect(t, !p.truncated)
	testing.expect(t, len(p.text) <= MAX_INPUT_BYTES + INPUT_SLACK - len(PASTE_START) - len(PASTE_END),
		fmt.tprintf("delivered %d bytes of paste text", len(p.text)))
}

@(test)
test_reader_garbage_flood_is_bounded :: proc(t: ^testing.T) {
	// A non-paste flood is not buffered beyond the cap, so at most one cap's
	// worth can ever decode, and the reader keeps working afterwards.
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	chunk := strings.repeat("a", 65536, context.temp_allocator)
	bytes := transmute([]u8)chunk
	for _ in 0..<40 { // 2.6 MiB total, never draining
		reader_feed(&r, bytes, 0)
		testing.expect(t, len(r.buf) <= MAX_INPUT_BYTES + INPUT_SLACK,
			fmt.tprintf("buffer grew to %d bytes", len(r.buf)))
	}
	evs := drain(&r, 0)
	testing.expect(t, len(evs) <= MAX_INPUT_BYTES + INPUT_SLACK, fmt.tprintf("%d events", len(evs)))
	reader_feed(&r, transmute([]u8)string("z"), 0)
	evs = drain(&r, 0)
	testing.expect_value(t, len(evs), 1)
	testing.expect_value(t, evs[0].(Key).ch, 'z')
}

@(test)
test_reader_escape_timing :: proc(t: ^testing.T) {
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	reader_feed(&r, transmute([]u8)string("\x1b"), 100)
	testing.expect_value(t, len(drain(&r, 100)), 0)
	testing.expect_value(t, reader_timeout(&r, 110), ESC_WAIT_MS - 10)
	// The rest of an arrow key arrives in time: one Up, not Escape + "[A".
	reader_feed(&r, transmute([]u8)string("[A"), 115)
	evs := drain(&r, 115)
	testing.expect_value(t, len(evs), 1)
	testing.expect_value(t, evs[0].(Key).code, Key_Code.Up)
	// A lone ESC becomes Escape once the wait expires.
	reader_feed(&r, transmute([]u8)string("\x1b"), 200)
	testing.expect_value(t, len(drain(&r, 210)), 0)
	evs = drain(&r, 200 + ESC_WAIT_MS)
	testing.expect_value(t, evs[0].(Key).code, Key_Code.Escape)
	testing.expect_value(t, reader_timeout(&r, 300), -1)
}

@(test)
test_reader_unterminated_paste_flushes_after_grace :: proc(t: ^testing.T) {
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	reader_feed(&r, transmute([]u8)string("\x1b[200~partial"), 0)
	testing.expect_value(t, len(drain(&r, ESC_WAIT_MS + 5)), 0) // not flushed like an ESC
	evs := drain(&r, PASTE_WAIT_MS)
	testing.expect_value(t, len(evs), 1)
	testing.expect(t, evs[0].(Paste).truncated)
	// Input keeps flowing afterwards; a stray late terminator is ignored.
	reader_feed(&r, transmute([]u8)string("\x1b[201~k"), PASTE_WAIT_MS + 10)
	evs = drain(&r, PASTE_WAIT_MS + 10)
	testing.expect_value(t, len(evs), 1)
	testing.expect_value(t, evs[0].(Key).ch, 'k')
}

@(test)
test_reader_discard_never_locks_input :: proc(t: ^testing.T) {
	r: Input_Reader
	reader_init(&r)
	defer reader_destroy(&r)
	r.discarding = true // as after a size-cap truncation whose terminator is lost
	r.last_feed = 0
	reader_feed(&r, transmute([]u8)string("still pasting"), 10)
	testing.expect_value(t, len(drain(&r, 10)), 0)
	reader_feed(&r, transmute([]u8)string("j"), 10 + PASTE_WAIT_MS + 1)
	evs := drain(&r, 10 + PASTE_WAIT_MS + 1)
	testing.expect_value(t, len(evs), 1)
	testing.expect_value(t, evs[0].(Key).ch, 'j')
}

package galdr

import "core:strings"

// Input_Reader buffers raw terminal bytes and turns them into Inputs. It owns
// the timing rules the pure decoder can't: when an incomplete sequence has
// waited long enough to be flushed, and what to do with oversized pastes.

MAX_INPUT_BYTES :: 1 << 20 // hard cap on buffered input (and on one paste)
INPUT_SLACK     :: 64       // constant head-room past the cap: delimiters, a trailing key
ESC_WAIT_MS     :: 30       // a lone ESC becomes the Escape key after this
PASTE_WAIT_MS   :: 1000     // an unterminated paste is flushed after this

@(private)
PASTE_START :: "\x1b[200~"

Input_Reader :: struct {
	buf:           [dynamic]u8,
	tail:          [len(PASTE_END) - 1]u8, // discarded bytes that may complete a split terminator
	tail_len:      int,
	oversize:      bool, // buf[0:content_end] holds a paste cut at the cap, waiting to be delivered
	content_end:   int,
	pending_since: i64, // ms timestamp when incomplete data started waiting; -1 = none
	discarding:    bool, // inside an over-long paste: drop bytes until PASTE_END
	last_feed:     i64, // ms timestamp of the most recent bytes
}

reader_init :: proc(r: ^Input_Reader, allocator := context.allocator) {
	r.buf = make([dynamic]u8, 0, 4096, allocator)
	r.pending_since = -1
}

reader_destroy :: proc(r: ^Input_Reader) {
	delete(r.buf)
}

// _find_paste_end locates PASTE_END in the logical stream tail||data without
// building the join. Returns the index in data just past the terminator, or
// -1. A terminator straddling the boundary ends earliest, so it is checked
// before a complete occurrence inside data.
@(private)
_find_paste_end :: proc(tail: []u8, data: []u8) -> int {
	pe := transmute([]u8)string(PASTE_END)
	for split := min(len(tail), len(pe) - 1); split >= 1; split -= 1 {
		k := len(pe) - split
		if len(data) < k do continue
		match := true
		for i in 0 ..< split do if tail[len(tail) - split + i] != pe[i] { match = false; break }
		for i in 0 ..< k do if data[i] != pe[split + i] { match = false; break }
		if match do return k
	}
	if end := _index(data, pe); end >= 0 do return end + len(pe)
	return -1
}

// _retain_tail keeps the last few bytes of the logical stream tail||data, so
// a terminator split across reads is still recognized by the next feed.
@(private)
_retain_tail :: proc(r: ^Input_Reader, data: []u8) {
	keep := min(len(r.tail), r.tail_len + len(data))
	if keep <= 0 {
		r.tail_len = 0
		return
	}
	if keep <= len(data) {
		copy(r.tail[:], data[len(data)-keep:])
	} else {
		from_tail := keep - len(data)
		copy(r.tail[:], r.tail[r.tail_len-from_tail:])
		copy(r.tail[from_tail:], data)
	}
	r.tail_len = keep
}

// _begin_oversize converts an in-progress paste (an opener whose terminator
// has not arrived) into a capped paste awaiting delivery: buf is truncated at
// the cap, the delivered text is flagged truncated, and the rest of the paste
// is discarded until its terminator. A paste that is already complete is
// normal input and is left alone. Returns true if it converted.
@(private)
_begin_oversize :: proc(r: ^Input_Reader) -> bool {
	start := _index(r.buf[:], transmute([]u8)string(PASTE_START))
	if start < 0 do return false
	rest := r.buf[start + len(PASTE_START):]
	if _index(rest, transmute([]u8)string(PASTE_END)) >= 0 do return false
	if start > 0 do remove_range(&r.buf, 0, start) // drop garbage before the paste
	content_end := min(len(r.buf), MAX_INPUT_BYTES)
	r.content_end = content_end
	r.oversize = true
	r.discarding = true
	r.pending_since = -1
	// A terminator that is already complete returned earlier, so the only one
	// that can be pending here straddles the truncation point: keep the suffix
	// of the whole buffered stream, not just the overflow.
	keep := min(len(r.tail), len(r.buf))
	copy(r.tail[:], r.buf[len(r.buf)-keep:])
	r.tail_len = keep
	resize(&r.buf, content_end)
	return true
}

// reader_feed appends freshly read bytes. In every state the reader holds at
// most MAX_INPUT_BYTES + INPUT_SLACK bytes: input that arrives faster than
// the app drains is dropped, and an oversized paste is delivered truncated
// with its remainder discarded. The bound holds however the bytes arrive —
// one giant feed or many feeds before a drain.
reader_feed :: proc(r: ^Input_Reader, data: []u8, now_ms: i64) {
	// Never discard forever: if the terminator is lost, resume after a quiet gap.
	if r.discarding && now_ms - r.last_feed > PASTE_WAIT_MS {
		r.discarding = false
		r.oversize = false
		r.tail_len = 0
		clear(&r.buf) // the kept bytes were paste content, not keystrokes
	}
	r.last_feed = now_ms
	pos := 0
	if r.discarding {
		if end := _find_paste_end(r.tail[:r.tail_len], data); end < 0 {
			_retain_tail(r, data)
			if !r.oversize do clear(&r.buf)
			return
		} else {
			r.discarding = false
			r.tail_len = 0
			pos = end
		}
	}
	// Accept only what fits under the bound.
	room := MAX_INPUT_BYTES + INPUT_SLACK - len(r.buf)
	take := clamp(len(data) - pos, 0, room)
	append(&r.buf, ..data[pos:pos+take])
	pos += take
	if r.pending_since < 0 && len(r.buf) > 0 && !r.discarding do r.pending_since = now_ms

	if pos >= len(data) {
		// Everything fit. An in-progress paste that passed the cap becomes a
		// truncated paste; a completed one decodes normally, whatever follows.
		if !r.oversize && len(r.buf) > MAX_INPUT_BYTES do _begin_oversize(r)
		return
	}
	// The buffer is full and data remains: an in-progress paste truncates and
	// swallows its tail; any other overflow is dropped.
	if !r.oversize && !_begin_oversize(r) do return
	if !r.discarding do return
	rest := data[pos:]
	if end := _find_paste_end(r.tail[:r.tail_len], rest); end >= 0 {
		r.discarding = false
		r.tail_len = 0
		rest = rest[end:]
		room = MAX_INPUT_BYTES + INPUT_SLACK - len(r.buf)
		if room > 0 {
			take = min(len(rest), room)
			append(&r.buf, ..rest[:take])
			if r.pending_since < 0 do r.pending_since = now_ms
		}
	} else {
		_retain_tail(r, rest)
	}
}

// reader_timeout reports how long the caller may block before calling
// reader_drain again (-1 = no deadline).
reader_timeout :: proc(r: ^Input_Reader, now_ms: i64) -> int {
	if r.oversize do return 0 // a capped paste is waiting to be delivered
	if len(r.buf) == 0 || r.discarding do return -1
	wait := _in_paste(r) ? PASTE_WAIT_MS : ESC_WAIT_MS
	return int(max(r.pending_since + i64(wait) - now_ms, 0))
}

@(private)
_in_paste :: proc(r: ^Input_Reader) -> bool {
	return strings.has_prefix(string(r.buf[:]), PASTE_START)
}

// reader_drain decodes every complete Input into out. Paste text is cloned
// into the temp allocator, so it stays valid until the next free_all.
reader_drain :: proc(r: ^Input_Reader, now_ms: i64, out: ^[dynamic]Input) {
	if r.oversize {
		// Deliver the paste that was cut at the cap (truncated), then decode
		// whatever real input was queued behind it.
		content := string(r.buf[len(PASTE_START):r.content_end])
		append(out, Paste{text = strings.clone(content, context.temp_allocator), truncated = true})
		remove_range(&r.buf, 0, r.content_end)
		r.oversize = false
		r.pending_since = len(r.buf) > 0 ? now_ms : -1
	}
	if r.discarding do return // buf only holds a possible split terminator
	pos := 0
	for pos < len(r.buf) {
		rest := r.buf[pos:]
		waited := r.pending_since >= 0 ? now_ms - r.pending_since : 0
		flush_after := strings.has_prefix(string(rest), PASTE_START) ? PASTE_WAIT_MS : ESC_WAIT_MS
		flush := waited >= i64(flush_after)

		ev, used, st := decode(rest, flush)
		if st == .Need_More do break
		pos += used
		if st != .Ok do continue
		if p, is_paste := ev.(Paste); is_paste {
			// A timeout flush (terminator never came) does not discard: a late
			// ESC[201~ decodes as an unknown sequence and is skipped.
			p.text = strings.clone(p.text, context.temp_allocator)
			ev = p
		}
		append(out, ev)
	}
	remove_range(&r.buf, 0, pos)
	r.pending_since = len(r.buf) > 0 ? (pos > 0 ? now_ms : r.pending_since) : -1
}

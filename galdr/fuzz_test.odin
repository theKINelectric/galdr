package galdr

import "core:fmt"
import "core:math/rand"
import "core:testing"

// ------------------------------------------------------------ decoder fuzzing

@(private = "file")
FRAGMENTS := [?]string{
	"\x1b", "\x1b[", "\x1b[1;5", "A", "\x1b[200~", "\x1b[201~", "\x1b[<0;3;4M", "\x1b[<", "\x1bO",
	"\x1b]11;rgb:1/2/3\x07", "\x1b]", "\x1bP>|x\x1b\\", "\x1b[?1u", "\x1b[99;5u", "é", "日", "\xe6\x97",
	"\xff", "\x00", "\x7f", "\r", "\t", "q", "\x1b\x1b", "\x1b[3~", ";", "~", "\x9b", "\x1b[?2026;2$y",
}

@(private = "file")
random_stream :: proc() -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< rand.int_max(40) + 1 {
		if rand.float32() < 0.3 {
			for _ in 0 ..< rand.int_max(6) + 1 do append(&out, u8(rand.int_max(256)))
		} else {
			append(&out, ..transmute([]u8)rand.choice(FRAGMENTS[:]))
		}
	}
	return out[:]
}

@(private = "file")
Summary :: struct {
	keys, mice, pastes, focus: int,
	text:                      [dynamic]rune,
}

@(private = "file")
feed_all :: proc(r: ^Input_Reader, stream: []u8, splits: []int) -> Summary {
	s: Summary
	s.text = make([dynamic]rune, context.temp_allocator)
	out := make([dynamic]Input, context.temp_allocator)
	prev := 0
	for cut in splits {
		reader_feed(r, stream[prev:cut], 0)
		reader_drain(r, 0, &out)
		prev = cut
	}
	reader_feed(r, stream[prev:], 0)
	reader_drain(r, 0, &out)
	reader_drain(r, PASTE_WAIT_MS + 1, &out) // everything left must flush
	for ev in out {
		switch v in ev {
		case Key:
			s.keys += 1
			append(&s.text, v.ch)
		case Mouse: s.mice += 1
		case Paste: s.pastes += 1
		case Focus: s.focus += 1
		}
	}
	return s
}

@(test)
test_fuzz_decoder_progress_and_chunking :: proc(t: ^testing.T) {
	for i in 0 ..< 3000 {
		stream := random_stream()

		// Invariant 1: decode always makes progress or asks for more.
		pos := 0
		for pos < len(stream) {
			_, n, st := decode(stream[pos:], flush = true)
			if n <= 0 {
				testing.expectf(t, false, "decode made no progress (status %v) at %d in case %d: %q", st, pos, i, string(stream))
				return
			}
			pos += n
		}

		// Invariant 2: splitting the bytes into reads changes nothing.
		whole: Input_Reader
		reader_init(&whole, context.temp_allocator)
		a := feed_all(&whole, stream, nil)
		split: Input_Reader
		reader_init(&split, context.temp_allocator)
		cuts := make([dynamic]int, context.temp_allocator)
		c := 0
		for c < len(stream) {
			c += rand.int_max(5) + 1
			if c < len(stream) do append(&cuts, c)
		}
		b := feed_all(&split, stream, cuts[:])
		same := a.keys == b.keys && a.mice == b.mice && a.pastes == b.pastes && a.focus == b.focus &&
			fmt.tprint(a.text[:]) == fmt.tprint(b.text[:])
		if !same {
			testing.expectf(t, false, "chunking changed the result in case %d: %q (%v vs %v)", i, string(stream), a, b)
			return
		}
		// Invariant 3: nothing is left behind once the flush deadline passes.
		testing.expectf(t, len(whole.buf) == 0 && len(split.buf) == 0, "bytes stuck in the reader (case %d)", i)
	}
}

// ------------------------------------------------------------ contrast

@(test)
test_theme_contrast :: proc(t: ^testing.T) {
	for i in 0 ..< THEME_COUNT {
		th := theme_by_index(i)
		check :: proc(t: ^testing.T, th: ^Theme, what: string, fg, bg: Color, need: f64) {
			r := contrast_ratio(fg, bg)
			testing.expectf(t, r >= need, "%s: %s contrast %.2f < %.1f", th.name, what, r, need)
		}
		// Body text: WCAG AA (4.5:1).
		check(t, &th, "ink on bg", th.ink, th.bg, 4.5)
		check(t, &th, "ink on surface", th.ink, th.surface, 4.5)
		check(t, &th, "ink on raised", th.ink, th.raised, 4.5)
		// Secondary text and UI glyphs: AA for large text / UI components (3:1).
		check(t, &th, "muted on surface", th.muted, th.surface, 3.0)
		for tone in Tone {
			name := fmt.tprintf("%v", tone)
			// Solid badges and buttons: label on its tone.
			check(t, &th, fmt.tprintf("on_tone on %s", name), th.on_tone[tone], th.tones[tone], 4.5)
			// Tone-colored text and icons on panels (Soft/Ghost/Outline).
			if tone != .Neutral {
				check(t, &th, fmt.tprintf("%s on surface", name), th.tones[tone], th.surface, 3.0)
			}
		}
	}
}

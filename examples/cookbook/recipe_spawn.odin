package cookbook

// Recipe: background work with `spawn`. The result comes back as a message.

import gd "galdr:galdr"
import "core:fmt"

Primes_Done :: struct {
	below, count: int,
}

Work_Msg :: union {
	Primes_Done,
}

Work_State :: struct {
	busy:   bool,
	result: Maybe(Primes_Done),
}

// count_primes runs on a worker thread. It must not touch the State:
// everything it needs comes in through data, everything it found goes out
// in the message it returns.
count_primes :: proc(data: rawptr) -> Work_Msg {
	below := int(uintptr(data))
	count := 0
	outer: for n in 2 ..< below {
		for d := 2; d * d <= n; d += 1 {
			if n % d == 0 do continue outer
		}
		count += 1
	}
	return Primes_Done{below, count}
}

work_react :: proc(s: ^Work_State, ev: gd.Event(Work_Msg), fx: ^gd.Fx(Work_Msg)) {
	#partial switch e in ev {
	case gd.Key:
		if gd.is_char(e, 'g') && !s.busy {
			s.busy = true
			gd.spawn(fx, count_primes, rawptr(uintptr(50_000)))
		}
		if gd.is_char(e, 'q') do gd.quit(fx)
	case Work_Msg:
		switch m in e {
		case Primes_Done:
			s.busy = false
			s.result = m
		}
	}
}

work_paint :: proc(s: ^Work_State, f: ^gd.Frame) {
	th := f.theme
	switch {
	case s.busy:
		gd.spinner(f, 1, 1, int(f.now_ms / gd.SPINNER_MS), .Dots, .Primary, "counting…")
	case s.result != nil:
		r := s.result.?
		gd.text(f, 1, 1, fmt.tprintf("%d primes below %d", r.count, r.below), gd.text_pen(th))
	case:
		gd.text(f, 1, 1, "g count primes · q quit", gd.muted_pen(th))
	}
}

WORK_APP :: gd.App(Work_State, Work_Msg){react = work_react, paint = work_paint}

work_run :: proc() -> gd.Run_Error {
	s: Work_State
	return gd.run(WORK_APP, &s)
}

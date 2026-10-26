package counter

// The README's example, kept here so it always compiles.
//   odin run examples/readme -collection:galdr=.

import gd "galdr:galdr"
import "core:fmt"

State :: struct { count: int }

react :: proc(s: ^State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	#partial switch e in ev {
	case gd.Key:
		if gd.is_char(e, '+') do s.count += 1
		if gd.is_char(e, '-') do s.count -= 1
		if gd.is_char(e, 'q') do gd.quit(fx)
	}
}

paint :: proc(s: ^State, f: ^gd.Frame) {
	card := gd.panel(f, gd.center(gd.frame_bounds(f), 30, 5), "counter")
	gd.text(f, card.x, card.y, fmt.tprintf("count = %d", s.count), gd.text_pen(f.theme))
	gd.text(f, card.x, card.y + 2, "+ / - to count, q to quit", gd.muted_pen(f.theme))
}

main :: proc() {
	s: State
	gd.run(gd.App(State, gd.No_Msg){react = react, paint = paint}, &s)
}

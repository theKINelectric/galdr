package cookbook

// Recipe: an inline picker that draws under the prompt, like fzf.

import gd "galdr:galdr"
import "core:fmt"
import "core:os"

FLAVORS := [?]string{"vanilla", "chocolate", "strawberry", "pistachio", "mango"}

Pick_State :: struct {
	list:   gd.Pick_List,
	picked: int, // -1 until Enter
}

pick_react :: proc(s: ^Pick_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	k, is_key := ev.(gd.Key)
	if !is_key do return
	switch {
	case k.code == .Enter:
		s.picked = s.list.cursor
		gd.quit(fx)
	case k.code == .Escape, gd.is_ctrl(k, 'c'):
		gd.quit(fx)
	case:
		gd.pick_on_key(&s.list, k, len(FLAVORS))
	}
}

pick_paint :: proc(s: ^Pick_State, f: ^gd.Frame) {
	gd.text(f, 0, 0, "Pick a flavor:", gd.muted_pen(f.theme))
	gd.pick_draw(f, {0, 1, f.w, f.h - 1}, &s.list, FLAVORS[:])
}

PICK_APP :: gd.App(Pick_State, gd.No_Msg){react = pick_react, paint = pick_paint}

inline_run :: proc() -> gd.Run_Error {
	s := Pick_State{picked = -1}
	err := gd.run(PICK_APP, &s, {inline = true, height = 6})
	if err != .None do return err
	if s.picked < 0 do os.exit(1) // canceled
	fmt.println(FLAVORS[s.picked]) // the terminal is ours again: stdout is safe
	return .None
}

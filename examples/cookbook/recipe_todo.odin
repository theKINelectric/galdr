package cookbook

// Recipe: a Pick_List of items and a Text_Field to add to it.

import gd "galdr:galdr"
import "core:strings"

Todo_State :: struct {
	items: [dynamic]string, // owned
	list:  gd.Pick_List,
	input: gd.Text_Field,
}

todo_react :: proc(s: ^Todo_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	#partial switch e in ev {
	case gd.Key:
		switch {
		case e.code == .Escape, gd.is_ctrl(e, 'c'):
			gd.quit(fx)
		case e.code == .Enter:
			item := strings.trim_space(gd.field_text(&s.input)) // temp allocated
			if item != "" {
				append(&s.items, strings.clone(item))
				s.list.cursor = len(s.items) - 1
			}
			gd.field_clear(&s.input)
		case e.code == .Up, e.code == .Down:
			gd.pick_on_key(&s.list, e, len(s.items))
		case:
			gd.field_on_key(&s.input, e)
		}
	case gd.Paste:
		gd.field_insert(&s.input, e.text)
	}
}

todo_paint :: proc(s: ^Todo_State, f: ^gd.Frame) {
	area := gd.frame_bounds(f)
	input := gd.cut_bottom(&area, 1)
	gd.pick_draw(f, area, &s.list, s.items[:])
	gd.field_draw(f, input, &s.input)
}

todo_boot :: proc(s: ^Todo_State, fx: ^gd.Fx(gd.No_Msg)) {
	s.input.placeholder = "new item, then enter"
	s.input.limit = 80
}

todo_destroy :: proc(s: ^Todo_State) {
	for item in s.items do delete(item)
	delete(s.items)
	gd.field_destroy(&s.input)
}

TODO_APP :: gd.App(Todo_State, gd.No_Msg){boot = todo_boot, react = todo_react, paint = todo_paint}

todo_run :: proc() -> gd.Run_Error {
	s: Todo_State
	defer todo_destroy(&s)
	return gd.run(TODO_APP, &s)
}

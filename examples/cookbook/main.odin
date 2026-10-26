package cookbook

// The code behind docs/COOKBOOK.md. Every snippet in the cookbook is copied
// from these files, and cookbook_test.odin checks that it still is.
//   odin run examples/cookbook -collection:galdr=. -- clock

import gd "galdr:galdr"
import "core:fmt"
import "core:os"

RECIPES :: "clock work layout keys focus mouse todo confirm form theme inline markdown log"

main :: proc() {
	name := len(os.args) > 1 ? os.args[1] : ""
	err: gd.Run_Error
	switch name {
	case "clock":    err = clock_run()
	case "work":     err = work_run()
	case "layout":   err = layout_run()
	case "keys":     err = keys_run()
	case "focus":    err = focus_run()
	case "mouse":    err = mouse_run()
	case "todo":     err = todo_run()
	case "confirm":  err = confirm_run()
	case "form":     err = signup_run()
	case "theme":    err = theme_run()
	case "inline":   err = inline_run()
	case "markdown": err = doc_run()
	case "log":      err = log_run()
	case:
		fmt.eprintln("usage: cookbook <recipe>")
		fmt.eprintln("recipes:", RECIPES)
		os.exit(2)
	}
	if err != .None {
		fmt.eprintln("cookbook: cannot start:", err)
		os.exit(1)
	}
}

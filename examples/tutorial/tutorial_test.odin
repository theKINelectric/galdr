package tutorial

import gd "galdr:galdr"
import "core:os"
import "core:strings"
import "core:testing"

// ---- step 6: testing

@(test)
test_tasks :: proc(t: ^testing.T) {
	s: State
	defer destroy(&s)
	h: gd.Harness(State, Msg)
	gd.harness_init(&h, gd.App(State, Msg){boot = boot, react = react, paint = paint}, &s, 60, 12)
	defer gd.harness_destroy(&h)

	screen := gd.harness_snapshot(&h)
	testing.expect(t, strings.contains(screen, "0 of 3 done"), screen)

	// Toggle the second task.
	gd.harness_key(&h, .Down)
	gd.harness_type(&h, " ")
	testing.expect(t, s.tasks[1].done)
	testing.expect(t, strings.contains(gd.harness_snapshot(&h), "1 of 3 done"))

	// Add a task through the input line.
	gd.harness_type(&h, "a")
	gd.harness_type(&h, "Buy bread")
	gd.harness_key(&h, .Enter)
	testing.expect_value(t, len(s.tasks), 4)
	testing.expect_value(t, s.tasks[3].title, "Buy bread")
	testing.expect(t, !s.adding)

	// The clock runs on virtual time.
	gd.harness_advance(&h, 3000)
	testing.expect_value(t, s.seconds, 3)
}

@(test)
test_save :: proc(t: ^testing.T) {
	s: State
	defer destroy(&s)
	s.path = "tutorial_test_tasks.txt"
	defer os.remove(s.path)
	h: gd.Harness(State, Msg)
	gd.harness_init(&h, gd.App(State, Msg){boot = boot, react = react, paint = paint}, &s, 60, 12)
	defer gd.harness_destroy(&h)

	gd.harness_type(&h, " s") // tick the first task, then save
	testing.expect_value(t, s.status, "saved") // tasks run synchronously in the harness

	data, err := os.read_entire_file_from_path(s.path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, strings.has_prefix(string(data), "[x] Water the plants\n"), string(data))
}

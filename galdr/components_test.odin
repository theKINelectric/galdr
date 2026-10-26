package galdr

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
keys :: proc(ta: ^Text_Area, s: string) {
	for r in s do area_on_key(ta, r == '\n' ? Key{code = .Enter} : Key{code = .Char, ch = r})
}

@(test)
test_text_area_editing :: proc(t: ^testing.T) {
	ta: Text_Area
	defer area_destroy(&ta)
	keys(&ta, "hello\nworld")
	testing.expect_value(t, area_text(&ta), "hello\nworld")
	testing.expect_value(t, ta.row, 1)
	area_on_key(&ta, Key{code = .Home})
	area_on_key(&ta, Key{code = .Backspace}) // joins with the previous line
	testing.expect_value(t, area_text(&ta), "helloworld")
	testing.expect_value(t, ta.col, 5)
	area_on_key(&ta, Key{code = .Enter})
	area_insert(&ta, "a\nlonger line\nb")
	testing.expect_value(t, len(ta.lines), 4)
	// Sticky column: moving through a short line keeps the wanted column.
	ta.row, ta.col, ta.want_col = 2, 8, 8
	area_on_key(&ta, Key{code = .Down})
	testing.expect_value(t, ta.col, 6) // "bworld" is shorter: clamped
	area_on_key(&ta, Key{code = .Up})
	testing.expect_value(t, ta.col, 8)
	area_on_key(&ta, Key{code = .Char, ch = 'k', mods = {.Ctrl}})
	testing.expect_value(t, strings.split_lines(area_text(&ta), context.temp_allocator)[2], "longer l")

	th := theme_nightfall()
	f := frame_make(20, 4, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	area_set(&ta, "one\ntwo\nthree\nfour\nfive")
	ta.row = 4
	area_draw(&f, {0, 0, 20, 3}, &ta, true, .Primary, true)
	testing.expect_value(t, row_text(&f, 2), "5 five") // scrolled to keep the cursor visible
}

@(test)
test_tree_navigation_and_guides :: proc(t: ^testing.T) {
	tr: Tree
	defer tree_destroy(&tr)
	root := tree_add(&tr, nil, "root")
	a := tree_add(&tr, root, "a")
	tree_add(&tr, a, "x")
	tree_add(&tr, root, "b")
	root.expanded, a.expanded = true, true
	tree_flatten(&tr)
	th := theme_nightfall()
	f := frame_make(20, 5, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	tree_draw(&f, {0, 0, 20, 5}, &tr, false)
	testing.expect_value(t, row_text(&f, 0), "▌ ▾ root") // the selection bar marks the cursor
	testing.expect_value(t, row_text(&f, 1), "  ├─ ▾ a")
	testing.expect_value(t, row_text(&f, 2), "  │  └─   x")
	testing.expect_value(t, row_text(&f, 3), "  └─   b")

	tr.list.cursor = 1 // "a"
	tree_on_key(&tr, Key{code = .Left}) // collapse
	testing.expect_value(t, len(tr.rows), 3)
	tree_on_key(&tr, Key{code = .Left}) // go to parent
	testing.expect_value(t, tree_selected(&tr).label, "root")
}

@(test)
test_tree_clear_children_invalidates_rows :: proc(t: ^testing.T) {
	// Regression (audit A1): tree_clear_children used to free the descendants
	// but leave Tree.rows caching pointers into them; selection and drawing
	// then read freed memory. Run under AddressSanitizer to catch the old bug.
	tr: Tree
	defer tree_destroy(&tr)
	root := tree_add(&tr, nil, "root", true)
	a := tree_add(&tr, root, "a", true)
	tree_add(&tr, a, "deep")
	tree_add(&tr, root, "b")
	tree_expand(&tr, root, true)
	tree_expand(&tr, a, true)
	testing.expect_value(t, len(tr.rows), 4)

	// A selected descendant is freed by the clear: selection must clamp to a
	// live node, never a stale row.
	tr.list.cursor = 2 // "deep"
	tree_clear_children(&tr, root)
	testing.expect_value(t, len(tr.rows), 1)
	sel := tree_selected(&tr)
	testing.expect(t, sel != nil)
	testing.expect_value(t, sel.label, "root")

	// Drawing and navigation after the clear only touch live rows.
	th := theme_nightfall()
	f := frame_make(20, 3, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	tree_draw(&f, {0, 0, 20, 3}, &tr, true)
	testing.expect_value(t, row_text(&f, 0), "▌ ▾ root")
	tree_on_key(&tr, Key{code = .Down})
	testing.expect_value(t, tree_selected(&tr).label, "root") // clamped: no child to move to

	// An in-place reload through the public API keeps the tree usable.
	a2 := tree_add(&tr, root, "a2", true)
	tree_add(&tr, a2, "x")
	tree_expand(&tr, a2, true)
	testing.expect_value(t, len(tr.rows), 3)
	testing.expect_value(t, tr.rows[2].node.label, "x")
}

@(test)
test_file_picker_lists_directories_first :: proc(t: ^testing.T) {
	dir :: #directory + "/testdata/picker"
	_ = os.make_directory_all(dir + "/zeta_dir")
	_ = os.write_entire_file_from_string(dir + "/alpha.md", "x")
	_ = os.write_entire_file_from_string(dir + "/beta.txt", "x")
	_ = os.write_entire_file_from_string(dir + "/.hidden", "x")
	fp: File_Picker
	defer picker_destroy(&fp)
	fp.extensions = {".md"}
	picker_open(&fp, dir)
	labels := make([dynamic]string, context.temp_allocator)
	for row in fp.tree.rows do append(&labels, row.node.label)
	testing.expect_value(t, strings.join(labels[:], ",", context.temp_allocator), "picker,zeta_dir,alpha.md")
	fp.tree.list.cursor = 2
	_, picked := picker_on_key(&fp, Key{code = .Enter})
	testing.expect(t, picked)
	testing.expect(t, strings.has_suffix(fp.chosen, "picker/alpha.md"), fp.chosen)
}

@(test)
test_filter_draws_clusters_whole :: proc(t: ^testing.T) {
	// filter_draw used to draw runes one by one, splitting grapheme clusters
	// (a ZWJ family became three faces). It must draw them like the editors:
	// one glyph, one width.
	saved := width_mode
	defer width_mode = saved
	width_mode = .Grapheme
	family := "\U0001F468\u200D\U0001F469\u200D\U0001F467"
	items := []string{strings.concatenate({family, " crew"}, context.temp_allocator)}
	fl: Filter
	defer filter_destroy(&fl)
	field_set(&fl.query, "")
	filter_update(&fl, items[:])
	th := theme_nightfall()
	f := frame_make(20, 3, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	filter_draw(&f, {0, 0, 20, 3}, &fl, items[:])
	testing.expect_value(t, f.cells[f.w + 2].width, u8(2)) // row 1, col 2: one 2-cell family glyph
	testing.expect(t, strings.contains(row_text(&f, 1), family), row_text(&f, 1))

	// Match highlighting still lands on the right runes.
	for r in "crew" do field_on_key(&fl.query, Key{code = .Char, ch = r})
	filter_update(&fl, items[:])
	frame_reset(&f)
	filter_draw(&f, {0, 0, 20, 3}, &fl, items[:])
	line := row_text(&f, 1)
	testing.expect(t, strings.contains(line, family), line) // untouched prefix
}

@(test)
test_search_in_lines :: proc(t: ^testing.T) {
	th := theme_nightfall()
	src := "alpha beta\ngamma\nBeta again and beta\ndelta"
	lines := make([dynamic]Line, context.temp_allocator)
	for l in strings.split_lines(src, context.temp_allocator) {
		parts := make([]Span, 2, context.temp_allocator) // a slice literal here would live on the stack
		parts[0], parts[1] = Span{"· ", {}}, Span{l, {fg = th.ink}}
		append(&lines, parts)
	}
	s: Search
	defer search_destroy(&s)
	sv: Scroll_View
	search_on_key(&s, Key{code = .Char, ch = '/'}, &sv, lines[:], 2)
	testing.expect(t, s.typing)
	for r in "beta" do search_on_key(&s, Key{code = .Char, ch = r}, &sv, lines[:], 2)
	testing.expect_value(t, len(s.hits), 3) // case-insensitive, across spans
	search_on_key(&s, Key{code = .Enter}, &sv, lines[:], 2)
	testing.expect(t, !s.typing)
	search_on_key(&s, Key{code = .Char, ch = 'n'}, &sv, lines[:], 2)
	testing.expect_value(t, s.current, 1)
	testing.expect(t, sv.offset > 0, "jumping to a hit scrolls it into view")
	search_on_key(&s, Key{code = .Char, ch = 'N'}, &sv, lines[:], 2)
	testing.expect_value(t, search_status(&s), "1/3")

	f := frame_make(24, 4, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	sv.offset = 0
	search_draw(&f, {0, 0, 24, 4}, &s, &sv, lines[:])
	// "beta" on the first line is the current hit: solid find-yellow behind it,
	// distinct from inline code (Accent).
	testing.expect_value(t, f.cells[8].pen.bg, th.tones[.Warning])
	testing.expect(t, f.cells[1].pen.bg != th.tones[.Warning])
}

@(test)
test_search_recomputes_when_content_changes :: proc(t: ^testing.T) {
	// Regression (audit A7): search_update used to cache on (query, line
	// count) alone, so replacing a line's text kept stale hits. Content
	// changes are the caller's to report, via search_invalidate.
	th := theme_nightfall()
	lines := make([dynamic]Line, context.temp_allocator)
	for l in strings.split_lines("the cat sat\nno animals here", context.temp_allocator) {
		parts := make([]Span, 1, context.temp_allocator)
		parts[0] = Span{l, {fg = th.ink}}
		append(&lines, parts)
	}
	s: Search
	defer search_destroy(&s)
	sv: Scroll_View
	search_on_key(&s, Key{code = .Char, ch = '/'}, &sv, lines[:], 2)
	for r in "cat" do search_on_key(&s, Key{code = .Char, ch = r}, &sv, lines[:], 2)
	search_on_key(&s, Key{code = .Enter}, &sv, lines[:], 2)
	testing.expect_value(t, len(s.hits), 1)

	// Same line count, different text: stale until invalidated…
	news := make([]Span, 1, context.temp_allocator)
	news[0] = Span{"the dog sat", {fg = th.ink}}
	lines[0] = news[:]
	search_update(&s, lines[:])
	testing.expect_value(t, len(s.hits), 1)

	// …then correct, both when matches vanish and when they appear.
	search_invalidate(&s)
	search_update(&s, lines[:])
	testing.expect_value(t, len(s.hits), 0)
	lines[1] = []Span{Span{"a cat and a cat", {fg = th.ink}}}
	search_invalidate(&s)
	search_update(&s, lines[:])
	testing.expect_value(t, len(s.hits), 2)
}

@(test)
test_form_validation :: proc(t: ^testing.T) {
	fields := []Form_Field{
		{label = "Name", kind = .Text, required = true},
		{label = "Email", kind = .Text, validate = proc(v: string) -> string {
			return strings.contains(v, "@") ? "" : "needs an @"
		}},
		{label = "Plan", kind = .Choice, choices = {"free", "pro"}},
		{label = "Terms", kind = .Toggle},
	}
	fm := Form{fields = fields}
	defer form_destroy(&fm)
	testing.expect_value(t, form_on_key(&fm, Key{code = .Char, ch = 's', mods = {.Ctrl}}), Form_Result.None)
	testing.expect_value(t, fm.focus, 0) // jumped to the first invalid field
	testing.expect_value(t, fm.fields[0].err, "required")
	testing.expect_value(t, fm.fields[1].err, "needs an @")

	for r in "Ada" do form_on_key(&fm, Key{code = .Char, ch = r})
	form_on_key(&fm, Key{code = .Tab})
	for r in "ada@x.io" do form_on_key(&fm, Key{code = .Char, ch = r})
	form_on_key(&fm, Key{code = .Tab})
	form_on_key(&fm, Key{code = .Right})
	form_on_key(&fm, Key{code = .Tab})
	form_on_key(&fm, Key{code = .Char, ch = ' '})
	testing.expect_value(t, form_on_key(&fm, Key{code = .Enter}), Form_Result.Submitted)
	testing.expect_value(t, form_value(&fm, 2), "pro")
	testing.expect_value(t, form_value(&fm, 3), "true")

	th := theme_nightfall()
	f := frame_make(40, 12, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	form_draw(&f, {0, 0, 40, 12}, &fm)
	testing.expect(t, strings.contains(row_text(&f, 0), "Name *"))
	testing.expect_value(t, form_on_key(&fm, Key{code = .Escape}), Form_Result.Canceled)
}

@(test)
test_field_marks_hidden_start :: proc(t: ^testing.T) {
	th := theme_nightfall()
	f := frame_make(12, 1, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	tf: Text_Field
	defer field_destroy(&tf)
	field_set(&tf, "a really long sentence")
	field_draw(&f, {0, 0, 12, 1}, &tf, true, .Primary, "› ")
	testing.expect(t, strings.has_prefix(row_text(&f, 0), "› …"), row_text(&f, 0))
}

@(test)
test_editors_keep_clusters_whole :: proc(t: ^testing.T) {
	saved := width_mode
	defer width_mode = saved
	width_mode = .Grapheme // like herdr / Ghostty
	family := "\U0001F468\u200D\U0001F469\u200D\U0001F467"

	tf: Text_Field
	defer field_destroy(&tf)
	field_set(&tf, strings.concatenate({"a", family, "e\u0301b"}, context.temp_allocator))
	field_on_key(&tf, Key{code = .Left}) // before b
	field_on_key(&tf, Key{code = .Left}) // before é: not between e and its accent
	testing.expect_value(t, tf.cursor, 6)
	field_on_key(&tf, Key{code = .Left}) // before the whole family
	testing.expect_value(t, tf.cursor, 1)
	field_on_key(&tf, Key{code = .Delete}) // removes the family in one press
	testing.expect_value(t, field_text(&tf), "ae\u0301b")
	field_on_key(&tf, Key{code = .End})
	field_on_key(&tf, Key{code = .Backspace})
	field_on_key(&tf, Key{code = .Backspace}) // é goes as one unit
	testing.expect_value(t, field_text(&tf), "a")

	th := theme_nightfall()
	f := frame_make(12, 1, &th)
	defer frame_destroy(&f)
	frame_reset(&f)
	field_set(&tf, family)
	field_draw(&f, {0, 0, 12, 1}, &tf, false, .Primary, "")
	testing.expect_value(t, f.cells[0].width, u8(2)) // one 2-cell glyph, joiners intact
	testing.expect_value(t, row_text(&f, 0), family)

	ta: Text_Area
	defer area_destroy(&ta)
	area_set(&ta, strings.concatenate({family, "x"}, context.temp_allocator))
	ta.col = 0
	area_on_key(&ta, Key{code = .Right})
	testing.expect_value(t, ta.col, 5) // past all five codepoints
	area_on_key(&ta, Key{code = .Backspace})
	testing.expect_value(t, area_text(&ta), "x")

	width_mode = .Legacy // wcwidth terminals: each face is its own unit
	field_set(&tf, family)
	field_on_key(&tf, Key{code = .Left})
	testing.expect_value(t, tf.cursor, 4) // before the girl
}

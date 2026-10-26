package galdr_cli

// galdr — glamorous shell prompts and markdown, powered by the galdr package.
//
//   galdr pick [--header H] [--multi] [--height N] [--selected S] items...   (or items on stdin)
//   galdr enter  [--header H] [--placeholder P] [--value V] [--password]
//   galdr refine [--header H] [--placeholder P] [--height N] [--selected S] items...   (or stdin)
//   galdr draft  [--header H] [--placeholder P] [--height N] [--value V]
//   galdr approve [--default yes|no] [--affirmative Yes] [--negative No] "Question?"
//   galdr design  [--tone T] [--border B] [--pad N] [--width N] [--align A] lines...
//   galdr md     [--print] [--width N] FILE
//   galdr themes
//
// Global: --theme nightfall|daybreak|ember|synth|moss
// Exit codes: 0 ok / yes, 1 no, 2 usage error, 130 cancelled.

import gd "galdr:galdr"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Flags :: struct {
	positional: [dynamic]string,
	values:     map[string]string,
	switches:   map[string]bool,
	unknown:    string, // first flag that is neither a switch nor a value flag
	missing:    string, // first value flag with no argument
}

SWITCHES :: []string{"multi", "password", "print", "help"}
VALUE_FLAGS :: []string{
	"affirmative", "align", "border", "color", "default", "header", "height", "negative",
	"pad", "placeholder", "selected", "theme", "title", "tone", "value", "width",
}

parse_flags :: proc(args: []string) -> (f: Flags) {
	i := 0
	for i < len(args) {
		a := args[i]
		if a == "--" {
			for rest in args[i + 1:] do append(&f.positional, rest)
			break
		}
		if strings.has_prefix(a, "--") {
			name := a[2:]
			base := name[:strings.index_byte(name, '=')] if strings.contains_rune(name, '=') else name
			if !is_switch(base) && !is_value_flag(base) {
				if f.unknown == "" do f.unknown = a
				i += 1
				continue
			}
			if eq := strings.index_byte(name, '='); eq >= 0 {
				f.values[name[:eq]] = name[eq + 1:]
			} else if is_switch(name) {
				f.switches[name] = true
			} else if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "--") {
				f.values[name] = args[i + 1]
				i += 1
			} else {
				// A value flag with nothing (or another flag) after it: a
				// usage error, not a silently ignored default.
				if f.missing == "" do f.missing = a
			}
		} else {
			append(&f.positional, a)
		}
		i += 1
	}
	return
}

is_switch :: proc(name: string) -> bool {
	for s in SWITCHES do if s == name do return true
	return false
}

is_value_flag :: proc(name: string) -> bool {
	for s in VALUE_FLAGS do if s == name do return true
	return false
}

// flag_int_checked turns a numeric flag into a usage error: the value must be
// a valid integer within [lo, hi], or the caller reports exit 2.
flag_int_checked :: proc(f: ^Flags, name: string, fallback: int, lo, hi: int) -> (v: int, ok: bool) {
	v = fallback
	if value, present := f.values[name]; present {
		n, parsed := strconv.parse_int(value)
		if !parsed do return n, false
		v = n
	}
	return v, lo <= v && v <= hi
}

pick_theme :: proc(f: ^Flags) -> gd.Theme {
	name := f.values["theme"] or_else os.get_env("GALDR_THEME", context.temp_allocator)
	th, _ := gd.theme_by_name(name)
	return th
}

// out_caps: when printed output goes to a terminal, ask that terminal how it
// measures text first (call before laying anything out), so emoji and CJK
// line up the way it will draw them. Piped output keeps legacy widths.
out_caps: gd.Caps

prepare_output :: proc() {
	out_caps = gd.detect_caps()
	if os.is_tty(os.stdout) {
		_, caps, _ := gd.probe_terminal()
		out_caps = caps
	}
}

// print_frame writes a frame to stdout honoring --color auto|always|never:
// auto uses color only when stdout is a terminal (and NO_COLOR is unset).
print_frame :: proc(f: ^Flags, frame: ^gd.Frame) {
	mode := f.values["color"] or_else "auto"
	if mode == "never" || (mode == "auto" && !os.is_tty(os.stdout)) {
		fmt.println(gd.frame_to_text(frame))
		return
	}
	caps := out_caps
	if mode == "always" && caps.depth == .Mono do caps.depth = .Palette_256
	fmt.print(gd.frame_to_ansi(frame, caps))
}

usage :: proc(help := false) -> ! {
	text := `galdr — glamorous shell prompts, powered by Odin

  galdr pick    [--header H] [--multi] [--height N] [--selected S] items...
  galdr refine  [--header H] [--placeholder P] [--height N] [--selected S] items...
  galdr enter   [--header H] [--placeholder P] [--value V] [--password]
  galdr draft   [--header H] [--placeholder P] [--height N] [--value V]   (ctrl+d saves)
  galdr approve [--default yes|no] [--affirmative L] [--negative L] "Question?"
  galdr design  [--tone T] [--border B] [--pad N] [--width N] [--align A] [--title T] lines...
  galdr md      [--print] [--width N] FILE
  galdr themes

  --theme nightfall|daybreak|ember|synth|moss   (or GALDR_THEME)
  Without a terminal (CI), --selected / --value / --default answer for you.
  With TERM=dumb, prompts fall back to plain numbered questions. NO_COLOR is honoured.
  design/md/themes: --color auto|always|never (auto = only when stdout is a terminal)
  Full reference: docs/CLI.md`
	// Asked for: stdout, success (so `galdr --help | less` works). A usage error: stderr, 2.
	if help {
		fmt.println(text)
		os.exit(0)
	}
	fmt.eprintln(text)
	os.exit(2)
}

main :: proc() {
	if len(os.args) < 2 do usage()
	if os.args[1] == "--help" || os.args[1] == "-h" || os.args[1] == "help" do usage(help = true)
	flags := parse_flags(os.args[2:])
	if flags.switches["help"] do usage(help = true)
	if flags.unknown != "" {
		fmt.eprintfln("galdr: unknown flag %s (see galdr --help)", flags.unknown)
		os.exit(2)
	}
	if flags.missing != "" {
		fmt.eprintfln("galdr: %s needs a value (see galdr --help)", flags.missing)
		os.exit(2)
	}
	code: int
	switch os.args[1] {
	case "pick":    code = cmd_pick(&flags)
	case "enter":   code = cmd_enter(&flags)
	case "refine":  code = cmd_refine(&flags)
	case "draft":   code = cmd_draft(&flags)
	case "approve": code = cmd_approve(&flags)
	case "design":  code = cmd_design(&flags)
	case "md":      code = cmd_md(&flags)
	case "themes":  code = cmd_themes(&flags)
	case:           usage()
	}
	os.exit(code)
}

// ------------------------------------------------------------ pick

Pick_Prompt :: struct {
	header:   string,
	items:    []string,
	picked:   []bool,
	multi:    bool,
	list:     gd.Pick_List,
	done:     bool,
	canceled: bool,
}

pick_app :: gd.App(Pick_Prompt, gd.No_Msg){
	react = proc(s: ^Pick_Prompt, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
		k, is_key := ev.(gd.Key)
		if !is_key do return
		switch {
		case k.code == .Escape, gd.is_ctrl(k, 'c'), gd.is_char(k, 'q'):
			s.canceled = true
			gd.quit(fx)
		case k.code == .Enter:
			s.done = true
			gd.quit(fx)
		case s.multi && (gd.is_char(k, ' ') || gd.is_char(k, 'x')):
			s.picked[s.list.cursor] = !s.picked[s.list.cursor]
		case s.multi && gd.is_char(k, 'a'):
			all := true
			for p in s.picked do all &&= p
			for &p in s.picked do p = !all
		case:
			gd.pick_on_key(&s.list, k, len(s.items), 8)
		}
	},
	paint = proc(s: ^Pick_Prompt, f: ^gd.Frame) {
		th := f.theme
		r := gd.frame_bounds(f)
		if s.header != "" {
			gd.text(f, 1, 0, s.header, {fg = th.tones[.Primary], attrs = {.Bold}})
			gd.cut_top(&r, 1)
		}
		footer := gd.cut_bottom(&r, 1)
		hints := s.multi ? []gd.Key_Hint{{"↑↓", "move"}, {"space", "toggle"}, {"a", "all"}, {"⏎", "confirm"}, {"esc", "cancel"}} : []gd.Key_Hint{{"↑↓", "move"}, {"⏎", "choose"}, {"esc", "cancel"}}
		gd.help_bar(f, 1, footer.y, footer.w - 2, hints)
		gd.pick_draw_custom(f, r, &s.list, len(s.items), proc(f: ^gd.Frame, row: gd.Rect, i: int, sel: bool, user: rawptr) {
			s := (^Pick_Prompt)(user)
			th := f.theme
			x := row.x
			if s.multi {
				x += gd.text(f, x, row.y, s.picked[i] ? "◉ " : "○ ", {fg = s.picked[i] ? th.tones[.Success] : th.faint})
			}
			p := sel ? gd.Pen{fg = th.tones[.Primary], attrs = {.Bold}} : gd.Pen{fg = th.ink}
			gd.text(f, x, row.y, gd.truncate(s.items[i], row.w - (x - row.x)), p)
		}, s, true, .Primary)
		// Plain background for inline prompts: blend into the user's terminal.
		for &c in f.cells do c.pen.bg = c.pen.bg == th.bg ? gd.NO_COLOR : c.pen.bg
	},
}

read_stdin_lines :: proc() -> []string {
	if os.is_tty(os.stdin) do return nil
	data, err := os.read_entire_file_from_file(os.stdin, context.allocator)
	if err != nil do return nil
	lines := make([dynamic]string)
	for l in strings.split_lines(string(data)) {
		if strings.trim_space(l) != "" do append(&lines, l)
	}
	return lines[:]
}

cmd_pick :: proc(f: ^Flags) -> int {
	items := f.positional[:]
	if len(items) == 0 do items = read_stdin_lines()
	if len(items) == 0 {
		fmt.eprintln("galdr pick: no items (pass them as arguments or on stdin)")
		return 2
	}
	s := Pick_Prompt{header = f.values["header"] or_else "", items = items, multi = f.switches["multi"]}
	s.picked = make([]bool, len(items))
	height, hok := flag_int_checked(f, "height", 10, 1, 1000)
	if !hok {
		fmt.eprintfln("galdr pick: --height must be a number between 1 and 1000 (got %q)", f.values["height"])
		return 2
	}
	height = min(height, len(items)) + 1 + (s.header != "" ? 1 : 0)
	if err := gd.run(pick_app, &s, {inline = true, height = height, theme = pick_theme(f)}); err != .None {
		if code, ran := try_plain(err, plain_pick, &s); ran {
			if code != 0 do return code
		} else if sel, ok := f.values["selected"]; ok {
			found := false
			for item, i in items {
				if item == sel {
					s.list.cursor, s.picked[i], s.done, found = i, true, true, true
					break
				}
			}
			if !found {
				fmt.eprintfln("galdr pick: --selected %q is not one of the items", sel)
				return 2
			}
		} else {
			return cannot_prompt(err, "--selected")
		}
	}
	if s.canceled || !s.done do return 130
	if s.multi {
		for item, i in items do if s.picked[i] do fmt.println(item)
	} else {
		fmt.println(items[s.list.cursor])
	}
	return 0
}

// ------------------------------------------------------------ enter

Enter_Prompt :: struct {
	header:   string,
	field:    gd.Text_Field,
	done:     bool,
	canceled: bool,
}

enter_app :: gd.App(Enter_Prompt, gd.No_Msg){
	react = proc(s: ^Enter_Prompt, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
		#partial switch e in ev {
		case gd.Key:
			switch {
			case e.code == .Escape, gd.is_ctrl(e, 'c'):
				s.canceled = true
				gd.quit(fx)
			case e.code == .Enter:
				s.done = true
				gd.quit(fx)
			case:
				gd.field_on_key(&s.field, e)
			}
		case gd.Paste:
			gd.field_insert(&s.field, e.text)
		}
	},
	paint = proc(s: ^Enter_Prompt, f: ^gd.Frame) {
		th := f.theme
		y := 0
		if s.header != "" {
			gd.text(f, 1, 0, s.header, {fg = th.tones[.Primary], attrs = {.Bold}})
			y = 1
		}
		gd.field_draw(f, {1, y, min(f.w - 2, 72), 1}, &s.field, true, .Primary)
		for &c in f.cells do c.pen.bg = c.pen.bg == th.bg ? gd.NO_COLOR : c.pen.bg
	},
}

cmd_enter :: proc(f: ^Flags) -> int {
	s := Enter_Prompt{header = f.values["header"] or_else ""}
	s.field.placeholder = f.values["placeholder"] or_else "type something…"
	if f.switches["password"] do s.field.mask = '•'
	if v, ok := f.values["value"]; ok do gd.field_set(&s.field, v)
	height := s.header != "" ? 2 : 1
	if err := gd.run(enter_app, &s, {inline = true, height = height, theme = pick_theme(f)}); err != .None {
		if code, ran := try_plain(err, plain_enter, &s); ran {
			if code != 0 do return code
		} else if _, ok := f.values["value"]; ok {
			s.done = true // --value already filled the field
		} else {
			return cannot_prompt(err, "--value")
		}
	}
	if s.canceled || !s.done do return 130
	fmt.println(gd.field_text(&s.field))
	return 0
}

// ------------------------------------------------------------ approve

Approve_Prompt :: struct {
	question:  string,
	yes, no:   string,
	choice:    bool,
	done:      bool,
	canceled:  bool,
}

approve_app :: gd.App(Approve_Prompt, gd.No_Msg){
	react = proc(s: ^Approve_Prompt, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
		k, is_key := ev.(gd.Key)
		if !is_key do return
		switch {
		case k.code == .Escape, gd.is_ctrl(k, 'c'), gd.is_char(k, 'q'):
			s.canceled = true
			gd.quit(fx)
		case k.code == .Left, k.code == .Right, k.code == .Tab, gd.is_char(k, 'h'), gd.is_char(k, 'l'):
			s.choice = !s.choice
		case gd.is_char(k, 'y'), gd.is_char(k, 'Y'):
			s.choice, s.done = true, true
			gd.quit(fx)
		case gd.is_char(k, 'n'), gd.is_char(k, 'N'):
			s.choice, s.done = false, true
			gd.quit(fx)
		case k.code == .Enter:
			s.done = true
			gd.quit(fx)
		}
	},
	paint = proc(s: ^Approve_Prompt, f: ^gd.Frame) {
		th := f.theme
		gd.text(f, 1, 0, s.question, {fg = th.ink, attrs = {.Bold}})
		x := 3
		x += gd.button(f, x, 2, s.yes, .Success, .Ghost, s.choice).w + 2
		gd.button(f, x, 2, s.no, .Danger, .Ghost, !s.choice)
		for &c in f.cells do c.pen.bg = c.pen.bg == th.bg ? gd.NO_COLOR : c.pen.bg
	},
}

cmd_approve :: proc(f: ^Flags) -> int {
	q := len(f.positional) > 0 ? strings.join(f.positional[:], " ") : "Are you sure?"
	// The documented enum is yes|no. Anything else is a usage error, never
	// implicit consent: `galdr approve --default "$answer" && deploy` must not
	// proceed because $answer was misspelled.
	if v, ok := f.values["default"]; ok && !strings.equal_fold(v, "yes") && !strings.equal_fold(v, "no") {
		fmt.eprintfln("galdr approve: --default must be yes or no (got %q)", v)
		return 2
	}
	s := Approve_Prompt{
		question = q,
		yes = f.values["affirmative"] or_else "Yes",
		no = f.values["negative"] or_else "No",
		choice = !strings.equal_fold(f.values["default"] or_else "yes", "no"),
	}
	if err := gd.run(approve_app, &s, {inline = true, height = 3, theme = pick_theme(f)}); err != .None {
		if code, ran := try_plain(err, plain_approve, &s); ran {
			if code != 0 do return code
		} else if _, ok := f.values["default"]; ok {
			s.done = true // --default already set the choice
		} else {
			return cannot_prompt(err, "--default")
		}
	}
	if s.canceled || !s.done do return 130
	return s.choice ? 0 : 1
}

// ------------------------------------------------------------ design

cmd_design :: proc(f: ^Flags) -> int {
	prepare_output()
	th := pick_theme(f)
	lines := f.positional[:]
	if len(lines) == 0 do lines = read_stdin_lines()
	tone := gd.Tone.Primary
	if t, ok := f.values["tone"]; ok {
		found := false
		for candidate in gd.Tone {
			if strings.equal_fold(fmt.tprintf("%v", candidate), t) {
				tone, found = candidate, true
			}
		}
		if !found {
			fmt.eprintfln("galdr design: unknown tone %q", t)
			return 2
		}
	}
	border := th.corners
	if b, ok := f.values["border"]; ok {
		parsed, known := gd.border_parse(b)
		if !known {
			fmt.eprintfln("galdr design: unknown border %q", b)
			return 2
		}
		border = parsed
	}
	pad, ok := flag_int_checked(f, "pad", 1, 0, 64)
	if !ok {
		fmt.eprintfln("galdr design: --pad must be a number between 0 and 64 (got %q)", f.values["pad"])
		return 2
	}
	align := gd.Align.Left
	switch f.values["align"] or_else "left" {
	case "center": align = .Center
	case "right":  align = .Right
	case "left":
	case:
		fmt.eprintfln("galdr design: unknown align %q (left, center or right)", f.values["align"])
		return 2
	}
	content_w := 0
	for l in lines do content_w = max(content_w, gd.text_width(l))
	width, wok := flag_int_checked(f, "width", content_w, 1, 4096)
	if !wok {
		fmt.eprintfln("galdr design: --width must be a number between 1 and 4096 (got %q)", f.values["width"])
		return 2
	}
	content_w = width
	edge := border == .None ? 0 : 1
	w := content_w + 2 * (pad + edge)
	h := len(lines) + 2 * edge + (pad > 0 ? 2 * (pad / 2) : 0)

	frame := gd.frame_make(w, h, &th)
	inner := gd.block(&frame, {0, 0, w, h}, {
		border = border, border_pen = {fg = th.tones[tone]},
		title = f.values["title"] or_else "", title_pen = gd.tone_pen(&th, tone, .Solid),
		pad_x = pad, pad_y = pad / 2,
	})
	for l, i in lines {
		if i >= inner.h do break
		gd.text_aligned(&frame, inner.x, inner.y + i, inner.w, l, {fg = th.tones[tone], attrs = {.Bold}}, align)
	}
	print_frame(f, &frame)
	return 0
}

// ------------------------------------------------------------ md

Pager :: struct {
	title:  string,
	source: string,
	doc:    gd.Md_Doc,
	key:    int,
	scroll: gd.Scroll_View,
	body:   gd.Rect,
	theme:  int,
}

pager_app :: gd.App(Pager, gd.No_Msg){
	react = proc(s: ^Pager, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
		#partial switch e in ev {
		case gd.Key:
			switch {
			case gd.is_char(e, 'q'), e.code == .Escape, gd.is_ctrl(e, 'c'):
				gd.quit(fx)
			case gd.is_char(e, 't'):
				s.theme += 1
				gd.set_theme(fx, gd.theme_by_index(s.theme))
				s.key = -1
			case:
				gd.scroll_on_key(&s.scroll, e, len(s.doc.lines), s.body.h)
			}
		case gd.Mouse:
			gd.scroll_on_mouse(&s.scroll, e, len(s.doc.lines), s.body.h)
		}
	},
	paint = proc(s: ^Pager, f: ^gd.Frame) {
		th := f.theme
		r := gd.frame_bounds(f)
		head := gd.cut_top(&r, 1)
		foot := gd.cut_bottom(&r, 1)
		gd.fill(f, head, {bg = th.surface})
		x := gd.text(f, 1, 0, " ▤ ", gd.tone_pen(th, .Primary, .Solid)) + 2
		gd.text(f, x, 0, s.title, {fg = th.ink, attrs = {.Bold}})
		width := min(r.w - 4, 100)
		s.body = {r.x + (r.w - width) / 2, r.y + 1, width + 1, r.h - 1}
		if s.key != width * 100 + s.theme {
			gd.md_destroy(&s.doc)
			s.doc = gd.md_render(s.source, width, th)
			s.key = width * 100 + s.theme
		}
		gd.scroll_draw(f, s.body, &s.scroll, s.doc.lines)
		gd.fill(f, foot, {bg = th.surface})
		gd.help_bar(f, 1, foot.y, foot.w - 12, {{"↑↓ space b", "scroll"}, {"g/G", "top/end"}, {"t", "theme"}, {"q", "quit"}})
		gd.text_aligned(f, 0, foot.y, foot.w - 1, gd.scroll_percent(&s.scroll, len(s.doc.lines), s.body.h), {fg = th.muted}, .Right)
	},
}

cmd_md :: proc(f: ^Flags) -> int {
	if len(f.positional) == 0 {
		fmt.eprintln("galdr md: which file?")
		return 2
	}
	path := f.positional[0]
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("galdr md: cannot read %s: %v", path, err)
		return 2
	}
	th := pick_theme(f)
	if f.switches["print"] || !os.is_tty(os.stdout) {
		prepare_output()
		width, ok := flag_int_checked(f, "width", 80, 1, 4096)
		if !ok {
			fmt.eprintfln("galdr md: --width must be a number between 1 and 4096 (got %q)", f.values["width"])
			return 2
		}
		lines := gd.md_lines(string(data), width, &th)
		frame := gd.frame_make(width, len(lines), &th)
		for l, i in lines do gd.spans(&frame, 0, i, l)
		print_frame(f, &frame)
		return 0
	}
	s := Pager{title = path, source = string(data), key = -1}
	for i in 0 ..< gd.THEME_COUNT {
		if gd.theme_by_index(i).name == th.name do s.theme = i
	}
	if err := gd.run(pager_app, &s, {theme = th, title = path}); err != .None {
		// Can't page: print instead.
		lines := gd.md_lines(s.source, 80, &th)
		frame := gd.frame_make(80, len(lines), &th)
		for l, i in lines do gd.spans(&frame, 0, i, l)
		print_frame(f, &frame)
	}
	return 0
}

// ------------------------------------------------------------ themes

cmd_themes :: proc(f: ^Flags) -> int {
	prepare_output()
	for i in 0 ..< gd.THEME_COUNT {
		th := gd.theme_by_index(i)
		frame := gd.frame_make(64, 3, &th)
		gd.frame_reset(&frame)
		gd.text(&frame, 1, 1, gd.pad_right(th.name, 10), {fg = th.ink, attrs = {.Bold}})
		x := 12
		for t in gd.Tone {
			x += gd.text(&frame, x, 1, "   ", {bg = th.tones[t]}) + 1
		}
		gd.text(&frame, x + 1, 1, th.dark ? "dark" : "light", {fg = th.muted})
		print_frame(f, &frame)
	}
	return 0
}

// ------------------------------------------------------------ refine

Refine_Prompt :: struct {
	header:   string,
	items:    []string,
	fl:       gd.Filter,
	done:     bool,
	canceled: bool,
}

refine_app :: gd.App(Refine_Prompt, gd.No_Msg){
	react = proc(s: ^Refine_Prompt, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
		#partial switch e in ev {
		case gd.Key:
			switch {
			case e.code == .Escape, gd.is_ctrl(e, 'c'):
				s.canceled = true
				gd.quit(fx)
			case e.code == .Enter:
				if _, ok := gd.filter_selected(&s.fl); ok {
					s.done = true
					gd.quit(fx)
				}
			case:
				gd.filter_on_key(&s.fl, e, s.items)
			}
		case gd.Paste:
			gd.field_insert(&s.fl.query, e.text)
			gd.filter_update(&s.fl, s.items)
		}
	},
	paint = proc(s: ^Refine_Prompt, f: ^gd.Frame) {
		th := f.theme
		r := gd.frame_bounds(f)
		if s.header != "" {
			gd.text(f, 1, 0, s.header, {fg = th.tones[.Primary], attrs = {.Bold}})
			gd.cut_top(&r, 1)
		}
		footer := gd.cut_bottom(&r, 1)
		gd.filter_draw(f, gd.inset(r, 1, 0), &s.fl, s.items, true)
		gd.help_bar(f, 1, footer.y, footer.w - 2, {{"type", "to filter"}, {"↑↓", "move"}, {"⏎", "choose"}, {"esc", "cancel"}})
		for &c in f.cells do c.pen.bg = c.pen.bg == th.bg ? gd.NO_COLOR : c.pen.bg
	},
}

cmd_refine :: proc(f: ^Flags) -> int {
	items := f.positional[:]
	if len(items) == 0 do items = read_stdin_lines()
	if len(items) == 0 {
		fmt.eprintln("galdr refine: no items (pass them as arguments or on stdin)")
		return 2
	}
	s := Refine_Prompt{header = f.values["header"] or_else "", items = items}
	s.fl.query.placeholder = f.values["placeholder"] or_else "type to filter…"
	height, hok := flag_int_checked(f, "height", 10, 1, 1000)
	if !hok {
		fmt.eprintfln("galdr refine: --height must be a number between 1 and 1000 (got %q)", f.values["height"])
		return 2
	}
	height = min(height, len(items)) + 2 + (s.header != "" ? 1 : 0)
	if err := gd.run(refine_app, &s, {inline = true, height = height, theme = pick_theme(f)}); err != .None {
		// Without a UI, filtering degrades to choosing.
		c := Pick_Prompt{header = s.header, items = items}
		c.picked = make([]bool, len(items))
		if code, ran := try_plain(err, plain_pick, &c); ran {
			if code != 0 do return code
			fmt.println(items[c.list.cursor])
			return 0
		}
		if sel, ok := f.values["selected"]; ok {
			for item in items do if item == sel {
				fmt.println(item)
				return 0
			}
			fmt.eprintfln("galdr refine: --selected %q is not one of the items", sel)
			return 2
		}
		return cannot_prompt(err, "--selected")
	}
	if s.canceled || !s.done do return 130
	i, _ := gd.filter_selected(&s.fl)
	fmt.println(items[i])
	return 0
}

// ------------------------------------------------------------ draft

Draft_Prompt :: struct {
	header:   string,
	area:     gd.Text_Area,
	done:     bool,
	canceled: bool,
}

draft_app :: gd.App(Draft_Prompt, gd.No_Msg){
	react = proc(s: ^Draft_Prompt, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
		#partial switch e in ev {
		case gd.Key:
			switch {
			case e.code == .Escape, gd.is_ctrl(e, 'c'):
				s.canceled = true
				gd.quit(fx)
			case gd.is_ctrl(e, 'd'):
				s.done = true
				gd.quit(fx)
			case:
				gd.area_on_key(&s.area, e)
			}
		case gd.Paste:
			gd.area_insert(&s.area, e.text)
		}
	},
	paint = proc(s: ^Draft_Prompt, f: ^gd.Frame) {
		th := f.theme
		r := gd.frame_bounds(f)
		if s.header != "" {
			gd.text(f, 1, 0, s.header, {fg = th.tones[.Primary], attrs = {.Bold}})
			gd.cut_top(&r, 1)
		}
		footer := gd.cut_bottom(&r, 1)
		gd.area_draw(f, gd.inset(r, 1, 0), &s.area, true, .Primary, true)
		gd.help_bar(f, 1, footer.y, footer.w - 2, {{"ctrl+d", "save"}, {"esc", "cancel"}, {"⏎", "new line"}})
		for &c in f.cells do c.pen.bg = c.pen.bg == th.bg ? gd.NO_COLOR : c.pen.bg
	},
}

cmd_draft :: proc(f: ^Flags) -> int {
	s := Draft_Prompt{header = f.values["header"] or_else ""}
	s.area.placeholder = f.values["placeholder"] or_else "write something…"
	value, has_value := f.values["value"]
	if has_value do gd.area_set(&s.area, value)
	height, ok := flag_int_checked(f, "height", 8, 1, 1000)
	if !ok {
		fmt.eprintfln("galdr draft: --height must be a number between 1 and 1000 (got %q)", f.values["height"])
		return 2
	}
	height += 1 + (s.header != "" ? 1 : 0)
	if err := gd.run(draft_app, &s, {inline = true, height = height, theme = pick_theme(f)}); err != .None {
		if code, ran := try_plain(err, plain_draft, &s); ran {
			if code != 0 do return code
		} else if has_value {
			s.done = true
		} else {
			return cannot_prompt(err, "--value")
		}
	}
	if s.canceled || !s.done do return 130
	fmt.println(gd.area_text(&s.area))
	return 0
}

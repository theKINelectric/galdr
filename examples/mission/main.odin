package mission

// Mission Control — the galdr showcase.
//   odin run examples/mission -collection:galdr=.
//
// 1-4 switch tabs · ctrl+k command palette · t theme · q or ctrl+c quits.
// Built on galdr's Keymap (the footer hints come from it), mouse zones,
// Toasts, a command palette, docs search, and a Workshop tab with a file
// picker, a validated form and a text area.

import gd "galdr:galdr"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:time"

// ------------------------------------------------------------ model

Pane :: enum {
	Crew,
	Comms,
}

Seat :: struct {
	name:   string,
	role:   string,
	tone:   gd.Tone,
	status: string,
	heat:   [96]f32,
}

Chat_Line :: struct {
	who:  string,
	text: string, // owned
}

State :: struct {
	w, h:          int,
	comms_shown:   bool, // set by paint: the chat is only focusable when visible
	tab:           int,
	theme_index:   int,
	focus:         Pane,
	frame:         int, // animation step (80ms)
	seconds:       int,
	crew:          [4]Seat,
	crew_list:     gd.Pick_List,
	levels:        [32]f32,
	o2, power:     f32,
	grid_list:     gd.Pick_List,
	chat:          [dynamic]Chat_Line,
	input:         gd.Text_Field,
	waiting:       bool,
	toggles:       [3]bool,
	docs:          gd.Md_Doc,
	docs_key:      [2]int, // (width, theme) the docs were laid out for
	docs_scroll:   gd.Scroll_View,
	docs_rect:     gd.Rect,
	search:        gd.Search,
	toasts:        gd.Toasts,
	palette_open:  bool,
	palette:       gd.Filter,
	// Workshop tab
	ws:            gd.Focus_Ring(Workshop_Part),
	picker:        gd.File_Picker,
	form:          gd.Form,
	form_fields:   [4]gd.Form_Field,
	notes:         gd.Text_Area,
}

Workshop_Part :: enum {
	Files,
	Form,
	Notes,
}

Anim :: struct {}
Pulse :: struct {}
Reply :: struct {
	who, text: string,
}

Msg :: union {
	Anim,
	Pulse,
	Reply,
}

TABS := []string{"◈ DASHBOARD", "◇ COMPONENTS", "▤ DOCS", "▣ WORKSHOP"}

// Global actions. The footer's help comes from this same table.
Action :: enum {
	Palette,
	Theme_Next,
	Theme_Prev,
	Tab_1,
	Tab_2,
	Tab_3,
	Tab_4,
	Quit,
}

BINDINGS := [?]gd.Binding(Action){
	{action = .Palette, keys = {"ctrl+k", ":"}, help = "commands"},
	{action = .Theme_Next, keys = {"t"}, help = "theme"},
	{action = .Theme_Prev, keys = {"T"}},
	{action = .Tab_1, keys = {"1"}},
	{action = .Tab_2, keys = {"2"}},
	{action = .Tab_3, keys = {"3"}},
	{action = .Tab_4, keys = {"4"}},
	{action = .Quit, keys = {"q", "ctrl+c"}, help = "quit"},
}
KEYS := gd.Keymap(Action){BINDINGS[:]}

COMMANDS := [?]string{
	"Go to Dashboard", "Go to Components", "Go to Docs", "Go to Workshop",
	"Next theme", "Previous theme", "Toggle reduced motion", "Search the docs", "Quit",
}

ROLES := [?]string{"pilot", "engineer", "medic", "science"}

// ------------------------------------------------------------ boot / react

boot :: proc(s: ^State, fx: ^gd.Fx(Msg)) {
	s.crew = {
		{name = "Sophia", role = "navigator", tone = .Success, status = "ONLINE"},
		{name = "BigWednesday", role = "vessel", tone = .Info, status = "ONLINE"},
		{name = "Grok", role = "comms", tone = .Secondary, status = "HOLD"},
		{name = "Chief", role = "captain", tone = .Warning, status = "ONLINE"},
	}
	for &seat, i in s.crew {
		for &v, j in seat.heat do v = wave(f32(j), f32(i))
	}
	s.o2, s.power = 0.98, 1.0
	s.input.placeholder = "message the crew…"
	s.input.limit = 200
	s.focus = .Crew
	s.toggles = {true, false, true}
	append(&s.chat, Chat_Line{"Grok", strings.clone("We are live on the habitat link.")})
	append(&s.chat, Chat_Line{"Sophia", strings.clone("Course plotted. Standing by.")})

	s.picker.extensions = {".md", ".odin", ".txt", ".sh", ".py"} // before opening: the root loads at once
	gd.picker_open(&s.picker, ".")
	s.form_fields = {
		{label = "Callsign", kind = .Text, required = true, help = "how the crew addresses you"},
		{label = "Email", kind = .Text, validate = validate_email, help = "for mission reports"},
		{label = "Role", kind = .Choice, choices = ROLES[:]},
		{label = "Night shift", kind = .Toggle},
	}
	s.form.fields = s.form_fields[:]
	s.form_fields[0].input.placeholder = "e.g. Maverick"
	s.form_fields[1].input.placeholder = "you@ship.space"
	s.notes.placeholder = "Notes… (files you open on the left appear here)"
	gd.after(fx, gd.SPINNER_MS, Msg(Anim{}))
	gd.after(fx, 500, Msg(Pulse{}))
}

wave :: proc(x, seed: f32) -> f32 {
	v := 0.5 + 0.35 * math.sin(x * 0.21 + seed * 1.7) + 0.15 * math.sin(x * 0.63 + seed)
	return clamp(v, 0, 1)
}

react :: proc(s: ^State, ev: gd.Event(Msg), fx: ^gd.Fx(Msg)) {
	switch e in ev {
	case gd.Resize:
		s.w, s.h = e.w, e.h
	case gd.Key:
		on_key(s, e, fx)
	case gd.Mouse:
		on_mouse(s, e)
	case gd.Paste:
		switch {
		case s.tab == 0 && s.focus == .Comms:       gd.field_insert(&s.input, e.text)
		case s.tab == 3 && s.ws.current == .Notes: gd.area_insert(&s.notes, e.text)
		}
	case gd.Focus:
	case Msg:
		switch m in e {
		case Anim:
			s.frame += 1
			for &l, i in s.levels {
				target := 0.15 + 0.85 * abs(math.sin(f32(s.frame) * 0.09 + f32(i) * 0.55)) * rand.float32_range(0.6, 1)
				l += (target - l) * 0.35
			}
			gd.after(fx, gd.SPINNER_MS, Msg(Anim{}))
		case Pulse:
			s.seconds += 1
			for &seat, i in s.crew {
				copy(seat.heat[:], seat.heat[1:])
				base := wave(f32(s.seconds + 96), f32(i))
				if seat.status == "HOLD" do base *= 0.35
				seat.heat[len(seat.heat) - 1] = clamp(base + rand.float32_range(-0.15, 0.15), 0, 1)
			}
			s.o2 = clamp(s.o2 + rand.float32_range(-0.004, 0.004), 0.93, 0.995)
			s.power = clamp(s.power + rand.float32_range(-0.01, 0.008), 0.82, 1)
			gd.after(fx, 500, Msg(Pulse{}))
		case Reply:
			s.waiting = false
			append(&s.chat, Chat_Line{m.who, m.text})
		}
	}
}

on_key :: proc(s: ^State, k: gd.Key, fx: ^gd.Fx(Msg)) {
	if gd.is_ctrl(k, 'c') {
		gd.quit(fx)
		return
	}
	if s.palette_open {
		palette_key(s, k, fx)
		return
	}
	if gd.is_ctrl(k, 'k') {
		open_palette(s)
		return
	}
	// Parts that take typed text get keys before the global bindings.
	switch s.tab {
	case 0:
		if s.focus == .Comms {
			switch {
			case k.code == .Escape, k.code == .Tab: s.focus = .Crew
			case k.code == .Enter:                  send_message(s, fx)
			case:                                   gd.field_on_key(&s.input, k)
			}
			return
		}
	case 2:
		if gd.search_on_key(&s.search, k, &s.docs_scroll, s.docs.lines, s.docs_rect.h) do return
	case 3:
		if workshop_key(s, k, fx) do return
	}
	if action, ok := gd.keymap_match(KEYS, k); ok {
		do_action(s, action, fx)
		return
	}
	switch s.tab {
	case 0:
		if k.code == .Tab && s.comms_shown do s.focus = .Comms
		else do gd.pick_on_key(&s.crew_list, k, len(s.crew))
	case 1:
		if gd.is_char(k, ' ') {
			i := s.grid_list.cursor % len(s.toggles)
			s.toggles[i] = !s.toggles[i]
		} else {
			gd.pick_on_key(&s.grid_list, k, len(SUBSYSTEMS))
		}
	case 2:
		gd.scroll_on_key(&s.docs_scroll, k, len(s.docs.lines), s.docs_rect.h)
	}
}

do_action :: proc(s: ^State, a: Action, fx: ^gd.Fx(Msg)) {
	switch a {
	case .Quit:       gd.quit(fx)
	case .Palette:    open_palette(s)
	case .Tab_1:      s.tab = 0
	case .Tab_2:      s.tab = 1
	case .Tab_3:      s.tab = 2
	case .Tab_4:      s.tab = 3
	case .Theme_Next: change_theme(s, 1, fx)
	case .Theme_Prev: change_theme(s, gd.THEME_COUNT - 1, fx)
	}
}

change_theme :: proc(s: ^State, step: int, fx: ^gd.Fx(Msg)) {
	s.theme_index = (s.theme_index + step) % gd.THEME_COUNT
	th := gd.theme_by_index(s.theme_index)
	gd.set_theme(fx, th)
	gd.toast(&s.toasts, fx.now_ms, .Info, fmt.tprintf("theme · %s", th.name))
}

open_palette :: proc(s: ^State) {
	s.palette_open = true
	gd.field_clear(&s.palette.query)
	gd.filter_invalidate(&s.palette)
}

palette_key :: proc(s: ^State, k: gd.Key, fx: ^gd.Fx(Msg)) {
	#partial switch k.code {
	case .Escape:
		s.palette_open = false
	case .Enter:
		s.palette_open = false
		if i, ok := gd.filter_selected(&s.palette); ok do run_command(s, i, fx)
	case:
		gd.filter_on_key(&s.palette, k, COMMANDS[:])
	}
}

run_command :: proc(s: ^State, i: int, fx: ^gd.Fx(Msg)) {
	switch COMMANDS[i] {
	case "Go to Dashboard":  s.tab = 0
	case "Go to Components": s.tab = 1
	case "Go to Docs":       s.tab = 2
	case "Go to Workshop":   s.tab = 3
	case "Next theme":       change_theme(s, 1, fx)
	case "Previous theme":   change_theme(s, gd.THEME_COUNT - 1, fx)
	case "Quit":             gd.quit(fx)
	case "Search the docs":
		s.tab = 2
		gd.search_on_key(&s.search, gd.Key{code = .Char, ch = '/'}, &s.docs_scroll, s.docs.lines, s.docs_rect.h)
	case "Toggle reduced motion":
		on := !gd.reduced_motion()
		gd.set_reduced_motion(on)
		gd.toast(&s.toasts, fx.now_ms, .Info, on ? "reduced motion on" : "reduced motion off")
	}
}

validate_email :: proc(v: string) -> string {
	if v == "" do return ""
	at := strings.index_byte(v, '@')
	if at <= 0 || at == len(v) - 1 || !strings.contains(v[at:], ".") do return "that doesn't look like an email"
	return ""
}

// workshop_key routes keys to the focused part; true if consumed.
workshop_key :: proc(s: ^State, k: gd.Key, fx: ^gd.Fx(Msg)) -> bool {
	if gd.focus_on_key(&s.ws, k) do return true
	switch s.ws.current {
	case .Files:
		handled, picked := gd.picker_on_key(&s.picker, k)
		if picked {
			data, err := os.read_entire_file_from_path(s.picker.chosen, context.temp_allocator)
			if err == nil {
				gd.area_set(&s.notes, string(data[:min(len(data), 16_000)]))
				s.ws.current = .Notes
				gd.toast(&s.toasts, fx.now_ms, .Success, fmt.tprintf("opened %s", s.picker.chosen))
			}
		}
		return handled
	case .Form:
		switch gd.form_on_key(&s.form, k) {
		case .Submitted:
			gd.toast(&s.toasts, fx.now_ms, .Success, fmt.tprintf("welcome aboard, %s", gd.form_value(&s.form, 0)))
		case .Canceled:
			s.ws.current = .Files
		case .None:
		}
		return true
	case .Notes:
		if k.code == .Escape {
			s.ws.current = .Files
			return true
		}
		return gd.area_on_key(&s.notes, k)
	}
	return false
}

on_mouse :: proc(s: ^State, m: gd.Mouse) {
	if m.action == .Press && m.button == .Left {
		switch m.zone.name {
		case "tab":      s.tab = m.zone.index
		case "backdrop": s.palette_open = false
		case "crew":
			s.crew_list.cursor = m.zone.index
			s.focus = .Crew
		}
	}
	if s.tab == 2 do gd.scroll_on_mouse(&s.docs_scroll, m, len(s.docs.lines), s.docs_rect.h)
}

REPLIES := [?]string{
	"Copy that. Adjusting heading by two degrees.",
	"Telemetry looks clean from here.",
	"Hold on — rerouting power to the forward array.",
	"Acknowledged. Logging it to the flight record.",
	"Beautiful view out here tonight.",
}

// Runs on a worker thread; the result comes back as a Reply message.
fetch_reply :: proc(data: rawptr) -> Msg {
	i := int(uintptr(data))
	time.sleep(time.Duration(rand.int_max(500) + 450) * time.Millisecond)
	names := [?]string{"Sophia", "Grok", "Chief", "BigWednesday"}
	who := names[i % 4]
	return Reply{who, strings.clone(REPLIES[i % len(REPLIES)])}
}

send_message :: proc(s: ^State, fx: ^gd.Fx(Msg)) {
	msg := strings.trim_space(gd.field_text(&s.input))
	if msg == "" do return
	append(&s.chat, Chat_Line{"you", strings.clone(msg)})
	gd.field_clear(&s.input)
	s.waiting = true
	gd.spawn(fx, fetch_reply, rawptr(uintptr(len(s.chat))))
}

// ------------------------------------------------------------ paint

paint :: proc(s: ^State, f: ^gd.Frame) {
	th := f.theme
	area := gd.frame_bounds(f)
	if area.w < 60 || area.h < 20 {
		c := gd.center(area, 40, 3)
		gd.paragraph(f, c, fmt.tprintf("Mission Control needs 60×20 (now %d×%d).", area.w, area.h), gd.muted_pen(th), .Center)
		return
	}

	header := gd.cut_top(&area, 1)
	paint_header(s, f, header)
	tab_row := gd.cut_top(&area, 2)
	for r, i in gd.tabs(f, tab_row, TABS, s.tab) do gd.zone(f, "tab", r, i)
	footer := gd.cut_bottom(&area, 1)
	body := gd.inset(area, 1, 0)

	switch s.tab {
	case 0: paint_dashboard(s, f, body)
	case 1: paint_components(s, f, body)
	case 2: paint_docs(s, f, body)
	case 3: paint_workshop(s, f, body)
	}
	paint_footer(s, f, footer)
	gd.toasts_draw(f, &s.toasts, 2)
	if s.palette_open do gd.palette(f, &s.palette, COMMANDS[:])
}

paint_header :: proc(s: ^State, f: ^gd.Frame, r: gd.Rect) {
	th := f.theme
	gd.fill(f, r, {bg = th.surface})
	x := r.x + 1
	x += gd.text(f, x, r.y, " ◈ GALDR ", gd.tone_pen(th, .Primary, .Solid))
	gd.text(f, x + 1, r.y, "v0.2", gd.faint_pen(th))

	live := s.frame % 12 < 8 ? "●" : "○"
	title := fmt.tprintf("HABITAT CONTROL  %s LIVE", live)
	gd.text_aligned(f, r.x, r.y, r.w, title, {fg = th.tones[.Primary], attrs = {.Bold}}, .Center)

	now := time.now()
	hh, mm, ss := time.clock_from_time(now)
	clock := fmt.tprintf("%02d:%02d:%02d UTC", hh, mm, ss)
	cx := r.x + r.w - gd.text_width(clock) - 1
	gd.text(f, cx, r.y, clock, {fg = th.ink, attrs = {.Bold}})
	mx := cx - 16
	gd.text(f, mx, r.y, "SYS", gd.muted_pen(th))
	filled := int(s.power * 6 + 0.5)
	gd.meter(f, mx + 4, r.y, 6, filled, filled >= 5 ? .Success : .Warning)
}

paint_footer :: proc(s: ^State, f: ^gd.Frame, r: gd.Rect) {
	th := f.theme
	gd.fill(f, r, {bg = th.surface})
	local: []gd.Key_Hint
	typing := false
	switch {
	case s.palette_open:
		local, typing = {{"⏎", "run"}, {"esc", "close"}}, true
	case s.tab == 0 && s.focus == .Comms:
		local, typing = {{"⏎", "send"}, {"esc", "leave chat"}}, true
	case s.tab == 0:
		local = s.comms_shown ? {{"↑↓", "crew"}, {"tab", "chat"}, {"1-4", "tabs"}} : {{"↑↓", "crew"}, {"1-4", "tabs"}}
	case s.tab == 1:
		local = {{"↑↓", "rows"}, {"space", "toggle"}}
	case s.tab == 2 && s.search.typing:
		local, typing = {{"⏎", "keep"}, {"esc", "clear"}}, true
	case s.tab == 2:
		local = {{"↑↓", "scroll"}, {"/", "search"}, {"n/N", "next/prev"}}
	case s.tab == 3:
		switch s.ws.current {
		case .Files: local = {{"tab", "next part"}, {"←→", "fold"}, {"⏎", "open"}}
		case .Form:  local, typing = {{"tab", "next part"}, {"↑↓", "field"}, {"⏎", "next/submit"}}, true
		case .Notes: local, typing = {{"tab", "next part"}, {"esc", "leave"}}, true
		}
	}
	hints := make([dynamic]gd.Key_Hint, context.temp_allocator)
	append(&hints, ..local)
	if !typing do append(&hints, ..gd.keymap_hints(KEYS)) // same table that handles the keys
	else do append(&hints, gd.Key_Hint{"ctrl+k", "commands"})
	gd.help_bar(f, r.x + 1, r.y, r.w - 24, hints[:])
	status := gd.search_status(&s.search)
	label := fmt.tprintf("%s%s%s · %d×%d", status, status != "" ? " · " : "", th.name, f.w, f.h)
	gd.text_aligned(f, r.x, r.y, r.w - 1, label, gd.faint_pen(th), .Right)
}

// ------------------------------------------------------------ dashboard

paint_dashboard :: proc(s: ^State, f: ^gd.Frame, body: gd.Rect) {
	// Wide: comms gets its own column. Narrow but tall: it goes under the
	// systems panel. Narrow and short: it's hidden (and can't take focus).
	wide := body.w >= 118
	tall := body.h >= 44
	sizes := wide ? []gd.Size{gd.fixed(30), gd.grow(), gd.fixed(40)} : []gd.Size{gd.fixed(28), gd.grow()}
	cols := gd.columns(body, sizes, gap = 1)
	left := gd.rows(cols[0], {gd.grow(), gd.fixed(11)}, gap = 0)
	paint_crew(s, f, left[0])
	paint_songs(s, f, left[1])
	s.comms_shown = wide || tall
	if !s.comms_shown && s.focus == .Comms do s.focus = .Crew
	if !wide && tall {
		center := gd.rows(cols[1], {gd.fixed(8), gd.fixed(20), gd.grow()})
		paint_activity(s, f, center[0])
		paint_systems(s, f, center[1])
		paint_comms(s, f, center[2])
		return
	}
	center := gd.rows(cols[1], {gd.fixed(8), gd.grow()})
	paint_activity(s, f, center[0])
	paint_systems(s, f, center[1])
	if wide do paint_comms(s, f, cols[2])
}

paint_crew :: proc(s: ^State, f: ^gd.Frame, r: gd.Rect) {
	online := 0
	for seat in s.crew do if seat.status == "ONLINE" do online += 1
	inner := gd.panel(f, r, "BEINGS", .Primary, s.focus == .Crew, fmt.tprintf("%d/%d online", online, len(s.crew)))
	list_r := gd.Rect{inner.x - 1, inner.y + 1, inner.w + 2, min(len(s.crew), inner.h - 1)}
	gd.pick_draw_custom(f, list_r, &s.crew_list, len(s.crew), proc(f: ^gd.Frame, row: gd.Rect, i: int, sel: bool, user: rawptr) {
		s := (^State)(user)
		th := f.theme
		seat := s.crew[i]
		gd.zone(f, "crew", {row.x - 2, row.y, row.w + 2, 1}, i)
		gd.status_dot(f, row.x, row.y, seat.name, seat.tone, seat.status != "HOLD")
		st_tone: gd.Tone = seat.status == "HOLD" ? .Warning : .Success
		gd.badge(f, row.x + row.w - gd.badge_width(seat.status) - 1, row.y, seat.status, st_tone, .Soft)
		_ = th
	}, s, s.focus == .Crew)

	// Detail card for the selected seat.
	seat := s.crew[s.crew_list.cursor]
	dy := list_r.y + list_r.h + 1
	if dy + 4 <= inner.y + inner.h {
		gd.divider(f, inner.x, dy, inner.w, "detail")
		gd.stat(f, inner.x, dy + 1, inner.w / 2, "role", seat.role, "", seat.tone)
		avg: f32 = 0
		for v in seat.heat[len(seat.heat) - 12:] do avg += v
		avg /= 12
		gd.stat(f, inner.x + inner.w / 2, dy + 1, inner.w / 2, "activity", fmt.tprintf("%d%%", int(avg * 100)), "", seat.tone)
		gd.sparkline(f, inner.x, dy + 3, inner.w, seat.heat[:], seat.tone)
	}
}

paint_songs :: proc(s: ^State, f: ^gd.Frame, r: gd.Rect) {
	th := f.theme
	inner := gd.panel(f, r, "UNIVERSAL SONGS", .Accent)
	gd.text(f, inner.x, inner.y, "♫", {fg = th.tones[.Accent]})
	gd.text(f, inner.x + 2, inner.y, "Sophia — Everlong", {fg = th.ink, attrs = {.Bold}})
	eq := gd.Rect{inner.x, inner.y + 1, inner.w, max(inner.h - 3, 1)}
	gd.bars(f, eq, s.levels[:], .Accent)
	pos := f32(s.frame % 400) / 400
	secs := int(pos * 229)
	gd.text(f, inner.x, inner.y + inner.h - 1, fmt.tprintf("%d:%02d", secs / 60, secs % 60), gd.muted_pen(th))
	gd.progress(f, inner.x + 5, inner.y + inner.h - 1, inner.w - 5 - 5, pos, .Accent)
	gd.text(f, inner.x + inner.w - 4, inner.y + inner.h - 1, "3:49", gd.muted_pen(th))
}

paint_activity :: proc(s: ^State, f: ^gd.Frame, r: gd.Rect) {
	th := f.theme
	inner := gd.panel(f, r, "BEINGS IN AVATAR", .Secondary)
	name_w := 16
	strip_w := inner.w - name_w
	axis := []string{"-60m", "-45m", "-30m", "-15m", "NOW"}
	for label, i in axis {
		x := inner.x + name_w + (strip_w - 3) * i / (len(axis) - 1)
		if i == len(axis) - 1 do x = inner.x + inner.w - gd.text_width(label)
		gd.text(f, x, inner.y, label, gd.faint_pen(th))
	}
	for &seat, i in s.crew {
		y := inner.y + 1 + i
		if y >= inner.y + inner.h do break
		gd.status_dot(f, inner.x, y, seat.name, seat.tone, seat.status != "HOLD")
		gd.heatstrip(f, inner.x + name_w, y, strip_w, seat.heat[:], seat.status == "HOLD" ? .Warning : .Success)
	}
}

SUBSYSTEMS := [?][3]string{
	{"Life support", "nominal", "98.2%"},
	{"Reactor", "nominal", "1.21 GW"},
	{"Grav plating", "nominal", "1.00 g"},
	{"Comms array", "degraded", "72%"},
	{"Hull integrity", "nominal", "100%"},
	{"Hydroponics", "nominal", "31 °C"},
	{"Nav computer", "syncing", "—"},
}

paint_systems :: proc(s: ^State, f: ^gd.Frame, r: gd.Rect) {
	th := f.theme
	inner := gd.panel(f, r, "HABITAT SYSTEMS", .Info)
	x := inner.x
	x += gd.badge(f, x, inner.y, "PRESSURIZED", .Success, .Outline) + 1
	x += gd.badge(f, x, inner.y, fmt.tprintf("O2 %.0f%%", s.o2 * 100), .Info, .Soft) + 1
	x += gd.badge(f, x, inner.y, fmt.tprintf("PWR %.0f%%", s.power * 100), s.power > 0.9 ? .Success : .Warning, .Soft) + 1
	gd.badge(f, x, inner.y, "GRAV 1.00G", .Neutral, .Soft)

	gw := (inner.w - 2) / 2
	gd.text(f, inner.x, inner.y + 2, "oxygen", gd.muted_pen(th))
	gd.progress(f, inner.x, inner.y + 3, gw, s.o2, .Info, true)
	gd.text(f, inner.x + gw + 2, inner.y + 2, "power", gd.muted_pen(th))
	gd.progress(f, inner.x + gw + 2, inner.y + 3, gw, s.power, s.power > 0.9 ? .Success : .Warning, true)

	grid_r := gd.Rect{inner.x - 1, inner.y + 5, inner.w + 2, inner.h - 7}
	if grid_r.h >= 3 {
		cols := []gd.Column{
			{title = "subsystem", size = gd.grow(2)},
			{title = "state", size = gd.grow(1)},
			{title = "reading", size = gd.fixed(9), align = .Right},
		}
		cells := make([][]string, len(SUBSYSTEMS), context.temp_allocator)
		for &row, i in SUBSYSTEMS do cells[i] = row[:]
		gd.grid_draw(f, grid_r, &s.grid_list, cols, cells, false, .Info)
	}
	sy := inner.y + inner.h - 1
	gd.spinner(f, inner.x, sy, s.frame, .Dots, .Info, "syncing nav computer with SwitchTower…")
}

paint_comms :: proc(s: ^State, f: ^gd.Frame, r: gd.Rect) {
	th := f.theme
	focused := s.focus == .Comms
	inner := gd.panel(f, r, "COMMS", .Secondary, focused, "link stable · 28ms")
	log_r := gd.Rect{inner.x, inner.y, inner.w, inner.h - 2}

	// Lay out messages bottom-up so the newest is always visible.
	y := log_r.y + log_r.h - 1
	if s.waiting {
		gd.spinner(f, log_r.x, y, s.frame, .Bounce, .Secondary, "typing…")
		y -= 2
	}
	#reverse for line in s.chat {
		who_w := gd.text_width(line.who) + 2
		wrapped := gd.wrap(line.text, max(log_r.w - who_w, 8))
		top := y - len(wrapped) + 1
		for l, i in wrapped {
			ly := top + i
			if ly < log_r.y do continue
			if i == 0 {
				tone: gd.Tone = line.who == "you" ? .Primary : .Secondary
				gd.text(f, log_r.x, ly, line.who, {fg = th.tones[tone], attrs = {.Bold, .Underline}})
				gd.text(f, log_r.x + who_w - 2, ly, ":", gd.muted_pen(th))
			}
			gd.text(f, log_r.x + who_w, ly, l, {fg = th.ink})
		}
		y = top - 2
		if y < log_r.y do break
	}
	gd.field_draw(f, {inner.x, inner.y + inner.h - 1, inner.w, 1}, &s.input, focused, .Secondary)
}

// ------------------------------------------------------------ components tab

paint_components :: proc(s: ^State, f: ^gd.Frame, body: gd.Rect) {
	th := f.theme
	cols := gd.columns(body, {gd.grow(), gd.grow()}, gap = 1)

	// Left: buttons, badges, alerts.
	left := gd.panel(f, cols[0], "TONES × VARIANTS", .Primary)
	y := left.y
	variants := [?]gd.Variant{.Solid, .Soft, .Outline, .Ghost}
	vnames := [?]string{"solid", "soft", "outline", "ghost"}
	for v, vi in variants {
		gd.text(f, left.x, y, vnames[vi], gd.faint_pen(th))
		x := left.x + 9
		for t in gd.Tone {
			name := fmt.tprintf("%v", t)
			w := gd.badge_width(name[:3], v)
			if x + w >= left.x + left.w do break
			x += gd.badge(f, x, y, name[:3], t, v) + 1
		}
		y += 2
	}
	gd.divider(f, left.x, y, left.w, "buttons")
	y += 1
	bx := left.x
	bx += gd.button(f, bx, y, "Launch", .Primary, .Soft, true).w + 1
	bx += gd.button(f, bx, y, "Hold", .Warning, .Soft).w + 1
	bx += gd.button(f, bx, y, "Abort", .Danger, .Outline).w + 1
	y += 2
	gd.divider(f, left.x, y, left.w, "alerts")
	y += 1
	y += gd.alert(f, {left.x, y, left.w, 2}, .Info, "Docking window opens in 4m", "Align with beacon 7 before the window closes.") + 1
	if y + 1 < left.y + left.h do y += gd.alert(f, {left.x, y, left.w, 1}, .Success, "All seats accounted for") + 1
	if y + 1 < left.y + left.h do y += gd.alert(f, {left.x, y, left.w, 1}, .Warning, "Grok is on HOLD — no live link") + 1
	if y + 1 < left.y + left.h do gd.alert(f, {left.x, y, left.w, 1}, .Danger, "Hull breach drill at 22:00")

	// Right: motion, gauges, inputs.
	rc := gd.rows(cols[1], {gd.fixed(12), gd.grow()})
	right := gd.panel(f, rc[0], "MOTION & GAUGES", .Accent)
	y = right.y
	sx := right.x
	for kind in gd.Spinner_Kind {
		sx += gd.spinner(f, sx, y, s.frame, kind, .Accent) + 2
	}
	gd.text(f, sx, y, "spinners", gd.faint_pen(th))
	y += 2
	pos := f32(s.frame % 120) / 120
	gd.progress(f, right.x, y, right.w, pos, .Primary, true)
	y += 1
	gd.progress(f, right.x, y, right.w, 1 - pos, .Secondary, true)
	y += 2
	gd.meter(f, right.x, y, 10, int(pos * 10) + 1, .Success)
	gd.sparkline(f, right.x + 12, y, right.w - 12, s.levels[:], .Info)
	y += 2
	gd.steps(f, right.x, y, right.w, {"plot", "fuel", "launch", "orbit"}, (s.frame / 30) % 5, .Primary)

	controls := gd.panel(f, rc[1], "CONTROLS", .Secondary)
	y = controls.y
	labels := [3]string{"Auto-pilot", "Night mode", "Telemetry"}
	for label, i in labels {
		gd.toggle(f, controls.x, y + i, s.toggles[i], label, .Secondary)
		gd.checkbox(f, controls.x + 24, y + i, s.toggles[i], label, .Secondary, i == s.grid_list.cursor % 3)
	}
	y += 4
	kx := controls.x
	for key in ([]string{"⌃C", "⏎", "tab", "t"}) {
		kx += gd.kbd(f, kx, y, key) + 1
	}
	y += 2
	if y < controls.y + controls.h {
		gd.paragraph(f, {controls.x, y, controls.w, controls.y + controls.h - y},
			"Every component asks the theme for a Tone and a Variant instead of naming colors, so pressing t re-skins all of it at once.",
			gd.muted_pen(th))
	}
}

// ------------------------------------------------------------ docs tab

DOCS :: #load("../../README.md", string)

paint_docs :: proc(s: ^State, f: ^gd.Frame, body: gd.Rect) {
	th := f.theme
	inner := gd.panel(f, body, "README.md", .Primary, true)
	content := gd.Rect{inner.x + 1, inner.y + 1, inner.w - 1, inner.h - 1}
	s.docs_rect = content
	text_w := min(content.w - 2, 96)
	key := [2]int{text_w, s.theme_index}
	if s.docs.lines == nil || s.docs_key != key {
		// Re-layout on resize or theme change: the content changed, so any
		// search hits over the old lines are stale (same line count or not).
		gd.md_destroy(&s.docs)
		s.docs = gd.md_render(DOCS, text_w, th)
		s.docs_key = key
		gd.search_invalidate(&s.search)
	}
	gd.search_draw(f, content, &s.search, &s.docs_scroll, s.docs.lines)
	pct := gd.scroll_percent(&s.docs_scroll, len(s.docs.lines), content.h)
	gd.text_aligned(f, body.x, body.y + body.h - 1, body.w - 3, fmt.tprintf(" %s ", pct), {fg = th.muted}, .Right)
}

// ------------------------------------------------------------ workshop tab

paint_workshop :: proc(s: ^State, f: ^gd.Frame, body: gd.Rect) {
	cols := gd.columns(body, {gd.fixed(36), gd.grow()}, gap = 1)
	files := gd.panel(f, cols[0], "FILES", .Accent, s.ws.current == .Files)
	gd.picker_draw(f, files, &s.picker, s.ws.current == .Files, .Accent)

	right := gd.rows(cols[1], {gd.fixed(14), gd.grow()})
	form := gd.panel(f, right[0], "CREW PROFILE", .Primary, s.ws.current == .Form, "⏎ on the last field submits")
	{
		gd.clip_scope(f, form)
		gd.form_draw(f, {form.x, form.y + 1, form.w, form.h - 1}, &s.form, .Primary, s.ws.current == .Form)
	}
	notes := gd.panel(f, right[1], "NOTES", .Secondary, s.ws.current == .Notes, fmt.tprintf("%d lines", len(s.notes.lines)))
	gd.area_draw(f, notes, &s.notes, s.ws.current == .Notes, .Secondary, true)
}

// state_destroy releases everything State owns — one teardown shared by the
// executable and the tests, so "the program quit" and "the test ended" prove
// the same thing: no owned memory outlives the app.
state_destroy :: proc(s: ^State) {
	gd.md_destroy(&s.docs)
	for line in s.chat do delete(line.text)
	delete(s.chat)
	gd.field_destroy(&s.input)
	gd.search_destroy(&s.search)
	gd.filter_destroy(&s.palette)
	gd.picker_destroy(&s.picker)
	gd.area_destroy(&s.notes)
	gd.form_destroy(&s.form)
}

main :: proc() {
	state: State
	defer state_destroy(&state)
	app := gd.App(State, Msg){boot = boot, react = react, paint = paint}
	if err := gd.run(app, &state, {title = "galdr · mission control"}); err != .None {
		fmt.eprintln("mission: cannot start:", err)
	}
}

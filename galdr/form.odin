package galdr

import "core:fmt"

// Forms: labeled fields with validation, built from the existing controls.
// Tab / Shift+Tab (or ↑↓) move between fields, Space toggles, ←→ pick a
// choice, Enter on the last field (or ctrl+s) submits, Esc cancels.

Form_Field_Kind :: enum u8 {
	Text,
	Secret, // a Text field that shows dots
	Toggle,
	Choice,
}

// A validator returns "" when the value is fine, else a short message.
Validator :: #type proc(value: string) -> string

Form_Field :: struct {
	label:    string,
	kind:     Form_Field_Kind,
	input:    Text_Field, // Text / Secret
	on:       bool,       // Toggle
	choices:  []string,   // Choice
	choice:   int,
	required: bool,
	validate: Validator,
	help:     string, // shown under the field when it has focus
	err_buf:  [96]u8,
	err:      string, // current error ("" = valid)
}

Form :: struct {
	fields: []Form_Field,
	focus:  int,
}

Form_Result :: enum u8 {
	None,      // key handled (or ignored); keep going
	Submitted, // every field valid
	Canceled,
}

form_destroy :: proc(fm: ^Form) {
	for &fl in fm.fields do field_destroy(&fl.input)
}

// form_value is a field's value as text (Toggle: "true"/"false").
form_value :: proc(fm: ^Form, i: int) -> string {
	fl := &fm.fields[i]
	switch fl.kind {
	case .Text, .Secret: return field_text(&fl.input)
	case .Toggle:        return fl.on ? "true" : "false"
	case .Choice:        return len(fl.choices) > 0 ? fl.choices[fl.choice] : ""
	}
	return ""
}

// form_validate checks every field; returns the index of the first invalid
// one (or -1 when the form is valid).
form_validate :: proc(fm: ^Form) -> int {
	first := -1
	for &fl, i in fm.fields {
		fl.err = ""
		value := form_value(fm, i)
		msg := ""
		if fl.required && (fl.kind == .Text || fl.kind == .Secret) && len(value) == 0 {
			msg = "required"
		} else if fl.validate != nil {
			msg = fl.validate(value)
		}
		if msg != "" {
			fl.err = fmt.bprint(fl.err_buf[:], msg)
			if first < 0 do first = i
		}
	}
	return first
}

form_on_key :: proc(fm: ^Form, k: Key) -> Form_Result {
	if len(fm.fields) == 0 do return .None
	fl := &fm.fields[fm.focus]
	last := fm.focus == len(fm.fields) - 1
	submit :: proc(fm: ^Form) -> Form_Result {
		bad := form_validate(fm)
		if bad < 0 do return .Submitted
		fm.focus = bad
		return .None
	}
	switch {
	case k.code == .Escape:
		return .Canceled
	case is_ctrl(k, 's'), k.code == .Enter && last:
		return submit(fm)
	case k.code == .Tab && .Shift in k.mods, k.code == .Up:
		fm.focus = (fm.focus + len(fm.fields) - 1) % len(fm.fields)
	case k.code == .Tab, k.code == .Down, k.code == .Enter:
		fm.focus = (fm.focus + 1) % len(fm.fields)
	case:
		switch fl.kind {
		case .Text, .Secret:
			field_on_key(&fl.input, k)
			if fl.err != "" do fl.err = "" // re-validated on submit
		case .Toggle:
			if is_char(k, ' ') || k.code == .Left || k.code == .Right do fl.on = !fl.on
		case .Choice:
			n := len(fl.choices)
			if n > 0 && (k.code == .Right || is_char(k, ' ')) do fl.choice = (fl.choice + 1) % n
			if n > 0 && k.code == .Left do fl.choice = (fl.choice + n - 1) % n
		}
	}
	return .None
}

// form_draw lays fields out as label | control, with errors and help below.
// Returns the rows used.
// active is false when another part of the screen has focus: no field is
// highlighted and no help is shown.
form_draw :: proc(f: ^Frame, r: Rect, fm: ^Form, tone: Tone = .Primary, active := true, label_w := 14) -> int {
	th := f.theme
	y := r.y
	for &fl, i in fm.fields {
		if y >= r.y + r.h do break
		focused := active && i == fm.focus
		lp := Pen{fg = focused ? th.tones[tone] : th.muted, attrs = focused ? {.Bold} : {}}
		mark := fl.required ? " *" : ""
		text(f, r.x, y, truncate(fmt.tprintf("%s%s", fl.label, mark), label_w - 1), lp)
		cx := r.x + label_w
		cw := r.w - label_w
		switch fl.kind {
		case .Text, .Secret:
			fl.input.mask = fl.kind == .Secret ? '•' : 0
			field_draw(f, {cx, y, cw, 1}, &fl.input, focused, fl.err != "" ? .Danger : tone, "")
		case .Toggle:
			toggle(f, cx, y, fl.on, fl.on ? "on" : "off", tone)
		case .Choice:
			x := cx
			for c, ci in fl.choices {
				sel := ci == fl.choice
				p := sel ? tone_pen(th, tone, focused ? .Solid : .Soft) : Pen{fg = th.muted}
				x += text(f, x, y, fmt.tprintf(" %s ", c), p) + 1
			}
		}
		y += 1
		if fl.err != "" && y < r.y + r.h {
			text(f, cx, y, fmt.tprintf("▲ %s", fl.err), {fg = th.tones[.Danger]})
			y += 1
		} else if focused && fl.help != "" && y < r.y + r.h {
			text(f, cx, y, truncate(fl.help, cw), {fg = th.faint, attrs = {.Italic}})
			y += 1
		}
		y += 1
	}
	return y - r.y
}

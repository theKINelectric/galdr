package cookbook

// Recipe: a validated Form.

import gd "galdr:galdr"
import "core:fmt"
import "core:strings"

PLANS := [?]string{"free", "team", "enterprise"}

Signup_State :: struct {
	fields:  [4]gd.Form_Field,
	form:    gd.Form,
	welcome: string, // owned; set on submit
}

check_email :: proc(v: string) -> string {
	if v == "" do return "" // optional: only check what was typed
	at := strings.index_byte(v, '@')
	if at <= 0 || !strings.contains(v[at:], ".") do return "not an email address"
	return ""
}

signup_boot :: proc(s: ^Signup_State, fx: ^gd.Fx(gd.No_Msg)) {
	s.fields = {
		{label = "Name", kind = .Text, required = true},
		{label = "Email", kind = .Text, validate = check_email, help = "for receipts"},
		{label = "Plan", kind = .Choice, choices = PLANS[:]},
		{label = "Newsletter", kind = .Toggle},
	}
	s.form.fields = s.fields[:] // the form edits the fields in place
}

signup_react :: proc(s: ^Signup_State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	#partial switch e in ev {
	case gd.Key:
		switch gd.form_on_key(&s.form, e) {
		case .Submitted:
			delete(s.welcome)
			s.welcome = fmt.aprintf("welcome, %s (%s)", gd.form_value(&s.form, 0), gd.form_value(&s.form, 2))
		case .Canceled:
			gd.quit(fx)
		case .None:
		}
	case gd.Paste:
		fl := &s.form.fields[s.form.focus]
		if fl.kind == .Text do gd.field_insert(&fl.input, e.text)
	}
}

signup_paint :: proc(s: ^Signup_State, f: ^gd.Frame) {
	inner := gd.panel(f, gd.frame_bounds(f), "sign up", .Primary, true, "⏎ next · ctrl+s submit · esc quit")
	used := gd.form_draw(f, inner, &s.form)
	if s.welcome != "" do gd.text(f, inner.x, inner.y + used, s.welcome, {fg = f.theme.tones[.Success]})
}

signup_destroy :: proc(s: ^Signup_State) {
	gd.form_destroy(&s.form)
	delete(s.welcome)
}

SIGNUP_APP :: gd.App(Signup_State, gd.No_Msg){boot = signup_boot, react = signup_react, paint = signup_paint}

signup_run :: proc() -> gd.Run_Error {
	s: Signup_State
	defer signup_destroy(&s)
	return gd.run(SIGNUP_APP, &s)
}

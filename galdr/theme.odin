package galdr

// Semantic theming. Components never name raw colors; they ask for a Tone
// (what it means) and a Variant (how loud it is), and the Theme answers.

Tone :: enum u8 {
	Neutral,
	Primary,
	Secondary,
	Accent,
	Info,
	Success,
	Warning,
	Danger,
}

Variant :: enum u8 {
	Solid,   // filled with the tone, ink-on-tone text
	Soft,    // tinted background, tone-colored text
	Outline, // tone-colored text in brackets/border, no fill
	Ghost,   // tone-colored text only
}

Theme :: struct {
	name:    string,
	bg:      Color, // app background
	surface: Color, // panels
	raised:  Color, // hovered / selected rows, inputs
	line:    Color, // borders and rules
	ink:     Color, // primary text
	muted:   Color, // secondary text
	faint:   Color, // disabled / placeholder
	tones:   [Tone]Color,
	on_tone: [Tone]Color, // text drawn on a Solid tone fill
	corners: Border,      // default panel border
	dark:    bool,
}

// soft_bg is the tinted background used by the Soft variant and selections.
soft_bg :: proc(th: ^Theme, t: Tone, amount: f32 = 0.18) -> Color {
	return mix(th.surface, th.tones[t], amount)
}

// tone_pen resolves a Tone/Variant pair to a Pen.
tone_pen :: proc(th: ^Theme, t: Tone, v: Variant) -> Pen {
	switch v {
	case .Solid:   return {fg = th.on_tone[t], bg = th.tones[t], attrs = {.Bold}}
	case .Soft:    return {fg = th.tones[t], bg = soft_bg(th, t)}
	case .Outline: return {fg = th.tones[t]}
	case .Ghost:   return {fg = th.tones[t]}
	}
	return {fg = th.ink}
}

text_pen :: proc(th: ^Theme) -> Pen  { return {fg = th.ink} }
muted_pen :: proc(th: ^Theme) -> Pen { return {fg = th.muted} }
faint_pen :: proc(th: ^Theme) -> Pen { return {fg = th.faint} }

@(private)
_tones :: proc(neutral, primary, secondary, accent, info, success, warning, danger: string) -> (out: [Tone]Color) {
	out[.Neutral]   = hex(neutral)
	out[.Primary]   = hex(primary)
	out[.Secondary] = hex(secondary)
	out[.Accent]    = hex(accent)
	out[.Info]      = hex(info)
	out[.Success]   = hex(success)
	out[.Warning]   = hex(warning)
	out[.Danger]    = hex(danger)
	return
}

// _on_tones picks, per tone, whichever ink reads better on it (WCAG contrast).
@(private)
_on_tones :: proc(tones: [Tone]Color, dark_ink, light_ink: Color) -> (out: [Tone]Color) {
	for c, t in tones {
		out[t] = contrast_ratio(dark_ink, c) >= contrast_ratio(light_ink, c) ? dark_ink : light_ink
	}
	return
}

// Nightfall: deep navy with cyan/violet signal colors. The house default.
theme_nightfall :: proc() -> Theme {
	th := Theme{
		name = "nightfall", dark = true, corners = .Rounded,
		bg = hex("#0a0f1c"), surface = hex("#0e1526"), raised = hex("#172239"),
		line = hex("#23365a"), ink = hex("#dbe6ff"), muted = hex("#8196bd"), faint = hex("#44557a"),
	}
	th.tones = _tones("#475a80", "#38bdf8", "#a78bfa", "#f5a524", "#22d3ee", "#4ade80", "#facc15", "#fb7185")
	th.on_tone = _on_tones(th.tones, hex("#07101f"), hex("#f4f7ff"))
	return th
}

// Daybreak: a clean light theme.
theme_daybreak :: proc() -> Theme {
	th := Theme{
		name = "daybreak", dark = false, corners = .Rounded,
		bg = hex("#f6f8fb"), surface = hex("#ffffff"), raised = hex("#e8eef6"),
		line = hex("#c9d4e3"), ink = hex("#1b2537"), muted = hex("#5b6b84"), faint = hex("#9aa8bc"),
	}
	th.tones = _tones("#475569", "#2563eb", "#7c3aed", "#db2777", "#0891b2", "#16a34a", "#d97706", "#dc2626")
	th.on_tone = _on_tones(th.tones, hex("#101826"), hex("#ffffff"))
	return th
}

// Ember: warm charcoal with copper highlights.
theme_ember :: proc() -> Theme {
	th := Theme{
		name = "ember", dark = true, corners = .Sharp,
		bg = hex("#15100d"), surface = hex("#1d1612"), raised = hex("#2a1f19"),
		line = hex("#46332a"), ink = hex("#f4e7da"), muted = hex("#b39c88"), faint = hex("#65513f"),
	}
	th.tones = _tones("#6b5647", "#fb923c", "#f43f5e", "#fde047", "#67e8f9", "#a3e635", "#fbbf24", "#ef4444")
	th.on_tone = _on_tones(th.tones, hex("#1a0f08"), hex("#fff7ed"))
	return th
}

// Synthwave: neon on plum.
theme_synth :: proc() -> Theme {
	th := Theme{
		name = "synth", dark = true, corners = .Double,
		bg = hex("#120a1f"), surface = hex("#1a102e"), raised = hex("#281a45"),
		line = hex("#43306e"), ink = hex("#f6ecff"), muted = hex("#a992cf"), faint = hex("#5a4785"),
	}
	th.tones = _tones("#5b4a86", "#ff4fd8", "#7df9ff", "#fff75e", "#60a5fa", "#72f1b8", "#fede5d", "#fe4450")
	th.on_tone = _on_tones(th.tones, hex("#140a22"), hex("#ffffff"))
	return th
}

// Moss: forest greens, calm and legible.
theme_moss :: proc() -> Theme {
	th := Theme{
		name = "moss", dark = true, corners = .Rounded,
		bg = hex("#0c1310"), surface = hex("#111b16"), raised = hex("#1a2a21"),
		line = hex("#2b4336"), ink = hex("#e1efe6"), muted = hex("#8eaa99"), faint = hex("#4b6456"),
	}
	th.tones = _tones("#4d6658", "#34d399", "#a3e635", "#f0abfc", "#38bdf8", "#22c55e", "#eab308", "#f87171")
	th.on_tone = _on_tones(th.tones, hex("#06120c"), hex("#f0fff6"))
	return th
}

THEME_COUNT :: 5

theme_by_index :: proc(i: int) -> Theme {
	switch ((i % THEME_COUNT) + THEME_COUNT) % THEME_COUNT {
	case 0: return theme_nightfall()
	case 1: return theme_daybreak()
	case 2: return theme_ember()
	case 3: return theme_synth()
	case 4: return theme_moss()
	}
	return theme_nightfall()
}

theme_by_name :: proc(name: string) -> (Theme, bool) {
	for i in 0 ..< THEME_COUNT {
		th := theme_by_index(i)
		if th.name == name do return th, true
	}
	return theme_nightfall(), false
}

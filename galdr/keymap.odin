package galdr

import "base:intrinsics"
import "core:strings"
import "core:unicode/utf8"

// Key bindings and focus. A Keymap maps key specs to your own action enum and
// generates the help-bar hints from the same table, so hints can't drift from
// what the keys actually do.

// key_parse reads a spec like "q", "?", "ctrl+c", "alt+enter", "shift+tab",
// "space", "up", "pgdown", "f5". Modifiers: ctrl, alt, shift, super.
key_parse :: proc(spec: string) -> (k: Key, ok: bool) {
	rest := spec
	for {
		switch {
		case strings.has_prefix(rest, "ctrl+"):  k.mods += {.Ctrl};  rest = rest[5:]; continue
		case strings.has_prefix(rest, "alt+"):   k.mods += {.Alt};   rest = rest[4:]; continue
		case strings.has_prefix(rest, "shift+"): k.mods += {.Shift}; rest = rest[6:]; continue
		case strings.has_prefix(rest, "super+"): k.mods += {.Super}; rest = rest[6:]; continue
		}
		break
	}
	if rest == "" do return {}, false
	if r, n := utf8.decode_rune_in_string(rest); n == len(rest) && r != ' ' {
		k.code, k.ch = .Char, r
		if .Shift in k.mods && r >= 'a' && r <= 'z' {
			k.ch = r - 'a' + 'A'
			k.mods -= {.Shift}
		}
		return k, true
	}
	if rest == "space" {
		k.code, k.ch = .Char, ' '
		return k, true
	}
	for name, code in _code_names {
		if name == rest && code != .None && code != .Char {
			k.code = code
			return k, true
		}
	}
	return {}, false
}

// key_matches compares an event with a parsed spec. For characters the
// Shift modifier is already reflected in the rune ('A' vs 'a').
key_matches :: proc(k, spec: Key) -> bool {
	if k.code != spec.code do return false
	if k.code == .Char {
		if k.ch != spec.ch do return false
		return k.mods - {.Shift} == spec.mods - {.Shift}
	}
	return k.mods == spec.mods
}

Binding :: struct($A: typeid) {
	action:   A,
	keys:     []string, // specs; the first one is shown in help
	help:     string,   // "" hides the binding from help
	disabled: bool,
}

Keymap :: struct($A: typeid) {
	bindings: []Binding(A),
}

// keymap_match returns the action bound to k, if any enabled binding matches.
keymap_match :: proc(km: Keymap($A), k: Key) -> (action: A, ok: bool) {
	for b in km.bindings {
		if b.disabled do continue
		for spec in b.keys {
			parsed, valid := key_parse(spec)
			if valid && key_matches(k, parsed) do return b.action, true
		}
	}
	return
}

// keymap_enable turns a binding on or off (it also disappears from help).
keymap_enable :: proc(km: ^Keymap($A), action: A, enabled: bool) {
	for &b in km.bindings do if b.action == action do b.disabled = !enabled
}

// keymap_hints builds help-bar hints from the enabled bindings that have help.
keymap_hints :: proc(km: Keymap($A), allocator := context.temp_allocator) -> []Key_Hint {
	out := make([dynamic]Key_Hint, 0, len(km.bindings), allocator)
	for b in km.bindings {
		if b.disabled || b.help == "" || len(b.keys) == 0 do continue
		append(&out, Key_Hint{key = key_label(b.keys[0]), desc = b.help})
	}
	return out[:]
}

// key_label turns a spec into a compact label for help: "up" → "↑".
key_label :: proc(spec: string) -> string {
	switch spec {
	case "up":        return "↑"
	case "down":      return "↓"
	case "left":      return "←"
	case "right":     return "→"
	case "enter":     return "⏎"
	case "pgup":      return "pgup"
	case "pgdown":    return "pgdn"
	case "shift+tab": return "⇧tab"
	}
	return spec
}

// ------------------------------------------------------------ focus

// Focus_Ring cycles focus through the values of an enum with Tab/Shift+Tab.
Focus_Ring :: struct($E: typeid) where intrinsics.type_is_enum(E) {
	current: E,
	skip:    bit_set[E], // parts that can't take focus right now
}

focus_next :: proc(ring: ^Focus_Ring($E)) {
	_focus_step(ring, 1)
}

focus_prev :: proc(ring: ^Focus_Ring($E)) {
	_focus_step(ring, -1)
}

@(private)
_focus_step :: proc(ring: ^Focus_Ring($E), dir: int) {
	n := len(E)
	values: [len(E)]E
	i := 0
	for v in E {
		values[i] = v
		i += 1
	}
	at := 0
	for v, k in values do if v == ring.current do at = k
	for step in 1 ..= n {
		cand := values[((at + dir * step) % n + n) % n]
		if cand not_in ring.skip {
			ring.current = cand
			return
		}
	}
}

// focus_on_key handles Tab / Shift+Tab. Returns true if it moved focus.
focus_on_key :: proc(ring: ^Focus_Ring($E), k: Key) -> bool {
	if k.code != .Tab do return false
	if .Shift in k.mods do focus_prev(ring)
	else do focus_next(ring)
	return true
}

is_focused :: proc(ring: Focus_Ring($E), part: E) -> bool {
	return ring.current == part
}

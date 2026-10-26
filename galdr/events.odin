package galdr

import "core:unicode/utf8"

// Events and the pure input decoder. The decoder never touches the terminal:
// feed it bytes, get events back. That keeps it trivially testable.

Key_Code :: enum u8 {
	None,
	Char,
	Enter,
	Tab,
	Backspace,
	Escape,
	Up,
	Down,
	Left,
	Right,
	Home,
	End,
	Page_Up,
	Page_Down,
	Insert,
	Delete,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

Mod :: enum u8 {
	Shift,
	Alt,
	Ctrl,
	Super,
}
Mods :: bit_set[Mod; u8]

Key :: struct {
	code: Key_Code,
	ch:   rune, // set when code == .Char
	mods: Mods,
}

Mouse_Button :: enum u8 {
	None,
	Left,
	Middle,
	Right,
	Wheel_Up,
	Wheel_Down,
}

Mouse_Action :: enum u8 {
	Press,
	Release,
	Drag,
	Move,
}

Mouse :: struct {
	x, y:   int,
	button: Mouse_Button,
	action: Mouse_Action,
	mods:   Mods,
	// Filled in by the engine from the last painted frame: the topmost zone
	// under the pointer ("" if none), and the position inside it.
	zone:   Zone,
	local:  [2]int,
}

// in_zone reports whether the mouse event hit zone `name`.
in_zone :: proc(m: Mouse, name: string) -> bool {
	return m.zone.name == name
}

Resize :: struct {
	w, h: int,
}

// Paste text is only valid during the react call that receives it; clone it to keep it.
// truncated is set when the paste exceeded MAX_INPUT_BYTES (or never terminated)
// and the rest was discarded.
Paste :: struct {
	text:      string,
	truncated: bool,
}

Focus :: struct {
	gained: bool,
}

// Input is what the terminal can say. Event(M) adds your own message type.
Input :: union {
	Key,
	Mouse,
	Paste,
	Focus,
}

Event :: union($M: typeid) {
	Key,
	Mouse,
	Resize,
	Paste,
	Focus,
	M,
}

// ------------------------------------------------------------ key helpers

// is_char reports whether k is the plain character c (no ctrl/alt).
is_char :: proc "contextless" (k: Key, c: rune) -> bool {
	return k.code == .Char && k.ch == c && k.mods & {.Ctrl, .Alt} == {}
}

// is_ctrl reports whether k is Ctrl+c (c lower-case letter).
is_ctrl :: proc "contextless" (k: Key, c: rune) -> bool {
	return k.code == .Char && k.ch == c && .Ctrl in k.mods
}

key_name :: proc(k: Key, allocator := context.temp_allocator) -> string {
	prefix := ""
	if .Ctrl in k.mods do prefix = "ctrl+"
	if .Alt in k.mods do prefix = "alt+" if prefix == "" else "ctrl+alt+"
	if k.code == .Char {
		buf, n := utf8.encode_rune(k.ch)
		return _concat(prefix, string(buf[:n]), allocator)
	}
	name := _code_names[k.code]
	return _concat(prefix, name, allocator)
}

@(private)
_code_names := [Key_Code]string{
	.None = "none", .Char = "char", .Enter = "enter", .Tab = "tab", .Backspace = "backspace",
	.Escape = "esc", .Up = "up", .Down = "down", .Left = "left", .Right = "right",
	.Home = "home", .End = "end", .Page_Up = "pgup", .Page_Down = "pgdown",
	.Insert = "insert", .Delete = "delete",
	.F1 = "f1", .F2 = "f2", .F3 = "f3", .F4 = "f4", .F5 = "f5", .F6 = "f6",
	.F7 = "f7", .F8 = "f8", .F9 = "f9", .F10 = "f10", .F11 = "f11", .F12 = "f12",
}

@(private)
_concat :: proc(a, b: string, allocator := context.temp_allocator) -> string {
	out := make([]u8, len(a) + len(b), allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

// ------------------------------------------------------------ decoder

Decode_Status :: enum u8 {
	Ok,        // an Input was produced
	Need_More, // bytes form an incomplete sequence; wait (or flush)
	Skip,      // bytes were consumed but produced nothing (unknown sequence)
}

// decode reads one Input from the front of buf. `flush` forces a decision on
// incomplete data (a lone ESC becomes the Escape key).
decode :: proc(buf: []u8, flush := false) -> (ev: Input, consumed: int, status: Decode_Status) {
	if len(buf) == 0 do return nil, 0, .Need_More
	b := buf[0]

	if b == 0x1b {
		if len(buf) == 1 {
			if flush do return Key{code = .Escape}, 1, .Ok
			return nil, 0, .Need_More
		}
		switch buf[1] {
		case '[':
			return _decode_csi(buf, flush)
		case ']':
			// OSC reply (e.g. background color): skip through its terminator.
			// Two bytes alone could still become one, so wait unless flushing.
			if len(buf) == 2 && !flush do return nil, 0, .Need_More
			if len(buf) > 2 && buf[2] >= '0' && buf[2] <= '9' {
				return _skip_string_sequence(buf, flush)
			}
		case 'P':
			// DCS reply (e.g. XTVERSION: ESC P > | ...).
			if len(buf) == 2 && !flush do return nil, 0, .Need_More
			if len(buf) > 2 && buf[2] == '>' do return _skip_string_sequence(buf, flush)
		case 'O':
			if len(buf) < 3 {
				if flush do return Key{code = .Char, ch = 'O', mods = {.Alt}}, 2, .Ok
				return nil, 0, .Need_More
			}
			code: Key_Code
			switch buf[2] {
			case 'A': code = .Up
			case 'B': code = .Down
			case 'C': code = .Right
			case 'D': code = .Left
			case 'H': code = .Home
			case 'F': code = .End
			case 'P': code = .F1
			case 'Q': code = .F2
			case 'R': code = .F3
			case 'S': code = .F4
			case: return nil, 3, .Skip
			}
			return Key{code = code}, 3, .Ok
		case 0x1b:
			return Key{code = .Escape, mods = {.Alt}}, 2, .Ok
		}
		// Alt + key: decode the following key and add Alt.
		inner, n, st := decode(buf[1:], flush)
		if st == .Ok {
			if k, ok := inner.(Key); ok {
				k.mods += {.Alt}
				return k, n + 1, .Ok
			}
		}
		if st == .Need_More do return nil, 0, .Need_More
		return Key{code = .Escape}, 1, .Ok
	}

	switch b {
	case '\r', '\n': return Key{code = .Enter}, 1, .Ok
	case '\t':       return Key{code = .Tab}, 1, .Ok
	case 0x7f, 0x08: return Key{code = .Backspace}, 1, .Ok
	case 0x00:       return Key{code = .Char, ch = ' ', mods = {.Ctrl}}, 1, .Ok
	case 0x01 ..= 0x1a:
		return Key{code = .Char, ch = rune('a' + b - 1), mods = {.Ctrl}}, 1, .Ok
	case 0x1c ..= 0x1f:
		return Key{code = .Char, ch = rune('4' + b - 0x1c), mods = {.Ctrl}}, 1, .Ok
	}

	if b < 0x80 do return Key{code = .Char, ch = rune(b)}, 1, .Ok

	if !utf8.full_rune(buf) {
		if flush do return nil, len(buf), .Skip
		return nil, 0, .Need_More
	}
	r, size := utf8.decode_rune(buf)
	if r == utf8.RUNE_ERROR && size <= 1 do return nil, 1, .Skip
	return Key{code = .Char, ch = r}, size, .Ok
}

@(private)
PASTE_END :: "\x1b[201~"

@(private)
_decode_csi :: proc(buf: []u8, flush: bool) -> (ev: Input, consumed: int, status: Decode_Status) {
	// ESC [ params... final   (final byte in 0x40..0x7e)
	i := 2
	for i < len(buf) && !(buf[i] >= 0x40 && buf[i] <= 0x7e) do i += 1
	if i >= len(buf) {
		if flush do return Key{code = .Char, ch = '[', mods = {.Alt}}, 2, .Ok
		return nil, 0, .Need_More
	}
	final := buf[i]
	body := buf[2:i]
	n := i + 1

	// SGR mouse: ESC [ < b ; x ; y (M|m)
	if len(body) > 0 && body[0] == '<' && (final == 'M' || final == 'm') {
		p, count := _params(body[1:])
		if count < 3 do return nil, n, .Skip
		return _sgr_mouse(p[0], p[1] - 1, p[2] - 1, final == 'm'), n, .Ok
	}

	// Replies to queries (CSI ? / > / = ...) are never keystrokes.
	if len(body) > 0 && (body[0] == '?' || body[0] == '>' || body[0] == '=') {
		return nil, n, .Skip
	}

	p, count := _params(body)
	mods := Mods{}
	if count >= 2 do mods = _mods_from_param(p[1])

	switch final {
	case 'A': return Key{code = .Up, mods = mods}, n, .Ok
	case 'B': return Key{code = .Down, mods = mods}, n, .Ok
	case 'C': return Key{code = .Right, mods = mods}, n, .Ok
	case 'D': return Key{code = .Left, mods = mods}, n, .Ok
	case 'H': return Key{code = .Home, mods = mods}, n, .Ok
	case 'F': return Key{code = .End, mods = mods}, n, .Ok
	case 'P': return Key{code = .F1, mods = mods}, n, .Ok
	case 'Q': return Key{code = .F2, mods = mods}, n, .Ok
	case 'S': return Key{code = .F4, mods = mods}, n, .Ok
	case 'Z': return Key{code = .Tab, mods = {.Shift}}, n, .Ok
	case 'I': return Focus{gained = true}, n, .Ok
	case 'O': return Focus{gained = false}, n, .Ok
	case 'u':
		// kitty keyboard protocol: ESC [ code ; mods u
		if count < 1 do return nil, n, .Skip
		return _kitty_key(p[0], mods), n, .Ok
	case '~':
		if count < 1 do return nil, n, .Skip
		if p[0] == 200 {
			// bracketed paste: everything up to ESC[201~
			rest := buf[n:]
			end := _index(rest, transmute([]u8)string(PASTE_END))
			if end < 0 {
				if flush do return Paste{text = string(rest), truncated = true}, len(buf), .Ok
				return nil, 0, .Need_More
			}
			return Paste{text = string(rest[:end])}, n + end + len(PASTE_END), .Ok
		}
		code: Key_Code
		switch p[0] {
		case 1, 7:  code = .Home
		case 2:     code = .Insert
		case 3:     code = .Delete
		case 4, 8:  code = .End
		case 5:     code = .Page_Up
		case 6:     code = .Page_Down
		case 11:    code = .F1
		case 12:    code = .F2
		case 13:    code = .F3
		case 14:    code = .F4
		case 15:    code = .F5
		case 17:    code = .F6
		case 18:    code = .F7
		case 19:    code = .F8
		case 20:    code = .F9
		case 21:    code = .F10
		case 23:    code = .F11
		case 24:    code = .F12
		case: return nil, n, .Skip
		}
		return Key{code = code, mods = mods}, n, .Ok
	}
	return nil, n, .Skip
}

@(private)
_params :: proc(body: []u8) -> (out: [8]int, count: int) {
	if len(body) == 0 do return
	cur := 0
	has := false
	in_sub := false // kitty ':' sub-parameters are ignored
	for c in body {
		switch c {
		case '0' ..= '9':
			if in_sub do continue
			cur = cur * 10 + int(c - '0')
			has = true
		case ':':
			in_sub = true
		case ';':
			if count < len(out) do out[count] = has ? cur : 1
			count += 1
			cur, has, in_sub = 0, false, false
		}
	}
	if count < len(out) do out[count] = has ? cur : 1
	count += 1
	return out, min(count, len(out))
}

@(private)
_mods_from_param :: proc(p: int) -> Mods {
	m := Mods{}
	v := max(p - 1, 0)
	if v & 1 != 0 do m += {.Shift}
	if v & 2 != 0 do m += {.Alt}
	if v & 4 != 0 do m += {.Ctrl}
	if v & 8 != 0 do m += {.Super}
	return m
}

@(private)
_kitty_key :: proc(code: int, mods: Mods) -> Key {
	switch code {
	case 13:   return {code = .Enter, mods = mods}
	case 9:    return {code = .Tab, mods = mods}
	case 27:   return {code = .Escape, mods = mods}
	case 127, 8: return {code = .Backspace, mods = mods}
	case 57399 ..= 57425: // keypad digits and operators; map keypad Enter
		if code == 57414 do return {code = .Enter, mods = mods}
	}
	r := rune(code)
	m := mods
	if r >= 'a' && r <= 'z' && .Shift in m {
		r = r - 'a' + 'A'
		m -= {.Shift}
	}
	return {code = .Char, ch = r, mods = m}
}

@(private)
_sgr_mouse :: proc(b, x, y: int, release: bool) -> Mouse {
	m := Mouse{x = x, y = y}
	if b & 4 != 0 do m.mods += {.Shift}
	if b & 8 != 0 do m.mods += {.Alt}
	if b & 16 != 0 do m.mods += {.Ctrl}
	motion := b & 32 != 0
	base := b & 0b11
	if b & 64 != 0 {
		m.button = base == 0 ? .Wheel_Up : .Wheel_Down
		m.action = .Press
		return m
	}
	switch base {
	case 0: m.button = .Left
	case 1: m.button = .Middle
	case 2: m.button = .Right
	case 3: m.button = .None
	}
	switch {
	case motion && m.button == .None: m.action = .Move
	case motion:                      m.action = .Drag
	case release:                     m.action = .Release
	case:                             m.action = .Press
	}
	return m
}

@(private)
_index :: proc(hay, needle: []u8) -> int {
	if len(needle) == 0 do return 0
	outer: for i in 0 ..= len(hay) - len(needle) {
		for j in 0 ..< len(needle) {
			if hay[i + j] != needle[j] do continue outer
		}
		return i
	}
	return -1
}

// _skip_string_sequence consumes an OSC/DCS string up to BEL or ESC \.
@(private)
_skip_string_sequence :: proc(buf: []u8, flush: bool) -> (ev: Input, consumed: int, status: Decode_Status) {
	for i in 2 ..< len(buf) {
		if buf[i] == 0x07 do return nil, i + 1, .Skip
		if buf[i] == 0x1b && i + 1 < len(buf) && buf[i + 1] == '\\' do return nil, i + 2, .Skip
	}
	if flush || len(buf) > 4096 do return nil, len(buf), .Skip
	return nil, 0, .Need_More
}

package galdr

import "core:strconv"
import "core:strings"

// Terminal capability probing. At startup the session sends a burst of
// queries ending with DA1 (which every terminal answers) and parses the
// replies. Parsing is pure and tested; the session does the I/O.

// PROBE_QUERY asks, in order: kitty keyboard flags, synchronized output
// (DECRQM 2026), grapheme clustering (DECRQM 2027), background color
// (OSC 11), terminal name (XTVERSION), and finally DA1 as the sentinel.
@(private)
PROBE_QUERY :: "\x1b[?u\x1b[?2026$p\x1b[?2027$p\x1b]11;?\x1b\\\x1b[>0q\x1b[c"

@(private)
PROBE_TIMEOUT_MS :: 200

// Mode_Support is the DECRQM answer for a private mode.
Mode_Support :: enum u8 {
	Unknown,       // no answer
	Unrecognized,  // 0
	Set,           // 1
	Reset,         // 2 (supported, currently off)
	Always_Set,    // 3
	Always_Reset,  // 4
}

Terminal_Info :: struct {
	answered:       bool, // DA1 arrived: the other fields are trustworthy
	name:           string, // XTVERSION, e.g. "kitty(0.36.1)"; "" if not reported
	kitty_keyboard: bool,
	sync_output:    Mode_Support,
	graphemes:      Mode_Support,
	background:     Color, // NO_COLOR if not reported
}

// terminal describes the terminal of the running session (after run starts).
terminal: Terminal_Info

mode_supported :: proc "contextless" (m: Mode_Support) -> bool {
	return m == .Set || m == .Reset || m == .Always_Set
}

@(private)
Reply_Status :: enum u8 {
	Reply,     // a probe reply was consumed and applied to info
	Not_Reply, // the front of buf is ordinary input
	Need_More, // could be a reply; wait for more bytes
}

// parse_reply consumes one probe reply from the front of buf into info.
@(private)
parse_reply :: proc(buf: []u8, info: ^Terminal_Info) -> (consumed: int, status: Reply_Status) {
	if len(buf) == 0 do return 0, .Need_More
	if buf[0] != 0x1b do return 0, .Not_Reply
	if len(buf) < 2 do return 0, .Need_More
	s := string(buf)
	switch buf[1] {
	case '[':
		// CSI ? ... (u | c | $y)
		if len(buf) < 3 do return 0, .Need_More
		if buf[2] != '?' do return 0, .Not_Reply
		i := 3
		for i < len(buf) && !(buf[i] >= 0x40 && buf[i] <= 0x7e) do i += 1
		if i >= len(buf) do return 0, .Need_More
		body := s[3:i]
		switch buf[i] {
		case 'u':
			info.kitty_keyboard = true
		case 'c':
			info.answered = true
		case 'y':
			// ESC [ ? mode ; value $ y
			body = strings.trim_suffix(body, "$")
			parts := strings.split(body, ";", context.temp_allocator)
			if len(parts) == 2 {
				mode, _ := strconv.parse_int(parts[0])
				val, _ := strconv.parse_int(parts[1])
				support := Mode_Support(clamp(val, 0, 4) + 1)
				switch mode {
				case 2026: info.sync_output = support
				case 2027: info.graphemes = support
				}
			}
		case:
			return 0, .Not_Reply
		}
		return i + 1, .Reply
	case ']':
		// OSC 11 ; rgb:RRRR/GGGG/BBBB (BEL | ESC \)
		end, term_len := _find_st(s[2:])
		if end < 0 do return 0, len(buf) > 256 ? .Not_Reply : .Need_More
		body := s[2:2 + end]
		if strings.has_prefix(body, "11;") do info.background = _parse_xcolor(body[3:])
		return 2 + end + term_len, .Reply
	case 'P':
		// DCS > | name ST   (XTVERSION)
		if len(buf) < 3 do return 0, .Need_More
		if buf[2] != '>' do return 0, .Not_Reply
		end, term_len := _find_st(s[2:])
		if end < 0 do return 0, len(buf) > 256 ? .Not_Reply : .Need_More
		body := s[2:2 + end]
		if strings.has_prefix(body, ">|") do info.name = strings.clone(sanitize(body[2:]))
		return 2 + end + term_len, .Reply
	}
	return 0, .Not_Reply
}

// _find_st finds a string terminator (BEL or ESC \): (index, length) or -1.
@(private)
_find_st :: proc(s: string) -> (int, int) {
	for i in 0 ..< len(s) {
		if s[i] == 0x07 do return i, 1
		if s[i] == 0x1b && i + 1 < len(s) && s[i + 1] == '\\' do return i, 2
	}
	return -1, 0
}

// _parse_xcolor reads "rgb:RRRR/GGGG/BBBB" (1-4 hex digits per channel).
@(private)
_parse_xcolor :: proc(s: string) -> Color {
	if !strings.has_prefix(s, "rgb:") do return NO_COLOR
	parts := strings.split(s[4:], "/", context.temp_allocator)
	if len(parts) != 3 do return NO_COLOR
	out: [3]u8
	for p, i in parts {
		if len(p) == 0 || len(p) > 4 do return NO_COLOR
		v, ok := strconv.parse_uint(p, 16)
		if !ok do return NO_COLOR
		max_v := (u64(1) << uint(4 * len(p))) - 1
		out[i] = u8(u64(v) * 255 / max_v)
	}
	return rgb(out[0], out[1], out[2])
}

// probe_scan pulls every reply out of buf; bytes that are not replies (keys
// typed during the probe) are returned in `rest` for the input reader.
@(private)
probe_scan :: proc(buf: []u8, info: ^Terminal_Info, rest: ^[dynamic]u8) -> (pending: []u8) {
	i := 0
	for i < len(buf) {
		n, st := parse_reply(buf[i:], info)
		switch st {
		case .Reply:
			i += n
		case .Need_More:
			return buf[i:]
		case .Not_Reply:
			append(rest, buf[i])
			i += 1
		}
	}
	return nil
}

// auto_theme picks a built-in theme that suits the terminal's background.
auto_theme :: proc(info: Terminal_Info) -> Theme {
	if info.background.mode == .RGB && relative_luminance(info.background) > 0.4 do return theme_daybreak()
	return theme_nightfall()
}

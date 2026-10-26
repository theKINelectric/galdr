package session_probe

// A session-restore probe for the PTY smoke suite (audit A5): installs custom
// SIGTERM and SIGTSTP handlers, opens and closes a Galdr Session, and verifies
// both dispositions survived. Must run under a real terminal.
// Exit 0 = restored, 1 = broken, 3 = no terminal (skip).

import gd "galdr:galdr"
import "core:fmt"
import "core:os"
import "core:sys/posix"

term_handler :: proc "c" (sig: posix.Signal) {}
tstp_handler :: proc "c" (sig: posix.Signal) {}

installed :: proc(handler: proc "c" (posix.Signal), sig: posix.Signal) -> bool {
	act: posix.sigaction_t
	act.sa_handler = handler
	posix.sigemptyset(&act.sa_mask)
	return posix.sigaction(sig, &act, nil) == .OK
}

still_installed :: proc(handler: proc "c" (posix.Signal), sig: posix.Signal) -> bool {
	cur: posix.sigaction_t
	if posix.sigaction(sig, nil, &cur) != .OK do return false
	return cur.sa_handler == auto_cast handler
}

main :: proc() {
	term_ok := installed(term_handler, .SIGTERM)
	tstp_ok := installed(tstp_handler, .SIGTSTP)

	s: gd.Session
	if err := gd.session_open(&s, {inline = true, no_probe = true}); err != .None {
		fmt.printfln("probe: session_open: %v", err)
		os.exit(err == .No_Terminal || err == .Dumb_Terminal ? 3 : 1)
	}
	gd.session_close(&s, nil)

	term_back := term_ok && still_installed(term_handler, .SIGTERM)
	tstp_back := tstp_ok && still_installed(tstp_handler, .SIGTSTP)
	fmt.printfln("SIGTERM restored: %v", term_back)
	fmt.printfln("SIGTSTP restored: %v", tstp_back)
	os.exit(term_back && tstp_back ? 0 : 1)
}

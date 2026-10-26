# Security

Galdr draws text from applications into a terminal, so the main risk is
**terminal escape injection**: untrusted text that smuggles in control sequences.

What Galdr guarantees, with tests in `galdr/galdr_test.odin` and `galdr/input_reader_test.odin`:
- Text drawn into a `Frame` (`text`, `spans`, markdown) can never emit C0 or C1 control characters, ESC, BEL or OSC. Control runes are dropped when drawn.
- Strings that Galdr embeds inside escape sequences (the window title) pass through `sanitize`.
- The plain line prompts used when `TERM=dumb` (`galdr` CLI) sanitize every untrusted fragment they print (headers, items, questions); the value printed to stdout is unchanged.
- The input reader never holds more than `MAX_INPUT_BYTES` (1 MB) plus a small constant (`INPUT_SLACK`) of undecoded bytes, however input arrives — one feed or many before a drain, pasted or not. Input beyond the bound is dropped; an in-progress paste that passes the cap is cut to 1 MB and delivered flagged `truncated`, its remainder discarded. A complete paste that fits the bound is delivered whole, so its text can reach the bound minus the delimiters — never past it. The bound is about memory: a flood still costs CPU to decode up to that bound.

What applications must do themselves:
- Treat `Paste.text` as untrusted input.
- Never write raw strings to the terminal outside of a `Frame`.

## Reporting
Please report vulnerabilities privately to the maintainer, not in a public issue.
Contact: kin.electric@proton.me. Expect an acknowledgment within a week.

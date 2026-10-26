# Terminal support

Galdr asks the terminal what it supports at startup (`galdr/probe.odin`)
instead of guessing from environment variables. What each answer changes:

| Probe | If supported | If unsupported or no answer |
|---|---|---|
| kitty keyboard (`CSI ? u`) | Push flags=1: unambiguous Esc, Ctrl+I vs Tab, and so on | Legacy keys; nothing is pushed |
| Synchronized output (DECRQM 2026) | Frames wrapped in `?2026h/l`, so there's no tearing | Unrecognized → wrapping omitted. No answer → still wrapped (harmless) |
| Grapheme clustering (DECRQM 2027) | Enabled; widths per grapheme cluster | Legacy per-codepoint `wcwidth` widths |
| Background color (OSC 11) | The default theme follows light or dark | `nightfall` |
| Name (XTVERSION) | Truecolor is assumed for known modern terminals | `COLORTERM` / `TERM` heuristics |

Probing takes at most 200 ms. It ends as soon as the DA1 reply arrives, which
is usually after a few milliseconds. Keys typed during the probe are kept.
`Options.no_probe` skips it.

Environment overrides: `NO_COLOR` gives monochrome. `TERM=dumb` gives no UI (the CLI
falls back to line prompts). `TERM=linux` gives 16 colors.

## Verified automatically (every CI run)

`scripts/smoke.py` runs the real binaries in a pseudo-terminal. It covers:
- a terminal that answers every probe like a modern one
- a terminal that answers nothing
- `NO_COLOR`
- `TERM=dumb`
- suspend and resume under bash

It runs on macOS and Linux.

## Real terminals (community reports)

The maintainers walk the terminals they use day to day. Every other row is
filled in from community reports, so a terminal with no report isn't known to
be broken, just untried. To add one, open an issue or a pull request with:
- the terminal and its version, the OS, the date, and your handle
- ✅ / ⚠️ (note) / ❌ for the steps below
- the `terminal:` line from `GALDR_LOG=galdr.log bin/mission`, which shows what
  the terminal answered at startup

Steps for each terminal:
1. `bin/mission`: keys, mouse clicks on tabs, wheel in docs, resize, `t` theme cycle
2. Chat paste of 12 KB
3. Ctrl-Z, then `fg`
4. `bin/galdr pick` and `approve` inline
5. Emoji and CJK in `galdr design "👨‍👩‍👧 日本 é"` and `galdr design "👱‍♂️日本 é"`

| Terminal | Status | Notes |
|---|---|---|
| Ghostty | no report yet | |
| kitty | no report yet | |
| WezTerm | no report yet | |
| iTerm2 | no report yet | |
| Terminal.app | ✅ 2026-09-24, Chief | Expected: 256 colors unless COLORTERM is set, no kitty keyboard |
| Alacritty | no report yet | |
| foot | no report yet | |
| xterm | no report yet | |
| VS Code terminal | no report yet | |
| tmux 3.4+ | ✅ 2026-09-24, Chief | Needs `set -g allow-passthrough on` for OSC passthrough; tmux answers DA1 itself |
| GNU screen | no report yet | Expected: no 2026/2027, legacy widths |
| over SSH | no report yet | Paste grace period (1 s) covers slow links |
| Linux console | no report yet | Expected: 16 colors, legacy widths |
| herdr 0.9.1 | ✅ 2026-09-24, Chief | libghostty; answers every probe, clusters emoji (2027). One-shot box widths fixed in `90e1491`. In chat, `👱‍♂️` draws as plain 👱 with a wider gap before `é`, but Galdr emits the full sequence (smoke check `chat keeps a ZWJ emoji whole`), so that's herdr's drawing |

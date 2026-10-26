# Galdr

The fun, functional and stateful way to build terminal apps — in **Odin**.

Galdr is one package with no dependencies beyond Odin's `core:` library. It gives you an app runtime, a diffing cell renderer, semantic theming, a component kit, a markdown renderer and a headless test harness. A companion CLI, `galdr`, brings the same pieces to shell scripts.

## Why

Go has a beautiful TUI story. Odin deserves one of its own, one that feels native to the language: plain structs, procedures, explicit allocators, no hidden goroutines, and nothing to learn beyond the handful of ideas below.

## The shape of an app

An app is three procedures over your own `State` struct and your own `Msg` type:

| Procedure | When it runs | What it may do |
|---|---|---|
| `boot` | once, before the first paint | set up state, schedule timers or tasks |
| `react` | for every Event | change state, request effects through `Fx` |
| `paint` | whenever state changed | draw into a `Frame`; nothing else |

```odin
import gd "galdr:galdr"
import "core:fmt"

State :: struct { count: int }

react :: proc(s: ^State, ev: gd.Event(gd.No_Msg), fx: ^gd.Fx(gd.No_Msg)) {
	#partial switch e in ev {
	case gd.Key:
		if gd.is_char(e, '+') do s.count += 1
		if gd.is_char(e, '-') do s.count -= 1
		if gd.is_char(e, 'q') do gd.quit(fx)
	}
}

paint :: proc(s: ^State, f: ^gd.Frame) {
	card := gd.panel(f, gd.center(gd.frame_bounds(f), 30, 5), "counter")
	gd.text(f, card.x, card.y, fmt.tprintf("count = %d", s.count), gd.text_pen(f.theme))
	gd.text(f, card.x, card.y + 2, "+ / - to count, q to quit", gd.muted_pen(f.theme))
}

main :: proc() {
	s: State
	gd.run(gd.App(State, gd.No_Msg){react = react, paint = paint}, &s)
}
```

Run it with `odin run examples/readme -collection:galdr=.`. `No_Msg` is for apps
with no messages of their own, and `boot` is optional.

## Getting started

Odin has no package manager, so add Galdr as a git submodule (or copy it in)
and point a collection at it:

```sh
git submodule add https://github.com/theKINelectric/galdr vendor/galdr
odin run . -collection:galdr=vendor/galdr
```

Then `import gd "galdr:galdr"`. It needs a recent Odin (CI pins
`dev-2026-09`) and runs on macOS, Linux and the BSDs.

## Documentation

| | |
|---|---|
| [Tutorial](docs/TUTORIAL.md) | Build a small task-list app step by step: state, keys, layout, a list, text input, timers, background work, tests |
| [Cookbook](docs/COOKBOOK.md) | Short recipes: keymaps, focus, mouse zones, dialogs, forms, themes, inline mode, markdown, logging |
| [CLI reference](docs/CLI.md) | Every `galdr` command and flag, for shell scripts |
| [API conventions](docs/API.md) | Naming, argument order, memory rules, stability tiers |
| [Terminals](docs/TERMINALS.md) | What Galdr asks the terminal, and which terminals have been tried |

Code in the README, tutorial and cookbook is copied from compiled, tested
example packages, and CI fails if the two drift apart.

## Effects are data

`react` never blocks and never does I/O. It *asks* for effects, and the engine carries them out after `react` returns:

- `after(fx, ms, msg)`: deliver `msg` later. Re-arm it for a clock.
- `send(fx, msg)`: react to `msg` right after this event.
- `spawn(fx, work, data)`: run `work` on a worker thread; its return value comes back as a message.
- `set_theme(fx, theme)` and `quit(fx)`.

Because effects are recorded rather than executed inline, the same app runs headlessly under `Harness`, where timers use virtual time and tasks run synchronously.

## Rendering

- A cell buffer is painted every frame, then **diffed**. Only changed cells reach the terminal.
- Each frame is wrapped in **synchronized output** (DEC mode 2026), so there's no tearing.
- **Truecolor**, with automatic 256-color fallback.
- Wide glyphs (CJK, emoji) occupy two cells correctly.
- **Fullscreen** mode (alternate screen, mouse) or **inline** mode (draws under your prompt, like a picker).
- The terminal is restored on quit, on a failed assertion, and on SIGTERM/SIGHUP.

## Input

The decoder is a pure procedure (bytes in, events out) and covers:

- keys with modifiers, including the **kitty keyboard protocol**
- SGR mouse: press, release, drag and wheel
- bracketed paste
- focus in/out

A lone `Esc` is told apart from an escape sequence with a short timeout.

## Theming

Components never name raw colors. They ask for a **Tone** and a **Variant**:

| Tones | Variants |
|---|---|
| neutral · primary · secondary · accent | solid |
| info · success · warning · danger | soft · outline · ghost |

Five built-in themes: `nightfall`, `daybreak`, `ember`, `synth` and `moss`. Swap one at runtime and every component re-skins at once.

## Components

- **Layout**: `columns`, `rows` with `fixed` / `percent` / `grow`, plus `cut_top` and friends, `inset`, `center`. `clip_scope` keeps drawing inside a rect until the end of the block.
- **Blocks**: borders (rounded, sharp, thick, double, dashed, block, half) with titles, footers, padding and fill.
- **Display**: `panel`, `badge`, `button`, `kbd`, `alert`, `divider`, `stat`, `status_dot`, `tabs`, `steps`, `help_bar`, `toggle`, `checkbox`.
- **Gauges**: `progress` (1/8-cell smooth), `meter`, `sparkline`, `bars`, `heatstrip`, and `spinner` in six styles.
- **Stateful**: `Pick_List`, `Text_Field` (readline keys), `Text_Area` (multi-line), `Scroll_View` with `Search` (`/`, `n`, `N`), `grid_draw` (tables), `Filter` (fuzzy), `Tree`, `File_Picker` (lazy), and `Form` (validated fields).
- **Layers**: `modal`, `popover`, `backdrop`, `shadow`, `Toasts`, and `palette` (a command palette).
- **Input**: `Keymap` maps key specs to your actions and generates the help hints from the same table. `Focus_Ring` handles Tab / Shift-Tab. Mouse zones: `zone(f, "name", rect)` in `paint`, then `m.zone` in `react`.
- **Motion**: `Spring`, `Tween` and easing curves. `GALDR_REDUCED_MOTION=1` turns animation off.
- **Markdown**: `md_render` returns an owning, wrapped, styled `Md_Doc`.

Conventions, memory rules and the stability policy are in `docs/API.md`.

## Diagnostics

Galdr never writes diagnostics to the terminal.
- `GALDR_LOG=path` sends `core:log` output, yours and Galdr's, to a file. That includes what the terminal reported about itself.
- `GALDR_TRACE=1` also logs every event-loop iteration.

## The `galdr` CLI

```sh
flavor=$(galdr pick vanilla chocolate strawberry)
file=$(ls | galdr refine --header "Open which file?")
name=$(galdr enter --placeholder "your name")
msg=$(galdr draft --header "Commit message")   # ctrl+d saves
galdr approve "Deploy to production?" && ./deploy.sh
galdr design --tone primary --border rounded --pad 1 "Hello, $name"
galdr md README.md        # pager
galdr md --print notes.md # render to stdout
```

Without a terminal (CI, cron), `--selected`, `--value` and `--default` answer for you. On `TERM=dumb`, prompts fall back to plain questions.

## Build

```sh
./build.sh   # tests, then bin/hello, bin/mission, bin/galdr
./ci.sh      # the full CI gate: strict checks, tests, ASan, builds, pty smoke tests
```

Galdr runs on macOS, Linux and the BSDs. It is tested on macOS arm64 and on
Linux under CI. It honours `NO_COLOR`, falls back gracefully on `TERM=dumb`,
and suspends to the shell on Ctrl-Z.

License: zlib. See `LICENSE`, `CHANGELOG.md`, `CONTRIBUTING.md` and `SECURITY.md`.

## Roadmap

- [x] Phase 0: release blockers
- [x] Phase 1: Unicode 16 graphemes, terminal probing, renderer efficiency, correctness suites
- [x] Phase 2: API review, keymaps, focus, zones, layers, filter, text area, tree, forms, motion, diagnostics
- [ ] Phase 3: Windows backend, `galdr spin` / `table`, syntax highlighting, images

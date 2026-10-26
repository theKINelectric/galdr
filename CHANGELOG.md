# Changelog

All notable changes are listed here. Galdr follows [semver](https://semver.org).
While the version is 0.x, minor releases may change the API. Each change is
called out under **Breaking**.

## 0.2.0 — 2026-09-27

The corrective release from the 2026-09-26 Astra audit, hardened by the
2026-09-27 re-review of the corrective commits. A 0.x **minor**, not a patch:
`tree_clear_children` changed shape (below), and API.md holds patch releases
to API-frozen. Each fix ships with a regression test; the re-review verified them as
genuine detectors by restoring 0.1.0 semantics in scratch copies for A1, A2,
A6, A7, A8, A9 and the filter fix — the A3/A5 terminal assertions were
verified by inspection — except the wake-pipe failure path, which is covered
by source review only.

### Breaking
- `tree_clear_children` now takes the owning `Tree`: `tree_clear_children(&t, node)` instead of `tree_clear_children(node)`. The old form left `Tree.rows` caching pointers into freed nodes; pass the tree and the cache is rebuilt and the selection clamped for you.
- `spawn` gained an optional fourth parameter `cancel: proc(data: rawptr) = nil` — existing calls compile unchanged.
- `Search` gained `search_invalidate` (call it when the lines' content changes at the same line count, mirroring `filter_invalidate`).

### Fixed
- **Trees:** freeing a subtree through `tree_clear_children` no longer leaves dangling visible rows; selection, drawing and navigation after a clear stay on live nodes (heap-use-after-free under ASan, audit A1). `tree_add` under an expanded parent now makes the new row visible immediately.
- **Input cap:** the 1 MB `MAX_INPUT_BYTES` cap is now enforced while bytes are buffered, not only while they are decoded — a complete oversized paste, one giant feed, or many feeds before a drain are all capped, delivered truncated, and their remainder discarded (audit A2). The buffer bound holds for garbage floods too. `SECURITY.md` now states the enforced semantics.
- **Plain prompts:** the `TERM=dumb` line prompts sanitize headers, items and questions; ESC/OSC/BEL/C1 bytes from untrusted text no longer reach the terminal. The selected value printed to stdout keeps its exact bytes (audit A3).
- **CLI validation:** `approve --default` must be `yes` or `no`; anything else is a usage error (exit 2), never implicit consent. Missing flag values (`galdr design hello --width`), malformed numbers (`--width oops`) and out-of-range values are usage errors; `design --align` validates its choices (audit A4).
- **Signals:** a session saves the host's signal dispositions and restores them on close — SIGTERM, SIGHUP, SIGQUIT, SIGWINCH and SIGTSTP, exactly as they were (custom handler, `SIG_IGN`, or default). Embedding Galdr no longer leaves our fatal-signal handler installed after the UI closes. `session_open` also fails closed (instead of keeping `-1` descriptors) when the wake pipe cannot be created (audit A5).
- **Timer fairness:** a handler that rearms itself with `after(fx, 0, …)` no longer monopolizes the engine — timers scheduled during a dispatch run on the next turn, input and paint always get a chance, and both `engine_fire_timers` and `harness_advance` are bounded per call (audit A6).
- **Search staleness:** search hits recompute after `search_invalidate` when content changed at the same line count; Mission invalidates on docs relayout (audit A7).
- **Mission teardown:** one `state_destroy` shared by the executable and tests frees everything `State` owns (the file picker was leaked before), and the soak test now *fails* on any byte of owned memory surviving teardown instead of printing a warning (audit A8).
- **Task ownership:** the shutdown contract is explicit (audit A9): queued tasks never run — their optional `cancel` callback disposes of the data; results the app will never react to go to `App.drop` / `Engine.on_result_drop` instead of leaking. Documented in the tutorial and API conventions.
- **Filter drawing** walks graphemes like the editors: a ZWJ family or `e` + accent draws as one glyph, not split faces.

### Fixed after the 2026-09-27 re-review
- The first input-cap rewrite had four boundary defects of its own, all now regression-tested: a paste opener near the end of a just-over-cap buffer sliced out of range (crash); a terminator split across small feeds never reassembled; the cap-crossing feed lost its own partial terminator; an exactly-1 MiB complete paste sharing a feed with one more key was truncated instead of decoded. A pending capped paste also let later feeds append without bound — the reader now holds at most `MAX_INPUT_BYTES + INPUT_SLACK` bytes in every state, dropping overflow.
- `harness_advance` bounded *all* turns, silently skipping real schedules (a 10-minute advance of an 80 ms clock fired 4,096 of its 7,500 ticks) and then claiming the whole span elapsed. Only zero-progress turns are bounded now, and a stopped storm leaves the clock where it stopped. Its "750 turns" comment was off by ten.
- The worker-side result disposer ran while holding the hub mutex; a disposer calling `engine_task_stats` (legal per the contract) deadlocked. All disposal callbacks now run off the lock. New tests cover the deadlock (fails cleanly against the old code), `App.drop` wiring, and quit-mid-drain disposal.
- `_install_handler` now checks `sigaction`'s result instead of always reporting success; the wake-pipe failure path no longer opens a log file it would leak; the session probe verifies SIGTSTP restoration as well as SIGTERM.
- `ci.sh` builds `bin/session_probe` itself: a clean checkout no longer needs `build.sh` first for the smoke suite to pass.

### Added
- `App.drop` — declare result disposal next to `react`; wired through `run`, `Engine` and `Harness`. Disposal may run on a worker thread.
- `scripts/session_probe` — a PTY-driven probe asserting the session restores signal dispositions; run by the smoke suite.

## 0.1.0 — 2026-09-24

The first release. Everything below is new relative to the unversioned
prototype.

### Added
- **Runtime:** `boot / react / paint` with an `Fx` effect queue (`after`, `send`, `spawn`, `set_theme`, `quit`), `Fx.now_ms`, and a headless `Harness` (virtual time, synchronous tasks, `harness_click`).
- **Renderer:**
  - Cell diffing, SGR deltas and cheap cursor moves.
  - Hardware scrolling via scroll margins.
  - Synchronized output.
  - Truecolor, 256-color, 16-color and monochrome.
- **Unicode 16:**
  - Generated width tables.
  - UAX #29 grapheme clusters in cells; all 1,093 official conformance cases pass.
  - Legacy or cluster width modes, chosen by probing the terminal.
- **Terminal probing:** kitty keyboard, DECRQM 2026/2027, OSC 11 background and XTVERSION. Late replies are never turned into keys.
- **Input:**
  - Kitty keyboard, SGR mouse, bracketed paste and focus.
  - `Input_Reader` with a 1 MB cap; an oversized paste is flagged `truncated`.
  - Mouse zones (`zone`, `Mouse.zone`).
  - `Keymap` with generated help hints, and `Focus_Ring`.
- **Theming:** Tone × Variant over five themes, all WCAG AA (label ink chosen by contrast). `contrast_ratio` is public.
- **Components:**
  - Layout, blocks and `clip_scope`.
  - Widgets.
  - Stateful: `Pick_List`, `Text_Field`, `Text_Area`, `Scroll_View` with `Search`, `grid_draw`, `Filter` (fuzzy), `Tree`, `File_Picker` and `Form`.
  - Layers: `modal`, `popover`, `Toasts` and `palette`.
  - Motion: `Spring`, `Tween`, and a reduced-motion switch.
  - Markdown via `Md_Doc`.
- **Lifecycle:**
  - Ctrl-Z suspends to the shell, and `fg` resumes with a full redraw.
  - `NO_COLOR`, `TERM=dumb` and no-terminal fallbacks.
  - `Run_Error`.
  - `GALDR_LOG` / `GALDR_TRACE` diagnostics that go to a file.
- **CLI:** `pick`, `refine`, `enter`, `draft`, `approve`, `design`, `md` and `themes`. Plain and no-terminal fallbacks, and `--color auto|always|never`.
- **Quality:**
  - `ci.sh`: strict vet, tests, ASan and smoke tests.
  - Linux CI (Forgejo).
  - Decoder fuzzing, a VT-emulator round-trip for the renderer, golden snapshots, a 10-minute soak test and byte budgets.
- **Docs:**
  - `docs/TUTORIAL.md`: build a task-list app step by step (`examples/tutorial`).
  - `docs/COOKBOOK.md`: 14 recipes (`examples/cookbook`).
  - `docs/CLI.md`: every `galdr` verb, flag, key and exit code.
  - Code in the README, tutorial and cookbook is copied from compiled, tested packages. `scripts/check_docs.py` fails CI when they drift.
- **Legal:** zlib license. `VERSION` constant.

### Fixed
- `galdr --help` printed to stderr and exited 2. It now prints to stdout and exits 0. An unknown flag is an error (exit 2) instead of silently taking the next argument as its value.
- The `TERM=dumb` pick prompt read `Pick_Prompt [1-N]:`. It now reads `Pick [1-N]:`.
- `galdr design` and the other one-shot commands measured emoji the old way even in terminals that cluster them (found in herdr).
- Pastes over 8 KB lost data. Also, a read boundary right after `ESC ]` / `ESC P` turned the rest of the reply into keystrokes.
- `Text_Field` insert and scroll were quadratic.
- Spawned tasks leaked threads and ran without the crash handler. Quitting no longer waits for tasks.
- Window titles could inject escape sequences. Control characters can never be stored in a cell or attached to a cluster.
- The combining accent in `e + ◌́` was dropped.
- `width_mode` raced between threads; it is now thread-local.

### Breaking (relative to the unversioned prototype)
- **Renamed Runic → Galdr.**
  - The package and directory are now `galdr`, imported as `import gd "galdr:galdr"` with `-collection:galdr=<path>`.
  - The CLI binary is `galdr`.
  - The environment variables are `GALDR_LOG`, `GALDR_TRACE`, `GALDR_REDUCED_MOTION` and `GALDR_THEME`.
- **CLI verbs recomposed:**

  | Before | After |
  |---|---|
  | `choose` | `pick` |
  | `input` | `enter` |
  | `confirm` | `approve` |
  | `filter` | `refine` |
  | `write` | `draft` |
  | `style` | `design` |
- `run` returns `Run_Error` instead of `bool`.
- `md_render` returns an owning `Md_Doc`. The borrowing form is `md_lines`.
- Renamed for consistency:
  - `field` → `field_draw`
  - `pick_list` / `pick_list_custom` → `pick_draw` / `pick_draw_custom`
  - `scroll_lines` → `scroll_draw`
  - `search_lines` → `search_draw`
  - `grid` → `grid_draw`, which now takes the list state before the columns.
- `search_on_key` takes the key second.
- Removed `luminance` (use `relative_luminance`), `bold`, `tone_color` and `THEME_DEFAULT`.
- The compile-time `GALDR_TRACE` define is replaced by the `GALDR_TRACE` environment variable.

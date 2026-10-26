# Galdr: road to a releasable 1.0

Written 2026-09-24, at commit `4558eac` (v0 prototype: 3.6k lines of library, 18 tests).

> **Status (same day):** Phases 0–2 are implemented and green on macOS and Linux.
> The name is settled (Galdr). The Chief walked Terminal.app, tmux and herdr; the
> rest of the terminal matrix comes from community reports. CI is
> green.

Galdr works today. The demos run and the tests pass. "Production grade" means
something narrower and harder: it behaves correctly in terminals and inputs we
didn't try, it never loses a user's data or leaves their terminal broken, and
its API is stable enough that other people can build on it.

The plan has four phases. Phase 0 is the list of release blockers. A public
`v0.1.0` can ship after it, once the Chief gives the go.

Sizes: **S** is under a day, **M** a few days, **L** a week or more.

---

## Phase 0 · Release blockers (→ v0.1.0)

| # | Item | Why it blocks | Size |
|---|---|---|---|
| 0.1 | **Pastes longer than 8 KB lose data.** A 12,000-char paste arrives as 3,814 chars. The input buffer is a fixed `[8192]u8`, and the overflow guard discards the start. Fix: a growable input buffer with a hard cap (e.g. 1 MB) and a truncation flag on `Paste`. | Silent data loss | S |
| 0.2 | **Sanitize terminal-bound strings.** `Options.title` goes into OSC 2 verbatim, so BEL or ESC in a title can inject escape sequences. Strip C0/C1 controls from anything we emit. Add a test proving `text()` can never emit ESC. | Security | S |
| 0.3 | **Worker threads.** `spawn` starts one OS thread per task and joins only at exit, so handles pile up in long sessions. Worker threads also don't inherit the crash-restore assertion handler. Move to a bounded `core:thread` pool, reap finished tasks, and pass our context. | Resource leak; broken terminal after a crash | M |
| 0.4 | **Markdown ownership.** `md_render` allocates into the caller's allocator with no destroy path, so re-rendering on resize leaks. Return an owning `Md_Doc` backed by an arena, plus `md_destroy`. | Memory leak | S |
| 0.5 | **Graceful degradation.** Honour `NO_COLOR`. Handle `TERM=dumb`, and prompts with no `/dev/tty` (CI, pipes), by falling back to plain line prompts, not failing. Add 16-color and monochrome depths. | Real-world environments | M |
| 0.6 | **Suspend and resume.** Ctrl-Z currently arrives as a key because ISIG is off. Restore the terminal, raise SIGTSTP, and on SIGCONT re-enter raw mode and fully redraw. | Expected shell behavior | S |
| 0.7 | **LICENSE.** Nothing can be shared without one. Pick zlib, BSD-3 or MIT. Most Odin libraries use zlib or BSD-3. | Legal | S |
| 0.8 | **Name check.** Search "Galdr" on GitHub, Codeberg, Homebrew and crates-style registries for collisions before going public. | Avoid a rename later | S |
| 0.9 | **CI.** Forgejo/Codeberg Actions (or GitHub Actions) on macOS arm64 and Linux x86_64/arm64, with the Odin version pinned plus latest. Run `odin check -vet -strict-style -warnings-as-errors`, all tests, all builds, and the pty smoke tests (`scripts/pty_drive.py`). | Keeps main green | M |
| 0.10 | **CHANGELOG, CONTRIBUTING, SECURITY.md, and a `VERSION` constant** in the package. | Release hygiene | S |

**Exit criteria:** every item closed. CI green on both platforms. Pty smoke tests
pass under tmux. The four PROVENANCE gates re-checked. The Chief's go.

---

## Phase 1 · Hardening (→ v0.2 to v0.4)

**Unicode, done properly**
- Grapheme clusters (UAX #29): ZWJ emoji, flags, skin tones, and combining marks. Today `e + ◌́` loses its accent, because width-0 runes are dropped instead of attached to the previous cell. A Cell needs to hold a short grapheme string, not one rune. **L**
- Generate the width tables from Unicode 16 data (UAX #11 plus emoji presentation) with a script. Don't maintain hand-written ranges. Use terminal mode 2027 where it's supported. **M**

**Know the terminal instead of guessing**
- At startup, query with a short timeout, then pick features from the answers rather than from `$TERM_PROGRAM` guesses:
  - DA1 and XTVERSION
  - kitty keyboard support (`CSI ? u`)
  - DECRQM for synchronized output (2026)
  - OSC 11 for the background color, to choose a light or dark theme automatically **M**
- tmux and screen: passthrough where needed, and a documented feature matrix. **M**

**Renderer efficiency**
- SGR deltas instead of a full reset on every pen change. Cheaper cursor moves (CUF, or reprinting unchanged cells when that's shorter). Scroll regions for log and pager views. **M**
- Benchmarks: bytes per frame and microseconds per frame for the mission dashboard, idle and animating. Treat regressions as test failures. **S**

**Prove correctness**
- **Decoder fuzzing:** random byte streams must never crash, must always make progress, and must never return `Need_More` forever. **S**
- **Round-trip conformance:** feed `render_diff` output into a VT emulator model and check the screen matches the Frame, across random frame pairs. This is the strongest guarantee a renderer can offer. **M**
- **Golden snapshots**, both plain text and styled, for every component in every theme, with an `-define:GALDR_UPDATE_GOLDEN=true` flow. **M**
- **Theme contrast test:** every `on_tone` over `tone`, and `ink`/`muted` over `surface`, must meet WCAG AA. **S**
- **Soak test:** the mission app with a tracking allocator for 10 minutes of virtual time, requiring zero growth. **S**

**Terminal matrix (maintainers' own terminals, then community reports)**
- Ghostty, kitty, WezTerm, iTerm2, Terminal.app, Alacritty, foot, xterm and VS Code
- tmux, screen, and SSH
- Linux console

---

## Phase 2 · API 1.0 candidate

- **API review and freeze.** Make everything consistent:
  - `Rect` first vs `x, y, w` in widget signatures
  - verb naming (`text` / `put` / `spans`)
  - an error enum instead of `run` returning `bool`
  - `@(private)` on everything that isn't meant to be public
  
  Write the deprecation policy. **M**
- **Focus and key bindings.** A focus ring across components. A small `Keymap` type that also generates help-bar hints, so hints can't drift from the real bindings. **M**
- **Mouse zones.** `paint` registers named hit rects in the Frame, and `react` asks which zone was hit. This replaces hand-stored rects in state. **S**
- **Layers.** Modal dialogs, popovers, toasts and command palettes composited above the base layer. **M**
- **Components still missing:**
  - `Text_Area` (multi-line)
  - fuzzy `Filter` list
  - file picker and tree
  - viewport with search
  - forms, with validation, built from existing fields **L**
- **Motion.** A spring/easing helper driven by `after`, plus a reduced-motion switch (`GALDR_REDUCED_MOTION`). **S**
- **Diagnostics.** `GALDR_LOG=path` for a structured debug log. The existing `GALDR_TRACE` becomes a runtime flag. **S**

---

## API polish found while writing the docs (→ 0.2)

Writing the cookbook against the real API turned up these. None blocks 0.1.0.

- **Generic procs can't infer enum values.** `keymap_enable(&km, .Save, …)` and `is_focused(ring, .Search)` need the type spelled out (`Key_Action.Save`). Rework the signatures so implicit selectors work. **S**
- **`Focus_Ring.skip` leaves focus on a hidden part.** Skipping the focused part should move focus to the next visible one. **S**
- **`Form_Field.err` points into the field's own buffer.** Copying a field that has an error leaves a dangling string. Store an index or re-point it after a copy, as `Toasts` already does. **S**
- **`keymap_enable` changes the shared binding table.** A global `Keymap` becomes global mutable state. Keep the enabled flags in the `Keymap` itself. **S**
- **No `harness_resize`.** Tests must send `Resize` and also call `frame_resize`. Add one call that does both. **S**
- **Toasts expire only on a repaint.** Arm the redraw timer inside `toast` instead of relying on every caller to do it. **S**
- **Custom themes set `on_tone` by hand.** Make the contrast-based helper public (`theme_finish` or similar). **S**
- **Theme index drift.** When `Options.theme` is unset, `run` picks a theme from the terminal background, so an app that tracks a theme index can start out wrong. Expose which theme was chosen. **S**
- **CLI flag parsing:** switches don't accept `--multi=true`, a number that doesn't parse silently falls back to its default, and an unknown `--theme` or `--align` is silently replaced. Make these errors. **S**
- **`md` reads files only:** no stdin, and the no-pager fallback ignores `--width`. **S**

## Phase 3 · Reach

- **Windows backend:** console VT mode, `ReadConsoleInputW`, resize events. **L**
- **Full CLI parity:** `spin -- cmd`, `filter`, `table`, `file`, `write`, `pager`, `log` and `format`, plus shell completions. **L**
- **Markdown extras:** syntax highlighting for fenced code (Odin, Go, Rust, JS, Python, shell, JSON), and OSC 8 hyperlinks for links. **M**
- **Images:** the kitty graphics protocol and sixel, with a text fallback. **L**
- A **windowed backend** (SDL or karl2d) rendering the same Frames. The earlier TermCL study wanted this, and it's where cell buffers pay off. **L**

---

## Releasing

**How people get it.** Odin has no package manager. Users vendor the library or
add it as a git submodule, then pass `-collection:galdr=...`. Releases are signed
semver tags. Keep `main` releasable. Stay on 0.x until Phase 2 is done.

**The `galdr` binary:**
- builds for macOS universal2 and Linux x86_64/arm64
- `.tar.gz` archives with SHA-256 checksums, signed with minisign or cosign
- the macOS binary is signed and notarized
- a Homebrew tap

**Docs:**
- `odin doc` API reference
- ~~a tutorial ("your first app in 10 minutes")~~ `docs/TUTORIAL.md` (0.1.0)
- ~~a cookbook~~ `docs/COOKBOOK.md`, and a CLI reference `docs/CLI.md` (0.1.0)
- a component gallery with screenshots or GIFs, recorded from the pty driver via asciinema and agg

**Per-release checklist:**
1. CI green
2. Terminal matrix: maintainers' terminals re-walked, new community reports merged
3. CHANGELOG updated
4. Provenance re-checked
5. Version bumped
6. Tag signed
7. Artifacts and checksums published
8. Announcement: Odin Discord, the showcase forum, and r/odinlang


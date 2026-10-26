# Provenance

This file answers the four publish gates set on 2026-07-28.

## Gate 1 · Clean extraction

Galdr is a fresh package, not a carve-out. It has no studio concepts: no crew
table, receipts, seals, Bind ceremony or telemetry. Its only dependencies are
Odin's `core:` and `base:` packages.

## Gate 2 · Lineage

| Source | Relationship |
|---|---|
| Charm's Bubble Tea, Lip Gloss, Bubbles, Gum, Glow (Go, MIT) | **Inspiration** for the product category: an Elm-style runtime, declarative styling, components, shell prompts, a markdown pager. No code was copied or translated. |
| daisyUI (CSS, MIT) | **Inspiration** for semantic color roles and component variants. No code or palette values were copied. |
| TermCL (Odin, BSD-3) | **Not used.** The earlier engine vendored it. Galdr's terminal layer is written from scratch on `core:sys/posix`. |
| `_BubbleTeaPP__TermCL` (house, July 2026) | **Superseded.** Only its lessons carried over (bounded effect queues, a pure core, restoring the terminal). |
| Terminal protocols (ECMA-48, xterm, DEC 2026, kitty keyboard, SGR mouse) | Public specifications, implemented from their documentation. |

## Gate 3 · The Melody pass

The aim was to compose awake: keep the good ideas, but give them our own
shape. These are the deliberate differences:

| Common pattern | Galdr's composition |
|---|---|
| `Init / Update / View` returning `(Model, Cmd)` | `boot / react / paint` over a **mutable** `^State`. Effects are requests recorded on an `Fx` queue, not returned closures. |
| `Cmd` as a function returning a message | `after`, `send`, `spawn` and `set_theme` are plain data. `spawn` takes `proc(rawptr) -> Msg` and runs on a real thread. |
| `tea.Msg` as `interface{}` | A typed union, `Event(M)`, closed over the app's own `Msg` type. |
| View returns a string | `paint` draws into a cell `Frame`. The runtime diffs frames and emits minimal bytes. |
| Style objects rendered to strings | A `Block` describes border, fill, title and padding, then draws straight into the Frame and returns the content rect. |
| Hard-coded or adaptive colors | Every component resolves a `Tone × Variant` through the active `Theme`. |
| `list.Model`, `textinput.Model` | `Pick_List`, `Text_Field` and `Scroll_View`: small structs with `*_on_key` procs and immediate-mode draw procs. |
| teatest golden files | `Harness`: virtual time, synchronous tasks, text snapshots, direct state inspection. |
| Names | Galdr's own vocabulary throughout: `Fx`, `Frame`, `Pen`, `Tone`, `Variant`, `Block`, `Pick_List`, `Text_Field`. |
| Gum's command set (`choose`, `input`, `confirm`, `filter`, `write`, `style`) | Recomposed by the Chief's ruling of 2026-09-24: `galdr pick`, `enter`, `approve`, `refine`, `draft`, `design`. |

## Gate 4 · Docs, examples, API stability

- `README.md` documents the model, effects, rendering, theming and components.
- There are two runnable examples, `examples/hello` and `examples/mission`, plus the `galdr` CLI.
- `./ci.sh` runs 92 test procedures (plus 1,093 Unicode conformance cases), an AddressSanitizer pass, and 61 end-to-end pty smoke checks, and builds every binary the smoke suite runs. 0.2.0 is the corrective release from the 2026-09-26 Astra audit and its 2026-09-27 re-review rounds; see `CHANGELOG.md`.
- API stability: **not declared yet.** Hold at 0.x until the procedure names have had real use.

## Custody

The flag stays planted. Per the July ruling, publishing is a separate outward
act that needs the Chief's explicit go.

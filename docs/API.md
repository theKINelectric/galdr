# API conventions and stability

This is the contract that the 1.0 freeze will hold Galdr to. In 0.x it
describes current practice and what we intend to keep.

## Naming

| Kind | Pattern | Examples |
|---|---|---|
| Types | `Ada_Case` | `Frame`, `Pick_List`, `Text_Area` |
| Procedures, variables | `snake_case` | `text_width`, `frame_reset` |
| Constants | `SCREAMING_CASE` | `MAX_INPUT_BYTES`, `SPINNER_MS` |
| Stateless widgets | a noun: draw immediately, keep no state | `panel`, `badge`, `progress`, `tabs`, `alert` |
| Stateful components | `<prefix>_on_key`, `<prefix>_draw`, `<prefix>_destroy` | `field_*`, `pick_*`, `area_*`, `filter_*`, `tree_*`, `search_*`, `form_*` |
| Effects | verbs on `^Fx` | `after`, `send`, `spawn`, `set_theme`, `quit` |

## Argument order

- Drawing: `(f: ^Frame, where, state?, data..., focused?, tone?, options...)`.
  - Point widgets take `x, y`.
  - Line widgets take `x, y, w`.
  - Area widgets take a `Rect`.
- Stateful draws put the state right after the rect: `grid_draw(f, r, &list, cols, cells)`.
- Key handlers put the key second: `search_on_key(&s, k, &view, lines, visible)`. They return `true` (or a result enum) when they consumed the key.

## Memory

- `paint` and the text helpers (`truncate`, `wrap`, `fmt.tprint`...) use `context.temp_allocator`. The runtime frees it after every frame.
- Anything you keep in your state must use `context.allocator` and be freed by you. Components that own memory have a `*_destroy`.
- `Paste.text` is only valid during the `react` call that receives it.
- `md_render` returns an owning `Md_Doc` (`md_destroy`). `md_lines` borrows.

## Background work

- `spawn(fx, work, data, cancel?)` hands `data` to a worker thread. Never touch `State` from the worker; copy what it needs into the job.
- Quitting is instant and does not stop started work. A task still queued when the engine is destroyed never runs: its `cancel` callback disposes of `data`. A result the app will never react to (in flight at shutdown, completed after close) goes to `App.drop` — `Engine.on_result_drop` for custom loops. Disposal can run on a worker thread, concurrently with teardown: keep it quick; it may call engine APIs but never `react`.
- `MAX_WORKERS` bounds threads, not queue depth. Queue admission and backpressure are the caller's policy.

## Invalidation

- Tree structural mutations (`tree_add`, `tree_clear_children(t, n)`, `tree_expand`, `tree_flatten`) keep the visible-row cache and selection coherent on their own; callers never repair `Tree.rows` by hand.
- `Filter` and `Search` recompute when the query or the item/line count changes. When the *content* changes at the same count, call `filter_invalidate` / `search_invalidate` before the next `*_update`.

## Clipping and layering

- Widgets do not clip themselves. Use `clip_scope(f, rect)` so nothing drawn later in the block leaves the rect.
- Whatever paints last is on top. `zone` registrations follow the same rule, so a dialog painted last also wins mouse hit-tests.

## Colors

Components ask the theme for a `Tone` and a `Variant`. They never name raw
colors. Every built-in theme passes the WCAG contrast test in `galdr/fuzz_test.odin`.

## Stability tiers

| Tier | What | Promise |
|---|---|---|
| **Core** | `App`, `Fx`, `Event`, `run`, `Options`, `Frame` and its drawing procs, layout, `Block`, theming, widgets, stateful components, markdown | Frozen at 1.0. Changes go through deprecation. |
| **Advanced** | `Engine`, `Session`, `Input_Reader`, `decode`, `render_diff`, `write_sgr*`, `Harness` | Kept stable, but may gain parameters. For custom loops and tests. |
| **Internal** | anything `@(private)`, generated Unicode tables | Can change at any time. |

## Changes and deprecation

- **0.x (now):** a minor release may break the API. Every break is listed under **Breaking** in `CHANGELOG.md`, with a one-line migration.
- **From 1.0:** nothing in Core or Advanced is removed or changed without first shipping for at least one minor release as a deprecated alias. The alias is marked `@(deprecated="use X")`, so the compiler points callers at the replacement.
- Patch releases never change the API.

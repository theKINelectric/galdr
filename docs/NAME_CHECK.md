# Name check (roadmap item 0.8)

> **Decision (Chief, 2026-09-24): Galdr.** The package, collection, CLI binary
> and environment variables were renamed from `runic` to `galdr` the same day.
> The rest of this file records the check as it was made.

Searched 2026-09-24: GitHub repository names, the Odin language filter, and Homebrew.

## "runic" is taken in the Odin ecosystem

| Project | Language | Stars | What it is |
|---|---|---|---|
| `Samudevv/runic` | **Odin** | 100 | Bindings generator and intermediate format. Well known in the community. |
| `kalsprite/runic` | **Odin** | 10 | Font engine |
| `fredrikekre/Runic.jl` | Julia | 246 | Code formatter |
| `zblanco/runic` | Elixir | 112 | DAG workflows |

Two Odin packages already use the name. A third would collide in `import`
paths, in search results and in conversation ("which runic?").
**Recommendation: choose a public name before v0.1.0.** Keep `runic` internally
until then, since renaming is mechanical (package name, collection, CLI binary).

## Candidates (Norse, to match the estate)

| Name | Meaning | GitHub (by name) | Odin clash | Homebrew |
|---|---|---|---|---|
| **Galdr** | Old Norse for a sung incantation. The "melody" fits the provenance law. | small projects, top 67★ | none | free |
| **Stave** | a rune stave, and the staff that music is written on | small projects, top 52★ | none | free |
| Seidr | Norse magic practice | small, top 25★ | none | free |
| Rimur | Icelandic rhymed epics | small, top 65★ | none | free |
| Skald | Norse poet | 564★ project | **`BuLEEto/Skald` (Odin)** | free |
| Ogham | Irish alphabet | 24k★ project | none | free |

**Recommended: Galdr**, with Stave as the runner-up. The decision belongs to the Chief.

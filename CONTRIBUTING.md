# Contributing

## Setup
- Odin: the version in `.github/workflows/ci.yml` (currently `dev-2026-09`).
- For the smoke tests: `python3 -m pip install pyte`.

## The gate
`./ci.sh` is exactly what CI runs:
- strict checks (`-vet -strict-style -warnings-as-errors`)
- unit tests, plus a run under AddressSanitizer
- builds
- pty smoke tests (`scripts/smoke.py`)

Use `./ci.sh --quick` to skip the smoke tests while iterating. CI is Linux-only, so run the gate locally on macOS before you push.

To reproduce Linux CI on a Mac with Docker:
```sh
tar --exclude=./bin --exclude=./.git -cf - . | docker run --rm -i ubuntu:24.04 \
  bash -c 'mkdir /src && tar -xf - -C /src && cd /src && bash scripts/ci_linux.sh'
```

## Style
- Match the surrounding code: tabs, `snake_case` procedures, `Ada_Case` types.
- Components ask the theme for a `Tone` and a `Variant`. They never name raw colors.
- Anything that touches the terminal belongs in `Session` / `term_*`. Everything else stays pure and testable.
- Every fix gets a test. A bug that needed a real terminal to find gets a check in `scripts/smoke.py`.

## Docs
Odin code in `README.md`, `docs/TUTORIAL.md` and `docs/COOKBOOK.md` is copied from `examples/readme`, `examples/tutorial` and `examples/cookbook`. Change the example first, make sure it passes, then paste the excerpt. `scripts/check_docs.py`, part of the gate, fails when a snippet no longer matches. A line that is exactly `// ...` marks an elision.

## Terminal reports
Tried Galdr in a terminal that has no row yet in `docs/TERMINALS.md`? A report is one of the most useful contributions. That file lists the steps and what to include.

## Commits
Imperative subject (≤ 72 chars), and a body that explains *why*. Add a CHANGELOG line for anything a user would notice.

## Provenance
Don't port code from other TUI libraries. If an API starts to mirror another library's shape, recompose it.

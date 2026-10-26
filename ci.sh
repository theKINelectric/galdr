#!/usr/bin/env bash
# The CI gate. Run locally before pushing; CI runs exactly this.
#   ./ci.sh          full gate (strict checks, tests, builds, smoke)
#   ./ci.sh --quick  skip the pty smoke tests
set -euo pipefail
cd "$(dirname "$0")"
STRICT=(-vet -strict-style -warnings-as-errors)

echo "== odin $(odin version)"
echo "== strict checks"
for pkg in examples/hello examples/mission examples/readme examples/tutorial examples/cookbook cmd/galdr scripts/session_probe; do
  odin check "$pkg" -collection:galdr=. "${STRICT[@]}"
done

echo "== tests"
odin test galdr "${STRICT[@]}"
odin test examples/mission -collection:galdr=. "${STRICT[@]}"
odin test examples/tutorial -collection:galdr=. "${STRICT[@]}"
odin test examples/cookbook -collection:galdr=. "${STRICT[@]}"

echo "== docs"
python3 scripts/check_docs.py
if [[ "$(uname)" == "Darwin" || "$(uname)" == "Linux" ]]; then
  odin test galdr -sanitize:address -define:ODIN_TEST_THREADS=1
fi

echo "== builds"
mkdir -p bin
odin build examples/hello   -collection:galdr=. -out:bin/hello   -o:speed
odin build examples/mission -collection:galdr=. -out:bin/mission -o:speed
odin build cmd/galdr        -collection:galdr=. -out:bin/galdr   -o:speed
odin build scripts/session_probe -collection:galdr=. -out:bin/session_probe -o:speed # the smoke suite runs it

if [[ "${1:-}" != "--quick" ]]; then
  echo "== smoke (pty)"
  python3 scripts/smoke.py
fi
echo "== CI gate green"

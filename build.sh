#!/usr/bin/env bash
# Test everything, then build the examples and the CLI into ./bin.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
odin test galdr
odin test examples/mission -collection:galdr=.
odin test examples/tutorial -collection:galdr=.
odin test examples/cookbook -collection:galdr=.
odin build examples/hello   -collection:galdr=. -out:bin/hello   -o:speed
odin build examples/mission -collection:galdr=. -out:bin/mission -o:speed
odin build cmd/galdr        -collection:galdr=. -out:bin/galdr   -o:speed
odin build scripts/session_probe -collection:galdr=. -out:bin/session_probe -o:speed
echo "ok: bin/hello bin/mission bin/galdr bin/session_probe"

#!/usr/bin/env bash
# Provision a bare Debian/Ubuntu container and run the CI gate.
# Used by .github/workflows/ci.yml and runnable locally:
#   docker run --rm -v "$PWD":/src -w /src ubuntu:24.04 scripts/ci_linux.sh
set -euo pipefail
ODIN_TAG="${ODIN_TAG:-dev-2026-09}"
case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl clang llvm libclang-rt-dev python3 python3-pip bash procps >/dev/null
pip3 install --quiet --break-system-packages pyte

mkdir -p /opt/odin
curl -fsSL "https://github.com/odin-lang/Odin/releases/download/${ODIN_TAG}/odin-linux-${ARCH}-${ODIN_TAG}.tar.gz" \
  | tar -xz -C /opt/odin --strip-components=1
export PATH="/opt/odin:$PATH"

# Build into a container-local copy so host binaries (macOS) aren't clobbered.
rm -rf /tmp/ci && mkdir -p /tmp/ci && cp -R . /tmp/ci && cd /tmp/ci && rm -rf bin
./ci.sh "$@"

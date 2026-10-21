#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v swift >/dev/null 2>&1; then
    echo 'Swift is unavailable on PATH. No tests ran.' >&2
    echo 'See README.md for toolchain/container setup, then rerun ./scripts/test-core.sh.' >&2
    exit 127
fi
swift --version
exec swift test "$@"

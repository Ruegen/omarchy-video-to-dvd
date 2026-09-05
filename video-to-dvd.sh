#!/bin/bash
# Compatibility wrapper. The helper is the Rust binary oma-dvd.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/oma-dvd"
if [[ ! -x "$BIN" ]]; then
  echo "RESULT:ERROR:runtime-state" >&2
  echo "oma-dvd is missing. From this folder run: cargo build --release && cp -f target/release/oma-dvd ." >&2
  exit 1
fi
exec "$BIN" "$@"

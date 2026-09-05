#!/bin/bash
# Runs the Rust helper unit tests (no disc, no ffmpeg encode).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
cargo test

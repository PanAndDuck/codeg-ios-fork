#!/usr/bin/env bash
unset CODEG_DATA_DIR CODEG_HOME CODEG_STATIC_DIR CODEG_ACP_TMP_ROOT CODEG_TOKEN CODEG_PORT CODEG_HOST
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ $# != 2 || "$1" != --name || -z "$2" ]]; then
  printf 'Usage: scripts/test-pairing-paste.sh --name <dedicated-empty-simulator>\n' >&2
  exit 1
fi
SIM_NAME="$2"
mkdir -p build/fork/pairing
WORK_DIR="$(mktemp -d "$ROOT/build/fork/pairing/unit.XXXXXX")"
export CODEG_DATA_DIR="$WORK_DIR/data" CODEG_HOME="$WORK_DIR/home"
mkdir -p "$CODEG_DATA_DIR" "$CODEG_HOME"
trap 'rmdir "$CODEG_DATA_DIR" "$CODEG_HOME" "$WORK_DIR"' EXIT

# Run the unit suite; the optional UI controller uses its own scheme.
scripts/build-fork.sh test --name "$SIM_NAME" 2>&1 | tail -n 60

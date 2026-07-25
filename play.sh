#!/usr/bin/env bash

set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/alsaadii98/letithappen-sh/main"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/letithappen.XXXXXX")"
RUNNER="$TEMP_DIR/run.sh"
SONG="$TEMP_DIR/1.mp3"
LYRICS="$TEMP_DIR/1.lrc"

cleanup() {
  rm -f "$RUNNER" "$SONG" "$LYRICS"
  rmdir "$TEMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required."
  exit 1
fi

if ! command -v mpv >/dev/null 2>&1; then
  echo "mpv is required."
  echo "macOS: brew install mpv"
  echo "Ubuntu: sudo apt install mpv"
  exit 1
fi

printf 'Loading Let It Happen…\n'

curl -fsSL --retry 3 "$BASE_URL/run.sh" -o "$RUNNER"
curl -fsSL --retry 3 "$BASE_URL/1.lrc" -o "$LYRICS"
curl -fsSL --retry 3 "$BASE_URL/1.mp3" -o "$SONG"

bash "$RUNNER" "$SONG" "$LYRICS"

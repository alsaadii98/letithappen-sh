#!/usr/bin/env bash

set -uo pipefail

BASE_URL="https://letithappen.alsaadii98.com"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/letithappen.XXXXXX")"
RUNNER="$TEMP_DIR/run.sh"
SONG="$TEMP_DIR/1.mp3"
LYRICS="$TEMP_DIR/1.lrc"

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT INT TERM

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required."
  exit 1
fi

printf 'Loading Let It Happen…\n'

if ! curl -fsSL --retry 3 "$BASE_URL/run.sh" -o "$RUNNER"; then
  echo "Could not download the player."
  exit 1
fi

# Sourced only for its helpers — run.sh returns early under this flag. Doing
# the dependency prompt here means a missing mpv is caught before the 11MB of
# audio is fetched, not after.
TERMINAL_SONG_LIB=1 . "$RUNNER"

if ! ensure_dependencies; then
  exit 1
fi

if ! curl -fsSL --retry 3 "$BASE_URL/1.lrc" -o "$LYRICS"; then
  echo "Could not download the lyrics."
  exit 1
fi

printf 'Fetching audio…\n'
if ! curl -fsSL --retry 3 "$BASE_URL/1.mp3" -o "$SONG"; then
  echo "Could not download the audio."
  exit 1
fi

bash "$RUNNER" "$SONG" "$LYRICS"

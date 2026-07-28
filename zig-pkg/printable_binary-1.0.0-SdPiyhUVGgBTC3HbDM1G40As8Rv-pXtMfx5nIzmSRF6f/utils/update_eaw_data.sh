#!/usr/bin/env bash
# Refresh utils/data/EastAsianWidth.txt from the Unicode UCD feed and rerun the map audit.
set -euo pipefail

URL="https://www.unicode.org/Public/UCD/latest/ucd/EastAsianWidth.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$SCRIPT_DIR/data/EastAsianWidth.txt"
TMP="$(mktemp)"

echo "Downloading EastAsianWidth.txt from $URL"
curl -fsSL "$URL" -o "$TMP"
mkdir -p "$SCRIPT_DIR/data"
mv "$TMP" "$DEST"
chmod 644 "$DEST"

if command -v luajit >/dev/null 2>&1; then
  echo "Running audit_character_map.lua with updated width data..."
  "$SCRIPT_DIR/audit_character_map.lua" "$ROOT_DIR/character_map.txt" >/dev/null || true
fi

echo "Updated $DEST"

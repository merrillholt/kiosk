#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$ROOT_DIR/manifest/install-files.txt"
INSTALL_DIR="$ROOT_DIR/building-directory-install"

if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing manifest: $MANIFEST" >&2
  exit 1
fi
if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "Missing install tree: $INSTALL_DIR" >&2
  exit 1
fi

missing=0
while IFS= read -r rel; do
  [[ -z "$rel" || "$rel" =~ ^# ]] && continue
  src="$ROOT_DIR/$rel"
  dst="$INSTALL_DIR/$rel"
  if [[ ! -e "$src" ]]; then
    echo "Missing source file: $rel" >&2
    missing=1
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  echo "synced: $rel"
done < "$MANIFEST"

if [[ "$missing" -ne 0 ]]; then
  echo "Sync completed with missing source files." >&2
  exit 1
fi

echo "Install tree synced from canonical sources."

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_INSTALL_DIR="$ROOT_DIR/building-directory-install"
MANIFEST="$ROOT_DIR/manifest/install-files.txt"
DIST_DIR="$ROOT_DIR/dist/install"
OUT_DIR="$DIST_DIR/building-directory-install"
ZIP_PATH="$ROOT_DIR/dist/building-directory-install.zip"

if [[ ! -d "$SRC_INSTALL_DIR" ]]; then
  echo "Missing source install directory: $SRC_INSTALL_DIR" >&2
  exit 1
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing manifest: $MANIFEST" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$OUT_DIR"
cp -a "$SRC_INSTALL_DIR" "$OUT_DIR"

missing=0
while IFS= read -r rel; do
  [[ -z "$rel" || "$rel" =~ ^# ]] && continue
  src="$ROOT_DIR/$rel"
  dst="$OUT_DIR/$rel"
  if [[ ! -e "$src" ]]; then
    echo "Missing source file from manifest: $rel" >&2
    missing=1
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
done < "$MANIFEST"

if [[ "$missing" -ne 0 ]]; then
  echo "Packaging aborted due to missing manifest files." >&2
  exit 1
fi

if command -v zip >/dev/null 2>&1; then
  rm -f "$ZIP_PATH"
  (
    cd "$DIST_DIR"
    zip -qr "$ZIP_PATH" "building-directory-install"
  )
  echo "Created: $ZIP_PATH"
else
  echo "zip not installed; skipped zip output" >&2
fi

echo "Packaged install tree: $OUT_DIR"

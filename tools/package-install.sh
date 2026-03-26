#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_INSTALL_DIR="$ROOT_DIR/building-directory-install"
MANIFEST="$ROOT_DIR/manifest/install-files.txt"
DIST_DIR="$ROOT_DIR/dist/install"
OUT_DIR="$DIST_DIR/building-directory-install"
ZIP_PATH="$ROOT_DIR/dist/building-directory-install.zip"
COMPUTE_REVISION="$SCRIPT_DIR/compute-revision.sh"
SYNC_INSTALL_TREE="$SCRIPT_DIR/sync-install-tree.sh"
CHECK_INSTALL_DRIFT="$SCRIPT_DIR/check-install-drift.sh"

if [[ ! -d "$SRC_INSTALL_DIR" ]]; then
  echo "Missing source install directory: $SRC_INSTALL_DIR" >&2
  exit 1
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing manifest: $MANIFEST" >&2
  exit 1
fi

if [[ ! -x "$SYNC_INSTALL_TREE" || ! -x "$CHECK_INSTALL_DRIFT" ]]; then
  echo "Missing install-tree tooling in $SCRIPT_DIR" >&2
  exit 1
fi

echo "Refreshing generated install tree from canonical sources..."
"$SYNC_INSTALL_TREE"
"$CHECK_INSTALL_DRIFT"
echo "Documentation PDFs refreshed in $SRC_INSTALL_DIR/docs/pdf"

mkdir -p "$DIST_DIR"
rm -rf "$OUT_DIR"
cp -a "$SRC_INSTALL_DIR" "$OUT_DIR"

missing=0
REVISION_VALUE="$("$COMPUTE_REVISION")"
printf '%s\n' "$REVISION_VALUE" > "$OUT_DIR/REVISION"
echo "Wrote computed revision: $REVISION_VALUE"

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

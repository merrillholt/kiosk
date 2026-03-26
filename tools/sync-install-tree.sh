#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$ROOT_DIR/manifest/install-files.txt"
INSTALL_DIR="$ROOT_DIR/building-directory-install"
COMPUTE_REVISION="$SCRIPT_DIR/compute-revision.sh"
GENERATE_INSTALL_DOC_PDFS="$SCRIPT_DIR/generate-install-doc-pdfs.sh"
GENERATED_MARKER="$INSTALL_DIR/.generated-from-root"

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

REVISION_VALUE="$("$COMPUTE_REVISION")"
printf '%s\n' "$REVISION_VALUE" > "$INSTALL_DIR/REVISION"
echo "synced: REVISION (computed)"

if [[ -x "$GENERATE_INSTALL_DOC_PDFS" ]]; then
  "$GENERATE_INSTALL_DOC_PDFS"
fi

cat > "$GENERATED_MARKER" <<'EOF'
This directory contains generated install-tree copies of manifest-managed files.

Do not hand-edit duplicated runtime files under building-directory-install/scripts.
Edit the canonical sources in the repository root and regenerate with:

  ./tools/sync-install-tree.sh

Drift can be checked with:

  ./tools/check-install-drift.sh

Documentation PDFs are also regenerated into:

  building-directory-install/docs/
EOF
echo "synced: .generated-from-root"

echo "Install tree synced from canonical sources."

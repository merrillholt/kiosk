#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="$ROOT_DIR/building-directory-install"
MANIFEST="$ROOT_DIR/manifest/install-files.txt"
COMPUTE_REVISION="$SCRIPT_DIR/compute-revision.sh"

if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "Missing install directory: $INSTALL_DIR" >&2
  exit 1
fi

status=0
while IFS= read -r rel; do
  [[ -z "$rel" || "$rel" =~ ^# ]] && continue
  src="$ROOT_DIR/$rel"
  inst="$INSTALL_DIR/$rel"
  if [[ ! -e "$src" ]]; then
    echo "MISSING source: $rel"
    status=1
    continue
  fi
  if [[ ! -e "$inst" ]]; then
    echo "MISSING install: $rel"
    status=1
    continue
  fi
  if ! cmp -s "$src" "$inst"; then
    echo "DIFF: $rel"
    status=1
  fi
done < "$MANIFEST"

expected_revision="$("$COMPUTE_REVISION")"
install_revision_file="$INSTALL_DIR/REVISION"
if [[ ! -e "$install_revision_file" ]]; then
  echo "MISSING install: REVISION"
  status=1
else
  actual_revision="$(tr -d '\r' < "$install_revision_file" | head -n 1 | sed 's/[[:space:]]*$//')"
  if [[ "$actual_revision" != "$expected_revision" ]]; then
    echo "DIFF: REVISION"
    status=1
  fi
fi

if [[ "$status" -eq 0 ]]; then
  echo "OK: install tree matches manifest files"
else
  echo "Drift detected between root and building-directory-install" >&2
  echo "Run ./tools/sync-install-tree.sh to regenerate the install tree." >&2
fi

exit "$status"

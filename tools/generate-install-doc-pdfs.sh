#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$ROOT_DIR/docs"
INSTALL_DIR="$ROOT_DIR/building-directory-install"
PRINT_DOCS="$SCRIPT_DIR/print-docs.sh"
OUT_DIR="$INSTALL_DIR/docs"

if [[ ! -d "$DOCS_DIR" ]]; then
  echo "Missing docs directory: $DOCS_DIR" >&2
  exit 1
fi
if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "Missing install tree: $INSTALL_DIR" >&2
  exit 1
fi
if [[ ! -x "$PRINT_DOCS" ]]; then
  echo "Missing printable docs tool: $PRINT_DOCS" >&2
  exit 1
fi
if ! command -v pandoc >/dev/null 2>&1; then
  echo "Missing dependency: pandoc" >&2
  exit 1
fi
if ! command -v xelatex >/dev/null 2>&1; then
  echo "Missing dependency: xelatex" >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

"$PRINT_DOCS" --out "$OUT_DIR" all

while IFS= read -r doc; do
  base="$(basename "$doc")"
  if [[ "$base" == "README.md" ]]; then
    continue
  fi
  if [[ -f "$OUT_DIR/${base%.md}.pdf" ]]; then
    continue
  fi
  "$PRINT_DOCS" --out "$OUT_DIR" "$doc"
done < <(find "$DOCS_DIR" -maxdepth 1 -type f -name '*.md' | sort)

echo "Generated documentation PDFs in $OUT_DIR"

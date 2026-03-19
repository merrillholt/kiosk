#!/usr/bin/env bash
# Print documentation as PDF using pandoc + xelatex.
#
# Usage:
#   tools/print-docs.sh all                     # Full manual with cover + TOC
#   tools/print-docs.sh <name>                  # Single document
#   tools/print-docs.sh --list                  # List printable documents
#   tools/print-docs.sh --out <dir> all         # Override output directory
#
# Single document <name> may be given with or without path/extension:
#   tools/print-docs.sh 01-hardware-requirements
#   tools/print-docs.sh docs/01-hardware-requirements.md
#
# Output goes to dist/docs/ by default.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$ROOT_DIR/docs"
OUT_DIR="$ROOT_DIR/dist/docs"

PANDOC_COMMON=(
  --pdf-engine=xelatex
  -V geometry:margin=1in
  -V fontsize=11pt
  -V linkcolor=blue
  -V urlcolor=blue
  -V mainfont="DejaVu Serif"
  -V sansfont="DejaVu Sans"
  -V monofont="DejaVu Sans Mono"
)

# Ordered list of documents included in the full manual.
ALL_DOCS=(
  "01-hardware-requirements.md"
  "05-architecture-overview.md"
  "03-read-only-filesystem.md"
  "06-desktop-environment.md"
  "07-touchscreen-setup.md"
  "elo-cage-wayland-kiosk-hardening.md"
  "08-packaging-and-deploy.md"
  "09-server-operations.md"
  "10-new-host-installation.md"
  "04-development-environment.md"
)

usage() {
  cat <<'EOF'
Usage: tools/print-docs.sh [--out <dir>] {all|--list|<name>}

  all           Build full manual PDF with cover page and TOC
  --list        Show printable documents
  <name>        Build single document PDF
                (name with or without docs/ prefix and .md extension)
  --out <dir>   Output directory (default: dist/docs/)
EOF
  exit 2
}

list_docs() {
  echo "Printable documents (in manual order):"
  for f in "${ALL_DOCS[@]}"; do
    echo "  ${f%.md}"
  done
  echo ""
  echo "Also printable (not in full manual):"
  for f in "$DOCS_DIR"/*.md; do
    base="$(basename "$f")"
    found=0
    for d in "${ALL_DOCS[@]}"; do
      [[ "$d" == "$base" ]] && found=1 && break
    done
    [[ "$found" -eq 0 ]] && echo "  ${base%.md}"
  done
}

build_all() {
  local out="$OUT_DIR/building-directory-manual.pdf"
  local date_str
  date_str="$(date '+%B %d, %Y')"
  mkdir -p "$OUT_DIR"

  # Collect doc paths in order
  local paths=()
  for f in "${ALL_DOCS[@]}"; do
    local p="$DOCS_DIR/$f"
    if [[ ! -f "$p" ]]; then
      echo "Warning: missing doc $f — skipping" >&2
      continue
    fi
    paths+=("$p")
  done

  echo "Building full manual → $out"
  pandoc \
    "${PANDOC_COMMON[@]}" \
    --metadata title="Building Directory Kiosk" \
    --metadata subtitle="Technical Documentation" \
    --metadata date="$date_str" \
    --toc \
    --toc-depth=2 \
    --number-sections \
    "${paths[@]}" \
    -o "$out"
  echo "Done: $out"

  # Also build individual PDFs for each doc
  for f in "${ALL_DOCS[@]}"; do
    local p="$DOCS_DIR/$f"
    [[ -f "$p" ]] && build_one "$p"
  done
}

build_one() {
  local arg="$1"
  # Resolve to a full path
  local path
  if [[ -f "$arg" ]]; then
    path="$(realpath "$arg")"
  elif [[ -f "$DOCS_DIR/$arg" ]]; then
    path="$DOCS_DIR/$arg"
  elif [[ -f "$DOCS_DIR/${arg}.md" ]]; then
    path="$DOCS_DIR/${arg}.md"
  elif [[ -f "$DOCS_DIR/$(basename "${arg%.md}").md" ]]; then
    path="$DOCS_DIR/$(basename "${arg%.md}").md"
  else
    echo "Error: cannot find document: $arg" >&2
    echo "Run 'tools/print-docs.sh --list' to see available documents." >&2
    exit 1
  fi

  local base
  base="$(basename "${path%.md}")"
  local out="$OUT_DIR/${base}.pdf"
  mkdir -p "$OUT_DIR"

  echo "Building $base → $out"
  pandoc \
    "${PANDOC_COMMON[@]}" \
    --toc \
    --toc-depth=2 \
    "$path" \
    -o "$out"
  echo "Done: $out"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="$2"; shift 2 ;;
    --list)
      list_docs; exit 0 ;;
    all)
      build_all; exit 0 ;;
    -h|--help|help)
      usage ;;
    *)
      build_one "$1"; exit 0 ;;
  esac
done

usage

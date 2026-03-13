#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REVISION_FILE="${REVISION_FILE:-$ROOT_DIR/REVISION}"
PACKAGE_JSON_FILE="${PACKAGE_JSON_FILE:-$ROOT_DIR/server/package.json}"

if [[ -n "${KIOSK_REVISION:-}" ]]; then
  printf '%s\n' "$KIOSK_REVISION"
  exit 0
fi

if command -v git >/dev/null 2>&1 && [[ -d "$ROOT_DIR/.git" ]]; then
  git_rev="$(git -C "$ROOT_DIR" log -1 --date=format:%Y.%m.%d --format='%cd.%h' 2>/dev/null || true)"
  if [[ -n "$git_rev" ]]; then
    printf '%s\n' "$git_rev"
    exit 0
  fi
fi

if [[ -f "$REVISION_FILE" ]]; then
  file_rev="$(tr -d '\r' < "$REVISION_FILE" | head -n 1 | sed 's/[[:space:]]*$//')"
  if [[ -n "$file_rev" ]]; then
    printf '%s\n' "$file_rev"
    exit 0
  fi
fi

if [[ -f "$PACKAGE_JSON_FILE" ]]; then
  pkg_rev="$(sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$PACKAGE_JSON_FILE" | head -n 1)"
  if [[ -n "$pkg_rev" ]]; then
    printf 'v%s\n' "$pkg_rev"
    exit 0
  fi
fi

printf 'unknown\n'

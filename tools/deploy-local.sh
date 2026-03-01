#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_ROOT="${DEPLOY_ROOT:-/home/security/building-directory}"
SERVER_MANIFEST="$SRC_ROOT/manifest/deploy-server-files.txt"
FULL_MANIFEST="$SRC_ROOT/manifest/install-files.txt"
MANIFEST="${MANIFEST:-$SERVER_MANIFEST}"
DRY_RUN=0
FULL=0

usage() {
  cat <<USAGE
Usage: tools/deploy-local.sh [--dry-run] [--full]

Deploys canonical project files from Public-Kiosk into the local deployed tree,
updates server dependencies, prints manual restart instructions, and runs health checks.

Options:
  -n, --dry-run   Print actions without changing files/services
  -f, --full      Deploy full manifest (server + kiosk + scripts)
  -h, --help      Show this help

Environment:
  DEPLOY_ROOT     Target deployed tree (default: /home/security/building-directory)
  MANIFEST        Override manifest path
                 (default: manifest/deploy-server-files.txt)
USAGE
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -f|--full)
      FULL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$FULL" -eq 1 ]]; then
  MANIFEST="$FULL_MANIFEST"
fi

if [[ ! -d "$DEPLOY_ROOT" ]]; then
  echo "Missing deploy root: $DEPLOY_ROOT" >&2
  exit 1
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing manifest: $MANIFEST" >&2
  exit 1
fi

echo "Deploy source: $SRC_ROOT"
echo "Deploy target: $DEPLOY_ROOT"
[[ "$DRY_RUN" -eq 1 ]] && echo "Mode: dry-run"
[[ "$FULL" -eq 1 ]] && echo "Profile: full" || echo "Profile: server-only"

# 1) Sync manifest-managed files into deployed tree.
missing=0
while IFS= read -r rel; do
  [[ -z "$rel" || "$rel" =~ ^# ]] && continue
  src="$SRC_ROOT/$rel"
  dst="$DEPLOY_ROOT/$rel"
  if [[ ! -e "$src" ]]; then
    echo "Missing source file: $rel" >&2
    missing=1
    continue
  fi
  run_cmd mkdir -p "$(dirname "$dst")"
  run_cmd cp -a "$src" "$dst"
  echo "synced: $rel"
done < "$MANIFEST"

if [[ "$missing" -ne 0 ]]; then
  echo "Aborting: missing source files." >&2
  exit 1
fi

# 2) Ensure production dependencies are installed.
if [[ -f "$DEPLOY_ROOT/server/package-lock.json" ]]; then
  run_cmd npm ci --omit=dev --no-audit --no-fund --loglevel=error --prefix "$DEPLOY_ROOT/server"
else
  run_cmd npm install --omit=dev --no-audit --no-fund --loglevel=error --prefix "$DEPLOY_ROOT/server"
fi

# 3) Ensure persist-upload helper is installed when non-interactive sudo is available.
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] Would install $DEPLOY_ROOT/server/persist-upload.sh to /usr/local/bin/persist-upload.sh"
else
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n install -m 755 "$DEPLOY_ROOT/server/persist-upload.sh" /usr/local/bin/persist-upload.sh
    echo "Installed helper: /usr/local/bin/persist-upload.sh"
  else
    echo "Manual step required:"
    echo "  sudo install -m 755 $DEPLOY_ROOT/server/persist-upload.sh /usr/local/bin/persist-upload.sh"
  fi
fi

# 4) Manual restart instruction (no sudo execution in deploy script).
if command -v systemctl >/dev/null 2>&1 && [[ -f /etc/systemd/system/directory-server.service || -f /lib/systemd/system/directory-server.service ]]; then
  echo "Manual restart required:"
  echo "  sudo systemctl restart directory-server"
else
  echo "Manual restart required (non-systemd):"
  echo "  $DEPLOY_ROOT/scripts/restart-server.sh"
fi

# 5) Health checks (skip in dry-run).
if [[ "$DRY_RUN" -eq 0 ]]; then
  sleep 2
  curl -fsS http://127.0.0.1:3000/api/auth/me > /dev/null
  curl -fsS http://127.0.0.1:3000/api/data-version > /dev/null
  echo "Health checks passed: /api/auth/me, /api/data-version"
fi

echo "Local deploy complete."

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST="${HOST:-kiosk@192.168.1.80}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/home/kiosk/building-directory}"
SERVER_MANIFEST="$SRC_ROOT/manifest/deploy-server-files.txt"
FULL_MANIFEST="$SRC_ROOT/manifest/install-files.txt"
MANIFEST="${MANIFEST:-$SERVER_MANIFEST}"
DRY_RUN=0
FULL=0
NO_RESTART=0
WITH_DB=0
DB_SOURCE="${DB_SOURCE:-}"
OVERLAY_MODE="${OVERLAY_MODE:-auto}"
OVERLAY_INSTALL_DEPS="${OVERLAY_INSTALL_DEPS:-0}"
REQUIRE_MAINTENANCE=0

usage() {
  cat <<USAGE
Usage: tools/deploy-ssh.sh [options]

Deploy canonical files from Public-Kiosk to a remote server host over SSH.
Default profile deploys server-only files; use --full for server+kiosk+scripts.

Options:
  -H, --host <user@ip>   Remote SSH target (default: kiosk@192.168.1.80)
  -n, --dry-run          Preview actions without modifying remote host
  -f, --full             Deploy full manifest (server + kiosk + scripts)
      --overlay          Force overlayroot-chroot write mode
      --no-overlay       Force direct write mode
      --maintenance      Require maintenance/writable mode and use direct writes
      --no-restart       Skip remote service restart and health checks
      --with-db          Also copy a SQLite DB file to remote server/directory.db
      --db-source <path> SQLite DB source path for --with-db
  -h, --help             Show this help

Environment:
  HOST                   Same as --host
  DEPLOY_ROOT            Remote deploy root (default: /home/kiosk/building-directory)
  MANIFEST               Override manifest path (default: deploy-server-files.txt)
  DB_SOURCE              Same as --db-source
  OVERLAY_MODE           auto|on|off (default: auto)
  OVERLAY_INSTALL_DEPS   1 to run npm install in overlay mode (default: 0)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host)
      HOST="${2:-}"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -f|--full)
      FULL=1
      shift
      ;;
    --overlay)
      OVERLAY_MODE="on"
      shift
      ;;
    --no-overlay)
      OVERLAY_MODE="off"
      shift
      ;;
    --maintenance)
      OVERLAY_MODE="off"
      REQUIRE_MAINTENANCE=1
      shift
      ;;
    --no-restart)
      NO_RESTART=1
      shift
      ;;
    --with-db)
      WITH_DB=1
      shift
      ;;
    --db-source)
      DB_SOURCE="${2:-}"
      shift 2
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

if [[ -z "$HOST" ]]; then
  echo "Host cannot be empty." >&2
  exit 2
fi

if [[ "$FULL" -eq 1 ]]; then
  MANIFEST="$FULL_MANIFEST"
fi

if [[ ! -d "$SRC_ROOT" ]]; then
  echo "Missing source root: $SRC_ROOT" >&2
  exit 1
fi

if [[ "$WITH_DB" -eq 1 && -z "$DB_SOURCE" ]]; then
  echo "--with-db requires --db-source <path> (or DB_SOURCE env var)." >&2
  exit 2
fi
if [[ "$WITH_DB" -eq 1 && ! -f "$DB_SOURCE" ]]; then
  echo "DB source file not found: $DB_SOURCE" >&2
  exit 1
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing manifest: $MANIFEST" >&2
  exit 1
fi

TMP_MANIFEST="$(mktemp)"
cleanup() { rm -f "$TMP_MANIFEST"; }
trap cleanup EXIT

awk '!/^\s*($|#)/ { print }' "$MANIFEST" > "$TMP_MANIFEST"

echo "Deploy source: $SRC_ROOT"
echo "Deploy target: $HOST:$DEPLOY_ROOT"
[[ "$DRY_RUN" -eq 1 ]] && echo "Mode: dry-run"
[[ "$FULL" -eq 1 ]] && echo "Profile: full" || echo "Profile: server-only"
[[ "$REQUIRE_MAINTENANCE" -eq 1 ]] && echo "Mode: maintenance (overlay disabled required)"
if [[ "$WITH_DB" -eq 1 ]]; then
  echo "Database source: $DB_SOURCE"
fi

# Validate all source files exist before remote operations.
missing=0
while IFS= read -r rel; do
  [[ -e "$SRC_ROOT/$rel" ]] || { echo "Missing source file: $rel" >&2; missing=1; }
done < "$TMP_MANIFEST"
if [[ "$missing" -ne 0 ]]; then
  echo "Aborting: missing source files." >&2
  exit 1
fi

RSYNC_ARGS=(-az --delete --files-from="$TMP_MANIFEST")
if [[ "$DRY_RUN" -eq 1 ]]; then
  RSYNC_ARGS+=(-n -v)
fi

detect_overlay() {
  ssh "$HOST" "mount | grep -q '^overlayroot on / type overlay'"
}

EFFECTIVE_OVERLAY=0
case "$OVERLAY_MODE" in
  on)
    EFFECTIVE_OVERLAY=1
    ;;
  off)
    EFFECTIVE_OVERLAY=0
    ;;
  auto)
    if detect_overlay; then EFFECTIVE_OVERLAY=1; fi
    ;;
  *)
    echo "Invalid OVERLAY_MODE: $OVERLAY_MODE (expected auto|on|off)" >&2
    exit 2
    ;;
esac

if [[ "$REQUIRE_MAINTENANCE" -eq 1 ]]; then
  if detect_overlay; then
    echo "Maintenance mode required, but overlayroot is active on $HOST." >&2
    echo "Reboot host into maintenance/writable mode and retry with --maintenance." >&2
    exit 1
  fi
fi

if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
  echo "Overlay deploy mode: enabled"
  STAGE_DIR="/tmp/building-directory-deploy-$RANDOM-$(date +%s)"
  CHROOT_STAGE="/run/deploy-stage"
  REMOTE_MANIFEST="/tmp/building-directory-deploy-manifest-$RANDOM-$(date +%s).txt"
  echo "==> Staging manifest files on remote..."
  ssh "$HOST" "mkdir -p '$STAGE_DIR'"
  rsync "${RSYNC_ARGS[@]}" "$SRC_ROOT/" "$HOST:$STAGE_DIR/"
  scp "$TMP_MANIFEST" "$HOST:$REMOTE_MANIFEST"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "==> Writing files to overlay lower layer..."
    ssh "$HOST" CHROOT_STAGE="$CHROOT_STAGE" DEPLOY_ROOT="$DEPLOY_ROOT" REMOTE_MANIFEST="$REMOTE_MANIFEST" STAGE_DIR="$STAGE_DIR" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail
cleanup() {
  sudo -n rm -rf "$CHROOT_STAGE"
  rm -rf "$STAGE_DIR" "$REMOTE_MANIFEST"
}
trap cleanup EXIT
sudo -n mkdir -p "$CHROOT_STAGE"
sudo -n cp -a "$STAGE_DIR"/. "$CHROOT_STAGE"/
CHROOT_MANIFEST="$CHROOT_STAGE/.deploy-manifest.txt"
sudo -n cp -f "$REMOTE_MANIFEST" "$CHROOT_MANIFEST"
# Run a single chroot session to avoid repeated mount/unmount churn.
CHROOT_ERR="$(mktemp /tmp/overlayroot-chroot.XXXXXX)"
sudo -n overlayroot-chroot bash -s -- "$CHROOT_STAGE" "$DEPLOY_ROOT" "$CHROOT_MANIFEST" 2>"$CHROOT_ERR" <<'CHROOT_SCRIPT'
set -euo pipefail
CHROOT_STAGE="$1"
DEPLOY_ROOT="$2"
CHROOT_MANIFEST="$3"
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  src="$CHROOT_STAGE/$rel"
  dst="$DEPLOY_ROOT/$rel"
  [[ -f "$src" ]] || { echo "Missing staged file: $src" >&2; exit 1; }
  mode=$(stat -c %a "$src")
  install -D -m "$mode" "$src" "$dst"
done < "$CHROOT_MANIFEST"
CHROOT_SCRIPT
if grep -q "mount point is busy" "$CHROOT_ERR"; then
  if mount | grep -Eq '^/dev/.+ on /media/root-ro type .+ \(ro,'; then
    echo "INFO: overlayroot remount warning observed; /media/root-ro is read-only after file write."
  else
    cat "$CHROOT_ERR" >&2
    echo "ERROR: /media/root-ro is not read-only after overlay write." >&2
    exit 1
  fi
elif [[ -s "$CHROOT_ERR" ]]; then
  cat "$CHROOT_ERR" >&2
fi
rm -f "$CHROOT_ERR"
echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null
REMOTE_SCRIPT
  else
    echo "==> [dry-run] Overlay lower-layer write step skipped."
    ssh "$HOST" "sudo -n rm -rf '$CHROOT_STAGE'; rm -rf '$STAGE_DIR' '$REMOTE_MANIFEST'" || true
  fi
else
  echo "Overlay deploy mode: disabled"
  echo "==> Syncing manifest files..."
  rsync "${RSYNC_ARGS[@]}" "$SRC_ROOT/" "$HOST:$DEPLOY_ROOT/"
fi

if [[ "$WITH_DB" -eq 1 ]]; then
  echo "==> Deploying database file..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] Would copy $DB_SOURCE -> $HOST:$DEPLOY_ROOT/server/directory.db (with service stop/start)"
  else
    scp "$DB_SOURCE" "$HOST:/tmp/directory.db.new"
    if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
      ssh "$HOST" "set -e; sudo -n systemctl stop directory-server; sudo -n overlayroot-chroot cp /tmp/directory.db.new '$DEPLOY_ROOT/server/directory.db'; rm -f /tmp/directory.db.new; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null; sudo -n systemctl start directory-server"
    else
      ssh "$HOST" "set -e; sudo -n systemctl stop directory-server; cp /tmp/directory.db.new '$DEPLOY_ROOT/server/directory.db'; rm -f /tmp/directory.db.new; sudo -n systemctl start directory-server"
    fi
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> [dry-run] Remote npm install/restart/health checks skipped."
  echo "Remote deploy preview complete."
  exit 0
fi

echo "==> Installing production dependencies on remote..."
if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
  if [[ "$OVERLAY_INSTALL_DEPS" -eq 1 ]]; then
    ssh "$HOST" "sudo -n overlayroot-chroot bash -lc \"if [[ -f '$DEPLOY_ROOT/server/package-lock.json' ]]; then npm ci --omit=dev --no-audit --no-fund --loglevel=error --prefix '$DEPLOY_ROOT/server'; else npm install --omit=dev --no-audit --no-fund --loglevel=error --prefix '$DEPLOY_ROOT/server'; fi\""
  else
    echo "==> Skipping npm install in overlay mode (OVERLAY_INSTALL_DEPS=0)."
  fi
else
  echo "==> Normalizing server directory ownership for dependency install..."
  ssh "$HOST" "set -e; if [[ -d '$DEPLOY_ROOT/server/node_modules' ]]; then sudo -n chown -R \$(id -un):\$(id -gn) '$DEPLOY_ROOT/server/node_modules'; fi; sudo -n chown \$(id -un):\$(id -gn) '$DEPLOY_ROOT/server' '$DEPLOY_ROOT/server/package.json' '$DEPLOY_ROOT/server/package-lock.json' 2>/dev/null || true"
  ssh "$HOST" "if [[ -f '$DEPLOY_ROOT/server/package-lock.json' ]]; then npm ci --omit=dev --no-audit --no-fund --loglevel=error --prefix '$DEPLOY_ROOT/server'; else npm install --omit=dev --no-audit --no-fund --loglevel=error --prefix '$DEPLOY_ROOT/server'; fi"
fi

echo "==> Installing persist-upload helper on remote..."
if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
  ssh "$HOST" "sudo -n overlayroot-chroot install -m 755 '$DEPLOY_ROOT/server/persist-upload.sh' /usr/local/bin/persist-upload.sh"
else
  ssh "$HOST" "sudo -n install -m 755 '$DEPLOY_ROOT/server/persist-upload.sh' /usr/local/bin/persist-upload.sh"
fi

if [[ "$NO_RESTART" -eq 1 ]]; then
  echo "==> --no-restart set; skipping service restart and health checks."
  echo "Remote deploy complete."
  exit 0
fi

echo "==> Restarting remote service..."
if ssh "$HOST" "command -v systemctl >/dev/null 2>&1 && (test -f /etc/systemd/system/directory-server.service || test -f /lib/systemd/system/directory-server.service)"; then
  if ! ssh "$HOST" "sudo -n systemctl restart directory-server"; then
    echo "WARN: non-interactive restart failed. Run on remote host:" >&2
    echo "  sudo systemctl restart directory-server" >&2
    exit 1
  fi
else
  echo "WARN: directory-server systemd service not found on remote host." >&2
  echo "Manual restart may be required." >&2
  exit 1
fi

echo "==> Running remote health checks..."
ssh "$HOST" "bash -lc '
for i in {1..20}; do
  curl -fsS http://127.0.0.1:3000/api/auth/me >/dev/null 2>&1 &&
  curl -fsS http://127.0.0.1:3000/api/data-version >/dev/null 2>&1 &&
  exit 0
  sleep 1
done
echo \"Health checks did not pass within timeout\" >&2
exit 1
'"

echo "Remote deploy complete."

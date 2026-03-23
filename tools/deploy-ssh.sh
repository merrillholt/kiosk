#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPUTE_REVISION="$SCRIPT_DIR/compute-revision.sh"

HOST="${HOST:-kiosk@192.168.1.80}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/home/kiosk/building-directory}"
SERVER_MANIFEST="$SRC_ROOT/manifest/deploy-server-files.txt"
CLIENT_MANIFEST="$SRC_ROOT/manifest/deploy-client-files.txt"
FULL_MANIFEST="$SRC_ROOT/manifest/install-files.txt"
MANIFEST="${MANIFEST:-}"
DRY_RUN=0
PROFILE="${PROFILE:-server}"
NO_RESTART=0
WITH_DB=0
DB_SOURCE="${DB_SOURCE:-}"
OVERLAY_MODE="${OVERLAY_MODE:-auto}"
OVERLAY_INSTALL_DEPS="${OVERLAY_INSTALL_DEPS:-0}"
REQUIRE_MAINTENANCE=0
KIOSK_PRIMARY_URL="${KIOSK_PRIMARY_URL:-http://192.168.1.80}"
KIOSK_STANDBY_URL="${KIOSK_STANDBY_URL:-http://192.168.1.81}"

host_ip() {
  local target="$1"
  if [[ "$target" == *"@"* ]]; then
    printf '%s\n' "${target##*@}"
  else
    printf '%s\n' "$target"
  fi
}

is_protected_kiosk_ip() {
  case "$1" in
    192.168.1.80|192.168.1.81|192.168.1.82)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_dirty_worktree() {
  if ! command -v git >/dev/null 2>&1 || [[ ! -d "$SRC_ROOT/.git" ]]; then
    return 1
  fi
  [[ -n "$(git -C "$SRC_ROOT" status --porcelain)" ]]
}

usage() {
  cat <<USAGE
Usage: tools/deploy-ssh.sh [options]

Deploy canonical files from Public-Kiosk to a remote server host over SSH.
Profiles deploy server-only, client-only, or both.

Options:
  -H, --host <user@ip>   Remote SSH target (default: kiosk@192.168.1.80)
  -n, --dry-run          Preview actions without modifying remote host
      --server           Deploy server-side files only
      --client           Deploy kiosk/client runtime files only
  -f, --full             Deploy both server and client files
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
  PROFILE                server|client|full (default: server)
  MANIFEST               Override manifest path for custom deploys
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
    --server)
      PROFILE="server"
      shift
      ;;
    --client)
      PROFILE="client"
      shift
      ;;
    -f|--full)
      PROFILE="full"
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

HOST_IP="$(host_ip "$HOST")"

case "$PROFILE" in
  server)
    [[ -n "$MANIFEST" ]] || MANIFEST="$SERVER_MANIFEST"
    DEPLOY_SERVER=1
    DEPLOY_CLIENT=0
    ;;
  client)
    [[ -n "$MANIFEST" ]] || MANIFEST="$CLIENT_MANIFEST"
    DEPLOY_SERVER=0
    DEPLOY_CLIENT=1
    ;;
  full)
    [[ -n "$MANIFEST" ]] || MANIFEST="$FULL_MANIFEST"
    DEPLOY_SERVER=1
    DEPLOY_CLIENT=1
    ;;
  *)
    echo "Invalid PROFILE: $PROFILE (expected server|client|full)" >&2
    exit 2
    ;;
esac

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
if [[ "$WITH_DB" -eq 1 && "$DEPLOY_SERVER" -ne 1 ]]; then
  echo "--with-db requires a server or full deploy profile." >&2
  exit 2
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing manifest: $MANIFEST" >&2
  exit 1
fi

if is_protected_kiosk_ip "$HOST_IP" && is_dirty_worktree; then
  echo "Refusing deploy: working tree has uncommitted changes and target $HOST_IP is protected." >&2
  echo "Commit changes before deploying to 192.168.1.80/81/82." >&2
  exit 1
fi

TMP_MANIFEST="$(mktemp)"
TMP_REVISION="$(mktemp)"
cleanup() { rm -f "$TMP_MANIFEST" "$TMP_REVISION"; }
trap cleanup EXIT

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

awk '!/^\s*($|#)/ { print }' "$MANIFEST" > "$TMP_MANIFEST"
REVISION_VALUE="$("$COMPUTE_REVISION")"
printf '%s\n' "$REVISION_VALUE" > "$TMP_REVISION"

echo "Deploy source: $SRC_ROOT"
echo "Deploy target: $HOST:$DEPLOY_ROOT"
[[ "$DRY_RUN" -eq 1 ]] && echo "Mode: dry-run"
echo "Profile: $PROFILE"
echo "Revision: $REVISION_VALUE"
[[ "$REQUIRE_MAINTENANCE" -eq 1 ]] && echo "Mode: maintenance (overlay disabled required)"
if [[ "$WITH_DB" -eq 1 ]]; then
  echo "Database source: $DB_SOURCE"
fi
PATCH_PRIMARY="$(escape_sed_replacement "$KIOSK_PRIMARY_URL")"
PATCH_STANDBY="$(escape_sed_replacement "$KIOSK_STANDBY_URL")"
if [[ "$DEPLOY_CLIENT" -eq 1 ]]; then
  echo "Kiosk browser URLs:"
  echo "  primary: $KIOSK_PRIMARY_URL"
  echo "  standby: $KIOSK_STANDBY_URL"
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
LOWERDIR_DIRECT_WRITE=0
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
  REVISION_STAGE="$STAGE_DIR/REVISION"
  echo "==> Staging manifest files on remote..."
  ssh "$HOST" "mkdir -p '$STAGE_DIR'"
  rsync "${RSYNC_ARGS[@]}" "$SRC_ROOT/" "$HOST:$STAGE_DIR/"
  scp "$TMP_REVISION" "$HOST:$REVISION_STAGE"
  scp "$TMP_MANIFEST" "$HOST:$REMOTE_MANIFEST"
  if [[ "$DEPLOY_CLIENT" -eq 1 ]]; then
    ssh "$HOST" "sed -i 's|^SERVER_URL=.*|SERVER_URL=\"$PATCH_PRIMARY\"|; s|^SERVER_URL_STANDBY=.*|SERVER_URL_STANDBY=\"$PATCH_STANDBY\"|' '$STAGE_DIR/scripts/start-kiosk.sh'"
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "==> Writing files to overlay lower layer..."
    set +e
    REMOTE_OUTPUT="$(ssh "$HOST" CHROOT_STAGE="$CHROOT_STAGE" DEPLOY_ROOT="$DEPLOY_ROOT" REMOTE_MANIFEST="$REMOTE_MANIFEST" STAGE_DIR="$STAGE_DIR" 'bash -s' <<'REMOTE_SCRIPT'
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
sudo -n chmod 644 "$CHROOT_MANIFEST"
# Run a single chroot session to avoid repeated mount/unmount churn.
run_overlay_write() {
  local err_file="$1"
  sudo -n overlayroot-chroot bash -s -- "$CHROOT_STAGE" "$DEPLOY_ROOT" "$CHROOT_MANIFEST" 2>"$err_file" <<'CHROOT_SCRIPT'
set -euo pipefail
CHROOT_STAGE="$1"
DEPLOY_ROOT="$2"
CHROOT_MANIFEST="$3"
install -D -m 644 "$CHROOT_STAGE/REVISION" "$DEPLOY_ROOT/REVISION"
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  src="$CHROOT_STAGE/$rel"
  dst="$DEPLOY_ROOT/$rel"
  [[ -f "$src" ]] || { echo "Missing staged file: $src" >&2; exit 1; }
  mode=$(stat -c %a "$src")
  install -D -m "$mode" "$src" "$dst"
done < "$CHROOT_MANIFEST"
CHROOT_SCRIPT
}

run_lowerdir_fallback() {
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    src="$CHROOT_STAGE/$rel"
    dst="/media/root-ro$DEPLOY_ROOT/$rel"
    [[ -f "$src" ]] || { echo "Missing staged file: $src" >&2; exit 1; }
    mode=$(stat -c %a "$src")
    sudo -n install -D -m "$mode" "$src" "$dst"
  done < "$CHROOT_MANIFEST"
}

CHROOT_ERR="$(mktemp /tmp/overlayroot-chroot.XXXXXX)"
if ! run_overlay_write "$CHROOT_ERR"; then
  cat "$CHROOT_ERR" >&2
  exit 1
fi
if grep -q "mount point is busy" "$CHROOT_ERR"; then
  if mount | grep -Eq '^/dev/.+ on /media/root-ro type .+ \(ro,'; then
    echo "INFO: overlayroot remount warning observed; /media/root-ro is read-only after file write."
  elif mount | grep -Eq '^/dev/.+ on /media/root-ro type .+ \(rw,'; then
    echo "WARN: overlayroot-chroot cleanup failed; falling back to direct lower-layer writes via /media/root-ro."
    run_lowerdir_fallback
    echo "__LOWERDIR_DIRECT_WRITE__"
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
)"
    REMOTE_RC=$?
    set -e
    echo "$REMOTE_OUTPUT"
    if [[ "$REMOTE_RC" -ne 0 ]]; then
      exit 1
    fi
    if [[ "$REMOTE_OUTPUT" == *"__LOWERDIR_DIRECT_WRITE__"* ]]; then
      LOWERDIR_DIRECT_WRITE=1
    fi
  else
    echo "==> [dry-run] Overlay lower-layer write step skipped."
    ssh "$HOST" "sudo -n rm -rf '$CHROOT_STAGE'; rm -rf '$STAGE_DIR' '$REMOTE_MANIFEST'" || true
  fi
else
  echo "Overlay deploy mode: disabled"
  echo "==> Syncing manifest files..."
  rsync "${RSYNC_ARGS[@]}" "$SRC_ROOT/" "$HOST:$DEPLOY_ROOT/"
  scp "$TMP_REVISION" "$HOST:$DEPLOY_ROOT/REVISION"
  if [[ "$DEPLOY_CLIENT" -eq 1 ]]; then
    ssh "$HOST" "sed -i 's|^SERVER_URL=.*|SERVER_URL=\"$PATCH_PRIMARY\"|; s|^SERVER_URL_STANDBY=.*|SERVER_URL_STANDBY=\"$PATCH_STANDBY\"|' '$DEPLOY_ROOT/scripts/start-kiosk.sh'"
  fi
fi

if [[ "$WITH_DB" -eq 1 ]]; then
  echo "==> Deploying database file..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] Would copy $DB_SOURCE -> $HOST:$DEPLOY_ROOT/server/directory.db (with service stop/start)"
  else
    scp "$DB_SOURCE" "$HOST:/tmp/directory.db.new"
    if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
      if [[ "$LOWERDIR_DIRECT_WRITE" -eq 1 ]]; then
        ssh "$HOST" "set -e; sudo -n systemctl stop directory-server; sudo -n install -D -m 644 /tmp/directory.db.new '/media/root-ro$DEPLOY_ROOT/server/directory.db'; rm -f /tmp/directory.db.new; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null; sudo -n systemctl start directory-server"
      else
        ssh "$HOST" "set -e; sudo -n systemctl stop directory-server; sudo -n overlayroot-chroot cp /tmp/directory.db.new '$DEPLOY_ROOT/server/directory.db'; rm -f /tmp/directory.db.new; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null; sudo -n systemctl start directory-server"
      fi
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

if [[ "$DEPLOY_SERVER" -eq 1 ]]; then
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
    ssh "$HOST" "if ! command -v npm &>/dev/null; then echo 'npm not found — skipping (client-only host)'; elif [[ -f '$DEPLOY_ROOT/server/package-lock.json' ]]; then npm ci --omit=dev --no-audit --no-fund --loglevel=error --prefix '$DEPLOY_ROOT/server'; else npm install --omit=dev --no-audit --no-fund --loglevel=error --prefix '$DEPLOY_ROOT/server'; fi"
  fi
  echo "==> Installing persist-upload helper on remote..."
  if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
    if [[ "$LOWERDIR_DIRECT_WRITE" -eq 1 ]]; then
      ssh "$HOST" "sudo -n install -D -m 755 '$DEPLOY_ROOT/server/persist-upload.sh' /media/root-ro/usr/local/bin/persist-upload.sh"
    else
      ssh "$HOST" "sudo -n overlayroot-chroot install -m 755 '$DEPLOY_ROOT/server/persist-upload.sh' /usr/local/bin/persist-upload.sh"
    fi
  else
    ssh "$HOST" "sudo -n install -m 755 '$DEPLOY_ROOT/server/persist-upload.sh' /usr/local/bin/persist-upload.sh"
  fi

  echo "==> Installing backup timer units on remote..."
  if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
    if [[ "$LOWERDIR_DIRECT_WRITE" -eq 1 ]]; then
      ssh "$HOST" "set -e; install_user=\$(stat -c %U '$DEPLOY_ROOT'); sed -e \"s|@INSTALL_USER@|\$install_user|g\" -e \"s|@INSTALL_DIR@|$DEPLOY_ROOT|g\" '$DEPLOY_ROOT/scripts/directory-backup.service' | sudo -n tee /media/root-ro/etc/systemd/system/directory-backup.service >/dev/null; sudo -n chmod 644 /media/root-ro/etc/systemd/system/directory-backup.service"
      ssh "$HOST" "sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/directory-backup.timer' /media/root-ro/etc/systemd/system/directory-backup.timer"
      ssh "$HOST" "sudo -n mkdir -p /media/root-ro/etc/systemd/system/timers.target.wants && sudo -n ln -sfn /etc/systemd/system/directory-backup.timer /media/root-ro/etc/systemd/system/timers.target.wants/directory-backup.timer"
    else
      ssh "$HOST" "set -e; install_user=\$(stat -c %U '$DEPLOY_ROOT'); tmp_unit=\$(mktemp /tmp/directory-backup.service.XXXXXX); sed -e \"s|@INSTALL_USER@|\$install_user|g\" -e \"s|@INSTALL_DIR@|$DEPLOY_ROOT|g\" '$DEPLOY_ROOT/scripts/directory-backup.service' > \"\$tmp_unit\"; sudo -n overlayroot-chroot install -D -m 644 \"\$tmp_unit\" /etc/systemd/system/directory-backup.service; rm -f \"\$tmp_unit\""
      ssh "$HOST" "sudo -n overlayroot-chroot install -D -m 644 '$DEPLOY_ROOT/scripts/directory-backup.timer' /etc/systemd/system/directory-backup.timer"
      ssh "$HOST" "sudo -n overlayroot-chroot mkdir -p /etc/systemd/system/timers.target.wants && sudo -n overlayroot-chroot ln -sfn /etc/systemd/system/directory-backup.timer /etc/systemd/system/timers.target.wants/directory-backup.timer"
    fi
  else
    ssh "$HOST" "set -e; install_user=\$(stat -c %U '$DEPLOY_ROOT'); sed -e \"s|@INSTALL_USER@|\$install_user|g\" -e \"s|@INSTALL_DIR@|$DEPLOY_ROOT|g\" '$DEPLOY_ROOT/scripts/directory-backup.service' | sudo -n tee /etc/systemd/system/directory-backup.service >/dev/null; sudo -n chmod 644 /etc/systemd/system/directory-backup.service"
    ssh "$HOST" "sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/directory-backup.timer' /etc/systemd/system/directory-backup.timer"
    ssh "$HOST" "sudo -n systemctl enable directory-backup.timer"
  fi
  ssh "$HOST" "sudo -n systemctl daemon-reload && sudo -n systemctl start directory-backup.timer"
fi

if [[ "$DEPLOY_CLIENT" -eq 1 || "$DEPLOY_SERVER" -eq 1 ]]; then
  echo "==> Installing kiosk-guard on remote..."
  if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
    if [[ "$LOWERDIR_DIRECT_WRITE" -eq 1 ]]; then
      ssh "$HOST" "sudo -n install -D -m 755 '$DEPLOY_ROOT/scripts/kiosk-guard' /media/root-ro/usr/local/sbin/kiosk-guard"
      ssh "$HOST" "sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/kiosk-guard.service' /media/root-ro/etc/systemd/system/kiosk-guard.service"
      ssh "$HOST" "sudo -n mkdir -p /media/root-ro/etc/systemd/system/multi-user.target.wants && sudo -n ln -sfn /etc/systemd/system/kiosk-guard.service /media/root-ro/etc/systemd/system/multi-user.target.wants/kiosk-guard.service"
    else
      ssh "$HOST" "sudo -n overlayroot-chroot install -D -m 755 '$DEPLOY_ROOT/scripts/kiosk-guard' /usr/local/sbin/kiosk-guard"
      ssh "$HOST" "sudo -n overlayroot-chroot install -D -m 644 '$DEPLOY_ROOT/scripts/kiosk-guard.service' /etc/systemd/system/kiosk-guard.service"
      ssh "$HOST" "sudo -n overlayroot-chroot mkdir -p /etc/systemd/system/multi-user.target.wants && sudo -n overlayroot-chroot ln -sfn /etc/systemd/system/kiosk-guard.service /etc/systemd/system/multi-user.target.wants/kiosk-guard.service"
    fi
  else
    ssh "$HOST" "sudo -n install -D -m 755 '$DEPLOY_ROOT/scripts/kiosk-guard' /usr/local/sbin/kiosk-guard"
    ssh "$HOST" "sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/kiosk-guard.service' /etc/systemd/system/kiosk-guard.service"
    ssh "$HOST" "sudo -n systemctl enable kiosk-guard.service"
  fi
  ssh "$HOST" "sudo -n systemctl daemon-reload && sudo -n systemctl restart kiosk-guard.service"
fi

if [[ "$NO_RESTART" -eq 1 ]]; then
  echo "==> --no-restart set; skipping service restart and health checks."
  echo "Remote deploy complete."
  exit 0
fi

if [[ "$DEPLOY_SERVER" -eq 1 ]]; then
  echo "==> Restarting remote service..."
  if ssh "$HOST" "command -v systemctl >/dev/null 2>&1 && (test -f /etc/systemd/system/directory-server.service || test -f /lib/systemd/system/directory-server.service)"; then
    if ! ssh "$HOST" "sudo -n systemctl restart directory-server"; then
      echo "WARN: non-interactive restart failed. Run on remote host:" >&2
      echo "  sudo systemctl restart directory-server" >&2
      exit 1
    fi
    echo "==> Running remote smoke tests..."
    sleep 2
    ssh "$HOST" "bash -s -- --url http://127.0.0.1:3000 --no-color" < "$SCRIPT_DIR/smoke-test.sh"
  else
    echo "==> No directory-server on remote host (client-only) — skipping restart and smoke tests."
  fi
fi

if [[ "$DEPLOY_CLIENT" -eq 1 ]]; then
  echo "==> Waiting briefly before restarting kiosk session..."
  sleep 3
  echo "==> Restarting remote kiosk session..."
  ssh "$HOST" "bash -lc '
if [[ -x \"$DEPLOY_ROOT/scripts/restart-kiosk.sh\" ]]; then
  \"$DEPLOY_ROOT/scripts/restart-kiosk.sh\"
elif pgrep -x cage >/dev/null 2>&1; then
  pkill -x cage
fi
'"
fi

echo "Remote deploy complete."

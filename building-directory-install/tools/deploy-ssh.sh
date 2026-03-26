#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPUTE_REVISION="$SCRIPT_DIR/compute-revision.sh"
VERIFY_KIOSK_RUNTIME="$SCRIPT_DIR/verify-kiosk-runtime-files.sh"

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
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-${KIOSK_SSH_KEY:-}}"
KNOWN_HOSTS_FILE="${KIOSK_KNOWN_HOSTS_FILE:-/tmp/kiosk_deploy_known_hosts}"
SSH_BASE_ARGS=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
)
if [[ -n "$SSH_IDENTITY_FILE" ]]; then
  SSH_BASE_ARGS+=(-i "$SSH_IDENTITY_FILE")
fi

run_overlay_lowerdir_write() {
  local remote_body="$1"
  ssh "${SSH_BASE_ARGS[@]}" "$HOST" "bash -s -- $(printf '%q' "$remote_body")" <<'REMOTE_SCRIPT'
set -euo pipefail
REMOTE_BODY="${1:-}"
sudo -n mount -o remount,rw /media/root-ro
eval "$REMOTE_BODY"
echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null
REMOTE_SCRIPT
}

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
      --overlay          Force overlay deploy mode
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

if [[ -x "$VERIFY_KIOSK_RUNTIME" ]]; then
  "$VERIFY_KIOSK_RUNTIME"
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
  ssh "${SSH_BASE_ARGS[@]}" "$HOST" "mount | grep -q '^overlayroot on / type overlay'"
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
  REMOTE_MANIFEST="/tmp/building-directory-deploy-manifest-$RANDOM-$(date +%s).txt"
  REVISION_STAGE="$STAGE_DIR/REVISION"
  echo "==> Staging manifest files on remote..."
  ssh "${SSH_BASE_ARGS[@]}" "$HOST" "mkdir -p '$STAGE_DIR'"
  rsync -e "ssh ${SSH_BASE_ARGS[*]}" "${RSYNC_ARGS[@]}" "$SRC_ROOT/" "$HOST:$STAGE_DIR/"
  scp "${SSH_BASE_ARGS[@]}" "$TMP_REVISION" "$HOST:$REVISION_STAGE"
  scp "${SSH_BASE_ARGS[@]}" "$TMP_MANIFEST" "$HOST:$REMOTE_MANIFEST"
  if [[ "$DEPLOY_CLIENT" -eq 1 ]]; then
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sed -i 's|KIOSK_SERVER_URL:-http://.*}|KIOSK_SERVER_URL:-$PATCH_PRIMARY}|; s|KIOSK_SERVER_URL_STANDBY:-http://.*}|KIOSK_SERVER_URL_STANDBY:-$PATCH_STANDBY}|' '$STAGE_DIR/scripts/start-kiosk-lib.sh'"
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "==> Writing files to overlay lower layer..."
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" DEPLOY_ROOT="$DEPLOY_ROOT" STAGE_DIR="$STAGE_DIR" REMOTE_MANIFEST="$REMOTE_MANIFEST" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail
cleanup() {
  rm -rf "$STAGE_DIR" "$REMOTE_MANIFEST"
}
trap cleanup EXIT
sudo -n mount -o remount,rw /media/root-ro
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  src="$STAGE_DIR/$rel"
  dst="/media/root-ro$DEPLOY_ROOT/$rel"
  [[ -f "$src" ]] || { echo "Missing staged file: $src" >&2; exit 1; }
  mode=$(stat -c %a "$src")
  sudo -n install -D -m "$mode" "$src" "$dst"
done < "$REMOTE_MANIFEST"
sudo -n install -D -m 644 "$STAGE_DIR/REVISION" "/media/root-ro$DEPLOY_ROOT/REVISION"
echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null
REMOTE_SCRIPT
    LOWERDIR_DIRECT_WRITE=1
  else
    echo "==> [dry-run] Overlay lower-layer write step skipped."
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "rm -rf '$STAGE_DIR' '$REMOTE_MANIFEST'" || true
  fi
else
  echo "Overlay deploy mode: disabled"
  echo "==> Syncing manifest files..."
  rsync -e "ssh ${SSH_BASE_ARGS[*]}" "${RSYNC_ARGS[@]}" "$SRC_ROOT/" "$HOST:$DEPLOY_ROOT/"
  scp "${SSH_BASE_ARGS[@]}" "$TMP_REVISION" "$HOST:$DEPLOY_ROOT/REVISION"
  if [[ "$DEPLOY_CLIENT" -eq 1 ]]; then
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sed -i 's|KIOSK_SERVER_URL:-http://.*}|KIOSK_SERVER_URL:-$PATCH_PRIMARY}|; s|KIOSK_SERVER_URL_STANDBY:-http://.*}|KIOSK_SERVER_URL_STANDBY:-$PATCH_STANDBY}|' '$DEPLOY_ROOT/scripts/start-kiosk-lib.sh'"
  fi
fi

if [[ "$WITH_DB" -eq 1 ]]; then
  echo "==> Deploying database file..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] Would copy $DB_SOURCE -> $HOST:$DEPLOY_ROOT/server/directory.db (with service stop/start)"
  else
    scp "${SSH_BASE_ARGS[@]}" "$DB_SOURCE" "$HOST:/tmp/directory.db.new"
    if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
      ssh "${SSH_BASE_ARGS[@]}" "$HOST" "set -e; sudo -n systemctl stop directory-server; sudo -n install -D -m 644 /tmp/directory.db.new '/media/root-ro$DEPLOY_ROOT/server/directory.db'; rm -f /tmp/directory.db.new; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null; sudo -n systemctl start directory-server"
    else
      ssh "${SSH_BASE_ARGS[@]}" "$HOST" "set -e; sudo -n systemctl stop directory-server; cp /tmp/directory.db.new '$DEPLOY_ROOT/server/directory.db'; rm -f /tmp/directory.db.new; sudo -n systemctl start directory-server"
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
      ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n overlayroot-chroot bash -lc \"if [[ -f '$DEPLOY_ROOT/server/package-lock.json' ]]; then npm ci --omit=dev --no-audit --no-fund --loglevel=error --prefix '$DEPLOY_ROOT/server'; else npm install --omit=dev --no-audit --no-fund --loglevel=error --prefix '$DEPLOY_ROOT/server'; fi\""
    else
      echo "==> Skipping npm install in overlay mode (OVERLAY_INSTALL_DEPS=0)."
    fi
  else
    echo "==> Normalizing server directory ownership for dependency install..."
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "set -e; if [[ -d '$DEPLOY_ROOT/server/node_modules' ]]; then sudo -n chown -R \$(id -un):\$(id -gn) '$DEPLOY_ROOT/server/node_modules'; fi; sudo -n chown \$(id -un):\$(id -gn) '$DEPLOY_ROOT/server' '$DEPLOY_ROOT/server/package.json' '$DEPLOY_ROOT/server/package-lock.json' 2>/dev/null || true"
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "if ! command -v npm &>/dev/null; then echo 'npm not found — skipping (client-only host)'; elif [[ -f '$DEPLOY_ROOT/server/package-lock.json' ]]; then npm ci --omit=dev --no-audit --no-fund --loglevel=error --prefix '$DEPLOY_ROOT/server'; else npm install --omit=dev --no-audit --no-fund --loglevel=error --prefix '$DEPLOY_ROOT/server'; fi"
  fi
  echo "==> Installing nginx tmpfiles rule on remote..."
  if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
    run_overlay_lowerdir_write "sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/nginx-log-tmpfiles.conf' /media/root-ro/etc/tmpfiles.d/nginx-log-tmpfiles.conf; if [[ -d /media/root-ro/home/kiosk ]]; then sudo -n chmod 711 /media/root-ro/home/kiosk; fi"
  else
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/nginx-log-tmpfiles.conf' /etc/tmpfiles.d/nginx-log-tmpfiles.conf; if [[ -d /home/kiosk ]]; then sudo -n chmod 711 /home/kiosk; fi"
  fi
  ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n systemd-tmpfiles --create /etc/tmpfiles.d/nginx-log-tmpfiles.conf || true"
  echo "==> Installing persist-upload helper on remote..."
  if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
    run_overlay_lowerdir_write "sudo -n install -D -m 755 '$DEPLOY_ROOT/server/persist-upload.sh' /media/root-ro/usr/local/bin/persist-upload.sh"
  else
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n install -m 755 '$DEPLOY_ROOT/server/persist-upload.sh' /usr/local/bin/persist-upload.sh"
  fi

HAS_DIRECTORY_SERVER=0
if ssh "${SSH_BASE_ARGS[@]}" "$HOST" "command -v systemctl >/dev/null 2>&1 && (test -f /etc/systemd/system/directory-server.service || test -f /lib/systemd/system/directory-server.service)"; then
  HAS_DIRECTORY_SERVER=1
fi

if [[ "$HAS_DIRECTORY_SERVER" -eq 1 ]]; then
  echo "==> Installing backup timer units on remote..."
  if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
    run_overlay_lowerdir_write "install_user=\$(stat -c %U '$DEPLOY_ROOT'); sed -e \"s|@INSTALL_USER@|\$install_user|g\" -e \"s|@INSTALL_DIR@|$DEPLOY_ROOT|g\" '$DEPLOY_ROOT/scripts/directory-backup.service' | sudo -n tee /media/root-ro/etc/systemd/system/directory-backup.service >/dev/null; sudo -n chmod 644 /media/root-ro/etc/systemd/system/directory-backup.service; sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/directory-backup.timer' /media/root-ro/etc/systemd/system/directory-backup.timer; sudo -n mkdir -p /media/root-ro/etc/systemd/system/timers.target.wants; sudo -n ln -sfn /etc/systemd/system/directory-backup.timer /media/root-ro/etc/systemd/system/timers.target.wants/directory-backup.timer"
  else
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "set -e; install_user=\$(stat -c %U '$DEPLOY_ROOT'); sed -e \"s|@INSTALL_USER@|\$install_user|g\" -e \"s|@INSTALL_DIR@|$DEPLOY_ROOT|g\" '$DEPLOY_ROOT/scripts/directory-backup.service' | sudo -n tee /etc/systemd/system/directory-backup.service >/dev/null; sudo -n chmod 644 /etc/systemd/system/directory-backup.service"
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/directory-backup.timer' /etc/systemd/system/directory-backup.timer"
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n systemctl enable directory-backup.timer"
  fi
  ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n systemctl daemon-reload && sudo -n systemctl start directory-backup.timer"
else
  echo "==> Client-only host detected; ensuring backup timer is disabled."
  ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n systemctl disable --now directory-backup.timer directory-backup.service >/dev/null 2>&1 || true"
fi
fi

if [[ "$DEPLOY_CLIENT" -eq 1 || "$DEPLOY_SERVER" -eq 1 ]]; then
  echo "==> Installing kiosk-guard on remote..."
  if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
    run_overlay_lowerdir_write "sudo -n install -D -m 755 '$DEPLOY_ROOT/scripts/kiosk-guard' /media/root-ro/usr/local/sbin/kiosk-guard; sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/kiosk-guard.service' /media/root-ro/etc/systemd/system/kiosk-guard.service; sudo -n mkdir -p /media/root-ro/etc/systemd/system/multi-user.target.wants; sudo -n ln -sfn /etc/systemd/system/kiosk-guard.service /media/root-ro/etc/systemd/system/multi-user.target.wants/kiosk-guard.service"
  else
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n install -D -m 755 '$DEPLOY_ROOT/scripts/kiosk-guard' /usr/local/sbin/kiosk-guard"
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/kiosk-guard.service' /etc/systemd/system/kiosk-guard.service"
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n systemctl enable kiosk-guard.service"
  fi
  ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n systemctl daemon-reload && sudo -n systemctl restart kiosk-guard.service"
fi

if [[ "$DEPLOY_CLIENT" -eq 1 ]]; then
  echo "==> Applying client-only host configuration..."
  CLIENT_EXTRA_LOWERDIR_CMD="sudo -n rm -f /media/root-ro/etc/udev/rules.d/99-elo-touch-calibration.rules"
  CLIENT_EXTRA_LIVE_CMD="sudo -n rm -f /etc/udev/rules.d/99-elo-touch-calibration.rules"
  if [[ "$HOST_IP" == "192.168.1.82" ]]; then
    CLIENT_EXTRA_LOWERDIR_CMD="sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/99-elo-touch-calibration-82.rules' /media/root-ro/etc/udev/rules.d/99-elo-touch-calibration.rules"
    CLIENT_EXTRA_LIVE_CMD="sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/99-elo-touch-calibration-82.rules' /etc/udev/rules.d/99-elo-touch-calibration.rules"
  fi
  if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
    run_overlay_lowerdir_write "sudo -n rm -f /media/root-ro/etc/systemd/system/directory-backup.service /media/root-ro/etc/systemd/system/directory-backup.timer /media/root-ro/etc/systemd/system/timers.target.wants/directory-backup.timer; sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/kiosk-blacklist-wireless.conf' /media/root-ro/etc/modprobe.d/kiosk-blacklist-wireless.conf; sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/bash_profile' /media/root-ro/home/kiosk/.bash_profile; $CLIENT_EXTRA_LOWERDIR_CMD; sudo -n mkdir -p /media/root-ro/etc/systemd/user; sudo -n ln -sfn /dev/null /media/root-ro/etc/systemd/user/pulseaudio.service; sudo -n ln -sfn /dev/null /media/root-ro/etc/systemd/user/pulseaudio.socket; if grep -Eq '^[^#[:space:]]+[[:space:]]+/var/log[[:space:]]+tmpfs[[:space:]]' /media/root-ro/etc/fstab 2>/dev/null; then sudo -n sed -i 's|^[^#[:space:]]\\+[[:space:]]\\+/var/log[[:space:]]\\+tmpfs[[:space:]].*|tmpfs /var/log tmpfs defaults,noatime,mode=0755,size=100m 0 0|' /media/root-ro/etc/fstab; else printf '%s\n' 'tmpfs /var/log tmpfs defaults,noatime,mode=0755,size=100m 0 0 # overlayroot:fs-virtual' | sudo -n tee -a /media/root-ro/etc/fstab >/dev/null; fi"
  else
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n rm -f /etc/systemd/system/directory-backup.service /etc/systemd/system/directory-backup.timer /etc/systemd/system/timers.target.wants/directory-backup.timer; sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/kiosk-blacklist-wireless.conf' /etc/modprobe.d/kiosk-blacklist-wireless.conf; sudo -n install -D -m 644 '$DEPLOY_ROOT/scripts/bash_profile' /home/kiosk/.bash_profile; $CLIENT_EXTRA_LIVE_CMD; sudo -n mkdir -p /etc/systemd/user; sudo -n ln -sfn /dev/null /etc/systemd/user/pulseaudio.service; sudo -n ln -sfn /dev/null /etc/systemd/user/pulseaudio.socket; if grep -Eq '^[^#[:space:]]+[[:space:]]+/var/log[[:space:]]+tmpfs[[:space:]]' /etc/fstab 2>/dev/null; then sudo -n sed -i 's|^[^#[:space:]]\\+[[:space:]]\\+/var/log[[:space:]]\\+tmpfs[[:space:]].*|tmpfs /var/log tmpfs defaults,noatime,mode=0755,size=100m 0 0|' /etc/fstab; else printf '%s\n' 'tmpfs /var/log tmpfs defaults,noatime,mode=0755,size=100m 0 0 # overlayroot:fs-virtual' | sudo -n tee -a /etc/fstab >/dev/null; fi; sudo -n udevadm control --reload-rules; sudo -n udevadm trigger --action=change /dev/input/event* >/dev/null 2>&1 || true"
  fi
  ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n systemctl disable --now directory-backup.timer directory-backup.service >/dev/null 2>&1 || true; systemctl --user disable --now pulseaudio.socket pulseaudio.service >/dev/null 2>&1 || true; systemctl --user reset-failed pulseaudio.socket pulseaudio.service >/dev/null 2>&1 || true; sudo -n systemctl daemon-reload"
fi

if [[ "$NO_RESTART" -eq 1 ]]; then
  echo "==> --no-restart set; skipping service restart and health checks."
  echo "Remote deploy complete."
  exit 0
fi

if [[ "$DEPLOY_SERVER" -eq 1 ]]; then
  echo "==> Restarting remote service..."
  ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n systemctl restart nginx || true"
  if ssh "${SSH_BASE_ARGS[@]}" "$HOST" "command -v systemctl >/dev/null 2>&1 && (test -f /etc/systemd/system/directory-server.service || test -f /lib/systemd/system/directory-server.service)"; then
    if ! ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n systemctl restart directory-server"; then
      echo "WARN: non-interactive restart failed. Run on remote host:" >&2
      echo "  sudo systemctl restart directory-server" >&2
      exit 1
    fi
    echo "==> Running remote smoke tests..."
    sleep 2
    ssh "${SSH_BASE_ARGS[@]}" "$HOST" "bash -s -- --url http://127.0.0.1:3000 --no-color" < "$SCRIPT_DIR/smoke-test.sh"
  else
    echo "==> No directory-server on remote host (client-only) — skipping restart and smoke tests."
  fi
fi

if [[ "$EFFECTIVE_OVERLAY" -eq 1 ]]; then
  echo "==> Rebooting remote host to restore clean overlay state..."
  ssh "${SSH_BASE_ARGS[@]}" "$HOST" "sudo -n reboot" || true
  echo "Remote deploy complete (reboot initiated)."
  exit 0
fi

if [[ "$DEPLOY_CLIENT" -eq 1 ]]; then
  echo "==> Waiting briefly before restarting kiosk session..."
  sleep 3
  echo "==> Restarting remote kiosk session..."
  ssh "${SSH_BASE_ARGS[@]}" "$HOST" "bash -lc '
if [[ -x \"$DEPLOY_ROOT/scripts/restart-kiosk.sh\" ]]; then
  \"$DEPLOY_ROOT/scripts/restart-kiosk.sh\"
elif pgrep -x cage >/dev/null 2>&1; then
  pkill -x cage
fi
'"
fi

echo "Remote deploy complete."

#!/usr/bin/env bash
set -euo pipefail

PRIMARY_HOST="${PRIMARY_HOST:-kiosk@192.168.1.80}"
STANDBY_HOST="${STANDBY_HOST:-kiosk@192.168.1.81}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/home/kiosk/building-directory}"
PRIMARY_DB="${PRIMARY_DB:-$DEPLOY_ROOT/server/directory.db}"
STANDBY_DB="${STANDBY_DB:-$DEPLOY_ROOT/server/directory.db}"
SERVICE_NAME="${SERVICE_NAME:-directory-server}"
KEEP_REMOTE_BACKUP="${KEEP_REMOTE_BACKUP:-0}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: tools/sync-standby-db.sh [options]

Create a consistent SQLite backup on the primary host and restore it to the
standby host, then restart the standby service and verify counts.

Options:
  -p, --primary <user@host>   Primary host (default: kiosk@192.168.1.80)
  -s, --standby <user@host>   Standby host (default: kiosk@192.168.1.81)
  -r, --deploy-root <path>    Deploy root (default: /home/kiosk/building-directory)
      --primary-db <path>     Primary DB path (default: <deploy-root>/server/directory.db)
      --standby-db <path>     Standby DB path (default: <deploy-root>/server/directory.db)
      --service <name>        Standby systemd service (default: directory-server)
  -n, --dry-run               Print actions only
  -h, --help                  Show help

Environment overrides:
  PRIMARY_HOST, STANDBY_HOST, DEPLOY_ROOT, PRIMARY_DB, STANDBY_DB,
  SERVICE_NAME, KEEP_REMOTE_BACKUP (0|1)

Requirements:
  - SSH access to both hosts
  - sqlite3 installed on primary + standby
  - passwordless sudo for restarting standby service
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
    -p|--primary)
      PRIMARY_HOST="${2:-}"
      shift 2
      ;;
    -s|--standby)
      STANDBY_HOST="${2:-}"
      shift 2
      ;;
    -r|--deploy-root)
      DEPLOY_ROOT="${2:-}"
      PRIMARY_DB="$DEPLOY_ROOT/server/directory.db"
      STANDBY_DB="$DEPLOY_ROOT/server/directory.db"
      shift 2
      ;;
    --primary-db)
      PRIMARY_DB="${2:-}"
      shift 2
      ;;
    --standby-db)
      STANDBY_DB="${2:-}"
      shift 2
      ;;
    --service)
      SERVICE_NAME="${2:-}"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN=1
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

if [[ -z "$PRIMARY_HOST" || -z "$STANDBY_HOST" ]]; then
  echo "Primary and standby hosts must be set." >&2
  exit 2
fi

ts="$(date +%Y%m%d-%H%M%S)"
remote_backup="/tmp/directory-standby-sync-${ts}.sqlite"
local_backup="$(mktemp /tmp/directory-standby-sync-${ts}.XXXXXX.sqlite)"

cleanup() {
  rm -f "$local_backup"
  if [[ "$KEEP_REMOTE_BACKUP" -ne 1 ]]; then
    ssh "$PRIMARY_HOST" "rm -f '$remote_backup'" >/dev/null 2>&1 || true
    ssh "$STANDBY_HOST" "rm -f '$remote_backup'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Primary: $PRIMARY_HOST ($PRIMARY_DB)"
echo "Standby: $STANDBY_HOST ($STANDBY_DB)"
[[ "$DRY_RUN" -eq 1 ]] && echo "Mode: dry-run"

echo "==> Checking SSH connectivity..."
run_cmd ssh "$PRIMARY_HOST" "true"
run_cmd ssh "$STANDBY_HOST" "true"

echo "==> Creating consistent backup on primary..."
run_cmd ssh "$PRIMARY_HOST" "set -e; test -f '$PRIMARY_DB'; sqlite3 '$PRIMARY_DB' \".backup '$remote_backup'\"; test -s '$remote_backup'"

echo "==> Copying backup primary -> local..."
run_cmd scp "$PRIMARY_HOST:$remote_backup" "$local_backup"

echo "==> Copying backup local -> standby..."
run_cmd scp "$local_backup" "$STANDBY_HOST:$remote_backup"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> [dry-run] Standby stop/restore/start/verify skipped."
  echo "Standby DB sync preview complete."
  exit 0
fi

echo "==> Restoring backup on standby..."
ssh "$STANDBY_HOST" "set -e
  test -s '$remote_backup'
  test -f '$STANDBY_DB'
  sqlite3 '$remote_backup' 'PRAGMA schema_version;' >/dev/null
  sudo -n systemctl stop '$SERVICE_NAME'
  cp '$STANDBY_DB' '${STANDBY_DB}.pre-sync-${ts}'
  cp '$remote_backup' '$STANDBY_DB'
  sudo -n systemctl start '$SERVICE_NAME'
"

echo "==> Verifying row counts + data version..."
primary_stats="$(ssh "$PRIMARY_HOST" "sqlite3 '$PRIMARY_DB' \"select (select count(*) from companies),(select count(*) from individuals),(select value from settings where key='data_version');\"")"
standby_stats="$(ssh "$STANDBY_HOST" "sqlite3 '$STANDBY_DB' \"select (select count(*) from companies),(select count(*) from individuals),(select value from settings where key='data_version');\"")"

echo "Primary stats : $primary_stats"
echo "Standby stats : $standby_stats"

if [[ "$primary_stats" != "$standby_stats" ]]; then
  echo "WARNING: primary/standby stats differ. Check data consistency." >&2
  exit 1
fi

echo "Standby DB sync complete."

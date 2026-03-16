#!/usr/bin/env bash
set -euo pipefail

PRIMARY_HOST="${PRIMARY_HOST:-kiosk@192.168.1.80}"
STANDBY_HOST="${STANDBY_HOST:-kiosk@192.168.1.81}"
PRIMARY_DB="${PRIMARY_DB:-/home/kiosk/building-directory/server/directory.db}"
LOCAL_DB="${LOCAL_DB:-/home/security/building-directory/server/directory.db}"
STANDBY_DB="${STANDBY_DB:-/home/kiosk/building-directory/server/directory.db}"
LOCAL_SERVICE_NAME="${LOCAL_SERVICE_NAME:-directory-server}"
STANDBY_SERVICE_NAME="${STANDBY_SERVICE_NAME:-directory-server}"
KEEP_REMOTE_BACKUP="${KEEP_REMOTE_BACKUP:-0}"
SKIP_LOCAL=0
SKIP_STANDBY=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: tools/sync-primary-db.sh [options]

Create a consistent SQLite backup on the primary host and restore it into:
  1. the local development runtime database
  2. the standby host database

Default topology:
  primary  = kiosk@192.168.1.80
  local    = /home/security/building-directory/server/directory.db
  standby  = kiosk@192.168.1.81

Options:
  -p, --primary <user@host>      Primary host (default: kiosk@192.168.1.80)
  -s, --standby <user@host>      Standby host (default: kiosk@192.168.1.81)
      --primary-db <path>        Primary DB path
      --local-db <path>          Local development DB path
      --standby-db <path>        Standby DB path
      --local-service <name>     Local systemd service to restart (default: directory-server)
      --standby-service <name>   Standby systemd service to restart (default: directory-server)
      --skip-local               Do not update the local development DB
      --skip-standby             Do not update the standby DB
  -n, --dry-run                  Print actions only
  -h, --help                     Show help

Environment overrides:
  PRIMARY_HOST, STANDBY_HOST, PRIMARY_DB, LOCAL_DB, STANDBY_DB,
  LOCAL_SERVICE_NAME, STANDBY_SERVICE_NAME, KEEP_REMOTE_BACKUP

Requirements:
  - SSH access to the primary host
  - sqlite3 installed on the primary and standby hosts
  - passwordless sudo for restarting services where needed
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
    --primary-db)
      PRIMARY_DB="${2:-}"
      shift 2
      ;;
    --local-db)
      LOCAL_DB="${2:-}"
      shift 2
      ;;
    --standby-db)
      STANDBY_DB="${2:-}"
      shift 2
      ;;
    --local-service)
      LOCAL_SERVICE_NAME="${2:-}"
      shift 2
      ;;
    --standby-service)
      STANDBY_SERVICE_NAME="${2:-}"
      shift 2
      ;;
    --skip-local)
      SKIP_LOCAL=1
      shift
      ;;
    --skip-standby)
      SKIP_STANDBY=1
      shift
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

if [[ "$SKIP_LOCAL" -eq 1 && "$SKIP_STANDBY" -eq 1 ]]; then
  echo "Nothing to do: both --skip-local and --skip-standby were set." >&2
  exit 2
fi

if [[ "$SKIP_LOCAL" -eq 0 ]]; then
  local_db_dir="$(dirname "$LOCAL_DB")"
  if [[ ! -d "$local_db_dir" ]]; then
    echo "Missing local deployed runtime: $local_db_dir" >&2
    echo "Run ./tools/deploy-local.sh --full first, then restart the local service." >&2
    exit 1
  fi
  if [[ ! -f "$LOCAL_DB" ]]; then
    echo "Missing local development DB: $LOCAL_DB" >&2
    echo "Run ./tools/deploy-local.sh --full first, then restart the local service." >&2
    exit 1
  fi
fi

ts="$(date +%Y%m%d-%H%M%S)"
remote_backup="/tmp/directory-primary-sync-${ts}.sqlite"
local_backup="$(mktemp /tmp/directory-primary-sync-${ts}.XXXXXX.sqlite)"

cleanup() {
  rm -f "$local_backup"
  if [[ "$KEEP_REMOTE_BACKUP" -ne 1 ]]; then
    ssh "$PRIMARY_HOST" "rm -f '$remote_backup'" >/dev/null 2>&1 || true
    if [[ "$SKIP_STANDBY" -ne 1 ]]; then
      ssh "$STANDBY_HOST" "rm -f '$remote_backup'" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

echo "Primary source : $PRIMARY_HOST ($PRIMARY_DB)"
if [[ "$SKIP_LOCAL" -eq 0 ]]; then
  echo "Local target   : $LOCAL_DB"
fi
if [[ "$SKIP_STANDBY" -eq 0 ]]; then
  echo "Standby target : $STANDBY_HOST ($STANDBY_DB)"
fi
[[ "$DRY_RUN" -eq 1 ]] && echo "Mode: dry-run"

echo "==> Checking primary SSH connectivity..."
run_cmd ssh "$PRIMARY_HOST" "true"

if [[ "$SKIP_STANDBY" -eq 0 ]]; then
  echo "==> Checking standby SSH connectivity..."
  run_cmd ssh "$STANDBY_HOST" "true"
fi

echo "==> Creating consistent backup on primary..."
run_cmd ssh "$PRIMARY_HOST" "set -e; test -f '$PRIMARY_DB'; sqlite3 '$PRIMARY_DB' \".backup '$remote_backup'\"; test -s '$remote_backup'"

echo "==> Copying backup primary -> local temp..."
run_cmd scp "$PRIMARY_HOST:$remote_backup" "$local_backup"

if [[ "$SKIP_STANDBY" -eq 0 ]]; then
  echo "==> Copying backup local temp -> standby..."
  run_cmd scp "$local_backup" "$STANDBY_HOST:$remote_backup"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> [dry-run] Restore steps skipped."
  echo "Primary DB sync preview complete."
  exit 0
fi

if [[ "$SKIP_LOCAL" -eq 0 ]]; then
  echo "==> Restoring backup into local development DB..."
  test -s "$local_backup"
  test -f "$LOCAL_DB"
  sqlite3 "$local_backup" 'PRAGMA schema_version;' >/dev/null
  if command -v systemctl >/dev/null 2>&1 && { [[ -f /etc/systemd/system/${LOCAL_SERVICE_NAME}.service ]] || [[ -f /lib/systemd/system/${LOCAL_SERVICE_NAME}.service ]]; }; then
    sudo -n systemctl stop "$LOCAL_SERVICE_NAME"
    cp "$LOCAL_DB" "${LOCAL_DB}.pre-sync-${ts}"
    cp "$local_backup" "$LOCAL_DB"
    sudo -n systemctl start "$LOCAL_SERVICE_NAME"
  else
    cp "$LOCAL_DB" "${LOCAL_DB}.pre-sync-${ts}"
    cp "$local_backup" "$LOCAL_DB"
  fi
fi

if [[ "$SKIP_STANDBY" -eq 0 ]]; then
  echo "==> Restoring backup on standby..."
  ssh "$STANDBY_HOST" "set -e
    test -s '$remote_backup'
    test -f '$STANDBY_DB'
    sqlite3 '$remote_backup' 'PRAGMA schema_version;' >/dev/null
    sudo -n systemctl stop '$STANDBY_SERVICE_NAME'
    cp '$STANDBY_DB' '${STANDBY_DB}.pre-sync-${ts}'
    cp '$remote_backup' '$STANDBY_DB'
    sudo -n systemctl start '$STANDBY_SERVICE_NAME'
  "
fi

echo "==> Verifying row counts + data version..."
primary_stats="$(ssh "$PRIMARY_HOST" "sqlite3 '$PRIMARY_DB' \"select (select count(*) from companies),(select count(*) from individuals),(select value from settings where key='data_version');\"")"

if [[ "$SKIP_LOCAL" -eq 0 ]]; then
  local_stats="$(sqlite3 "$LOCAL_DB" "select (select count(*) from companies),(select count(*) from individuals),(select value from settings where key='data_version');")"
  echo "Primary stats : $primary_stats"
  echo "Local stats   : $local_stats"
  if [[ "$primary_stats" != "$local_stats" ]]; then
    echo "WARNING: primary/local stats differ. Check local restore consistency." >&2
    exit 1
  fi
else
  echo "Primary stats : $primary_stats"
fi

if [[ "$SKIP_STANDBY" -eq 0 ]]; then
  standby_stats="$(ssh "$STANDBY_HOST" "sqlite3 '$STANDBY_DB' \"select (select count(*) from companies),(select count(*) from individuals),(select value from settings where key='data_version');\"")"
  echo "Standby stats : $standby_stats"
  if [[ "$primary_stats" != "$standby_stats" ]]; then
    echo "WARNING: primary/standby stats differ. Check standby restore consistency." >&2
    exit 1
  fi
fi

echo "Primary DB sync complete."

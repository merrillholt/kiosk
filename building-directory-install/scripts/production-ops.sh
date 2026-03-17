#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR%/scripts}"
SERVER_DIR="$DEPLOY_ROOT/server"
DB_LINK="${DB_LINK:-$SERVER_DIR/directory.db}"
DB_FILE="$(readlink -f "$DB_LINK" 2>/dev/null || true)"
REVISION_FILE="$DEPLOY_ROOT/REVISION"
API_URL="${API_URL:-http://127.0.0.1:3000}"
SERVICE_NAME="${SERVICE_NAME:-directory-server}"

usage() {
    cat <<'USAGE'
Usage: scripts/production-ops.sh <command>

Commands:
  status            Show local production health and storage state
  restart-server    Restart the directory-server service
  restart-kiosk     Restart the kiosk session
  backup            Run the production-local DB backup script
  restore <file>    Restore the DB from a local backup file
USAGE
}

require_arg() {
    if [[ $# -lt 1 ]]; then
        usage >&2
        exit 2
    fi
}

cmd_status() {
    echo "deploy_root=$DEPLOY_ROOT"
    if [[ -f "$REVISION_FILE" ]]; then
        echo "revision=$(cat "$REVISION_FILE")"
    else
        echo "revision=missing"
    fi
    echo "service=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
    echo "db_link=$DB_LINK"
    echo "db_file=${DB_FILE:-missing}"
    if [[ -n "${DB_FILE:-}" && -f "$DB_FILE" ]]; then
        echo "db_exists=yes"
        echo "db_mount=$(df -P "$DB_FILE" | awk 'NR==2 {print $6}')"
    else
        echo "db_exists=no"
    fi
    echo -n "api_revision="
    curl -fsS "$API_URL/api/revision" 2>/dev/null || echo "unreachable"
    echo -n "api_data_version="
    curl -fsS "$API_URL/api/data-version" 2>/dev/null || echo "unreachable"
    echo "kiosk_cage=$(pgrep -x cage >/dev/null 2>&1 && echo active || echo inactive)"
    echo "kiosk_chromium=$(pgrep -x chromium >/dev/null 2>&1 && echo active || echo inactive)"
}

cmd_restart_server() {
    sudo -n systemctl restart "$SERVICE_NAME"
}

cmd_restart_kiosk() {
    "$SCRIPT_DIR/restart-kiosk.sh"
}

cmd_backup() {
    "$SCRIPT_DIR/backup.sh"
}

cmd_restore() {
    local backup_file="$1"
    "$SCRIPT_DIR/restore-db.sh" "$backup_file"
}

require_arg "$@"
command="$1"
shift

case "$command" in
    status)
        cmd_status
        ;;
    restart-server)
        cmd_restart_server
        ;;
    restart-kiosk)
        cmd_restart_kiosk
        ;;
    backup)
        cmd_backup
        ;;
    restore)
        if [[ $# -ne 1 ]]; then
            usage >&2
            exit 2
        fi
        cmd_restore "$1"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "Unknown command: $command" >&2
        usage >&2
        exit 2
        ;;
esac

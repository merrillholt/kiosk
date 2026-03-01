#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="${SCRIPT_DIR%/scripts}/server"

if [[ ! -d "$SERVER_DIR" ]]; then
    echo "Server directory not found: $SERVER_DIR" >&2
    exit 1
fi

cd "$SERVER_DIR"

if [[ -z "${KIOSK_ADMIN_PASSWORD:-}" ]]; then
    echo "KIOSK_ADMIN_PASSWORD not set; using server default password."
fi

exec npm start

#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
START_SCRIPT="$SCRIPT_DIR/start-server.sh"

if [[ ! -x "$START_SCRIPT" ]]; then
    echo "Start script not found or not executable: $START_SCRIPT" >&2
    exit 1
fi

PIDS="$(pgrep -f 'node server.js' || true)"
if [[ -n "$PIDS" ]]; then
    echo "Stopping existing server process(es): $PIDS"
    kill $PIDS
    sleep 1
fi

exec "$START_SCRIPT"

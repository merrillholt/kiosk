#!/usr/bin/env bash
set -euo pipefail

UNIT_PATH="/etc/systemd/system/directory-server.service"

if [[ ! -f "$UNIT_PATH" ]]; then
    echo "Unit file not found: $UNIT_PATH" >&2
    exit 1
fi

tmp_file="$(mktemp)"
cleanup() {
    rm -f "$tmp_file"
}
trap cleanup EXIT

sed \
    -e '/^[[:space:]]*StandardOutput=syslog[[:space:]]*$/d' \
    -e '/^[[:space:]]*StandardError=syslog[[:space:]]*$/d' \
    "$UNIT_PATH" > "$tmp_file"

if cmp -s "$UNIT_PATH" "$tmp_file"; then
    echo "No obsolete syslog settings found in $UNIT_PATH"
    exit 0
fi

sudo cp "$UNIT_PATH" "$UNIT_PATH.bak.$(date +%Y%m%d%H%M%S)"
sudo install -m 644 "$tmp_file" "$UNIT_PATH"
sudo systemctl daemon-reload
sudo systemctl restart directory-server

echo "Updated $UNIT_PATH"
echo "Removed obsolete StandardOutput/StandardError syslog settings and restarted directory-server."

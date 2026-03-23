#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

sync_file() {
  local src_rel="$1"
  local dst_rel="$2"
  local src="$ROOT_DIR/$src_rel"
  local dst="$ROOT_DIR/$dst_rel"

  if [[ ! -f "$src" ]]; then
    echo "Missing source file: $src_rel" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}

while read -r src_rel dst_rel; do
  [[ -z "${src_rel:-}" ]] && continue
  sync_file "$src_rel" "$dst_rel"
done <<'EOF'
scripts/start-kiosk.sh building-directory-install/scripts/start-kiosk.sh
scripts/start-kiosk-lib.sh building-directory-install/scripts/start-kiosk-lib.sh
scripts/restart-kiosk.sh building-directory-install/scripts/restart-kiosk.sh
scripts/kiosk-guard building-directory-install/scripts/kiosk-guard
scripts/kiosk-guard.service building-directory-install/scripts/kiosk-guard.service
scripts/bash_profile building-directory-install/scripts/bash_profile
scripts/kiosk-keyboard-added.sh building-directory-install/scripts/kiosk-keyboard-added.sh
scripts/99-kiosk-keyboard.rules building-directory-install/scripts/99-kiosk-keyboard.rules
scripts/99-elo-usb-power.rules building-directory-install/scripts/99-elo-usb-power.rules
scripts/80-kiosk-power-button.conf building-directory-install/scripts/80-kiosk-power-button.conf
scripts/kiosk-blacklist-wireless.conf building-directory-install/scripts/kiosk-blacklist-wireless.conf
scripts/kioskctl building-directory-install/scripts/kioskctl
scripts/production-ops.sh building-directory-install/scripts/production-ops.sh
scripts/restart-server.sh building-directory-install/scripts/restart-server.sh
scripts/start-server.sh building-directory-install/scripts/start-server.sh
kiosk-fleet/kioskctl building-directory-install/kiosk-fleet/kioskctl
EOF

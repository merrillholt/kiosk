#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/vendor/elo-mt-usb"
SRC_DIR="${1:-$DEFAULT_SRC_DIR}"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Elo driver source directory not found: $SRC_DIR" >&2
    exit 1
fi

for required in elomtusbd elova cpl cplcmd elo.service eloCreateFifo.sh elorc loadEloMultiTouchUSB.sh 99-elotouch.rules; do
    if [[ ! -e "$SRC_DIR/$required" ]]; then
        echo "Missing Elo driver file: $SRC_DIR/$required" >&2
        exit 1
    fi
done

sudo rm -rf /etc/opt/elo-mt-usb
sudo mkdir -p /etc/opt/elo-mt-usb
sudo cp -a "$SRC_DIR"/. /etc/opt/elo-mt-usb/

sudo find /etc/opt/elo-mt-usb -type f -name '*.txt' -exec chmod 644 {} +
sudo chmod 755 \
    /etc/opt/elo-mt-usb/elomtusbd \
    /etc/opt/elo-mt-usb/elova \
    /etc/opt/elo-mt-usb/cpl \
    /etc/opt/elo-mt-usb/cplcmd \
    /etc/opt/elo-mt-usb/eloCreateFifo.sh \
    /etc/opt/elo-mt-usb/loadEloMultiTouchUSB.sh
sudo chmod 644 \
    /etc/opt/elo-mt-usb/99-elotouch.rules \
    /etc/opt/elo-mt-usb/elo.service \
    /etc/opt/elo-mt-usb/elorc

sudo install -D -m 644 /etc/opt/elo-mt-usb/99-elotouch.rules /etc/udev/rules.d/99-elotouch.rules
echo uinput | sudo tee /etc/modules-load.d/uinput.conf > /dev/null

sudo install -D -m 644 /etc/opt/elo-mt-usb/elo.service /etc/systemd/system/elo.service

sudo modprobe uinput || true
sudo udevadm control --reload-rules
sudo systemctl daemon-reload
sudo systemctl enable elo.service
sudo systemctl restart elo.service

echo "Elo driver installed from $SRC_DIR"
echo "Service: $(sudo systemctl is-active elo.service)"

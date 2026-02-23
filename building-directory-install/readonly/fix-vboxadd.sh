#!/bin/bash
# Fix vboxadd.service failing on read-only root.
#
# VBoxGuestAdditions init script unconditionally tries to write udev rules and
# a log file on every boot.  On an overlayroot system the lower layer is
# read-only, so the writes fail and the service exits 1.  The modules are
# already compiled and loaded from /lib/modules; no rebuild is needed.
#
# Run this inside overlayroot-chroot:
#   sudo /usr/sbin/overlayroot-chroot bash /run/fix-vboxadd.sh
#
set -e

echo "=== Adding SuccessExitStatus=1 drop-in for vboxadd ==="
mkdir -p /etc/systemd/system/vboxadd.service.d
cat > /etc/systemd/system/vboxadd.service.d/kiosk.conf << 'EOF'
[Unit]
Description=Kiosk vboxadd drop-in

[Service]
# The init script tries to write udev rules and a log file on every boot.
# On a read-only root these writes fail (exit 1).  The modules are already
# built and loaded from the lower layer, so treat exit 1 as success.
SuccessExitStatus=1
EOF

echo "=== Masking anacron (not needed on a kiosk) ==="
systemctl mask anacron.service anacron.timer

echo "=== Adding SuccessExitStatus=1 drop-in for systemd-remount-fs ==="
mkdir -p /etc/systemd/system/systemd-remount-fs.service.d
cat > /etc/systemd/system/systemd-remount-fs.service.d/kiosk.conf << 'EOF'
[Service]
# systemd-remount-fs exits 1 when it cannot reconfigure the overlayfs root
# on read-only (overlayroot) boots.  Treat it as success so it does not
# appear in the failed unit list.  On a plain read-write boot the service
# exits 0 normally.
SuccessExitStatus=1
EOF

echo "=== Done ==="

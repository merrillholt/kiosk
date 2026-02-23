#!/bin/bash
# Build VirtualBox Guest Additions kernel modules on a read-write boot.
#
# The Debian kernel ships its own vboxguest module which reports an older
# interface version to the hypervisor.  To make VirtualBox Manager show the
# correct Guest Additions version, the VBoxGuestAdditions-compiled modules
# must be built and installed into /lib/modules/<kernel>/misc/.
#
# This script must be run on a read-write root (i.e. with overlayroot
# disabled).  Boot procedure:
#   1. At GRUB menu press 'e', append 'overlayroot=disabled' to the linux line,
#      press F10 to boot.
#   2. If / is still read-only (systemd-remount-fs was masked), run:
#        sudo mount -o remount,rw /
#   3. Run this script:
#        sudo bash build-vboxadd-modules.sh
#   4. Reboot normally (overlayroot re-activates).
#
set -e

KERNEL=$(uname -r)
echo "=== Kernel: $KERNEL ==="

echo "=== Installing build dependencies ==="
apt-get install -y linux-headers-${KERNEL} make perl

echo "=== Building VBoxGuestAdditions modules ==="
/sbin/rcvboxadd setup

echo "=== Verifying modules in misc/ ==="
find /lib/modules/${KERNEL}/misc/ -name 'vbox*.ko*'

echo "=== Done — reboot to load the new modules ==="

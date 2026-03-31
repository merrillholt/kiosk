#! /bin/sh

# Create Elo Devices for communication
/etc/opt/elo-mt-usb/eloCreateFifo.sh

# Load the PC speaker kernel module into memory for Beep-On-Touch 
# Disable this module because ARM platform does not support it

platform_arch=`uname -m`

if [ $platform_arch != "aarch64" ] && [ $platform_arch != "armv7l" ]
then
  modprobe pcspkr
fi

# Wait for the Elo USB controller to appear before starting the daemon.
# On some hosts the system boots fast enough that elomtusbd starts before
# 04e7:0020 is fully enumerated, causing the daemon to exit immediately.
elo_wait_timeout=30
elo_wait_count=0

if command -v lsusb >/dev/null 2>&1
then
  while [ $elo_wait_count -lt $elo_wait_timeout ]
  do
    if lsusb -d 04e7:0020 >/dev/null 2>&1
    then
      break
    fi
    sleep 1
    elo_wait_count=$((elo_wait_count + 1))
  done
fi

sleep 1

# Load the Elo USB Touchscreen Daemon into memory
/etc/opt/elo-mt-usb/elomtusbd --stdigitizer

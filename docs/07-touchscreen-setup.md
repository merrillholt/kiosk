# Touchscreen Setup

## Connection Overview

Touchscreens require **two separate connections**:

```
+-------------+                      +-----------------+
|             |  Video (HDMI)        |                 |
|  Mini PC    |  -----------------→  |  Touchscreen    |
|             |                      |    Monitor      |
|             |  ← USB (touch data)  |                 |
+-------------+                      +-----------------+
```

| Cable | Purpose |
|-------|---------|
| HDMI (or DVI-to-HDMI adapter) | Video signal |
| USB | Touch input data |

HDMI does not carry touch data. Touch always requires a separate USB connection.

## Deployed Display: Elo 3239L (ET3239L-8CNA)

| Spec | Value |
|------|-------|
| Model | ET3239L-8CNA-0-D-G |
| Size | 32" |
| Touch | Projected Capacitive (PCAP) |
| USB controller | Elo 2700 (`04e7:0020`) |
| Video input | DVI-I (connected via DVI-to-HDMI adapter) |
| Touch connection | USB-B to host USB-A |

For full driver installation and udev configuration see
`docs/elo-cage-wayland-kiosk-hardening.md`.

## Linux Touch Support

The Elo 3239L uses the **Elo MT USB userspace driver** (`elomtusbd`) rather than
standard kernel HID-only handling. After `elo.service` runs at boot, the kernel
`hid-generic` driver presents the device as an absolute pointer on
`/dev/input/event*`.

### Verify the device is detected

```bash
# USB device present
lsusb | grep -i elo
# Expected: ID 04e7:0020 Elo TouchSystems 2700 IntelliTouch

# Kernel assigned an event node
sudo dmesg | grep -i elo
# Expected: hid-generic ... Pointer [Elo TouchSystems...]

# libinput sees it
sudo libinput list-devices | grep -A5 -i elo
# Expected: Capabilities: pointer
```

### Test touch events

```bash
sudo apt install evtest   # if not already installed
sudo evtest
# Select the Elo event device, then touch the screen
# Expected: ABS_X and ABS_Y coordinate events
```

### Verify Elo driver service

```bash
systemctl is-enabled elo.service    # should print: enabled
lsmod | grep uinput                  # uinput must be loaded
ls /etc/udev/rules.d/99-elotouch.rules
ls /etc/udev/rules.d/99-elo-usb-power.rules
```

## Wayland / Cage Behaviour

The kiosk compositor is **Cage** (Wayland). Touch is delivered to Chromium as
an absolute pointer. No X11 input tools (`xinput`, `xrandr`) apply to the
running kiosk session.

Inspect active Wayland outputs:

```bash
wlr-randr
```

## Troubleshooting

### Touch not detected

```bash
lsusb                           # confirm USB device is present
sudo dmesg | grep -i elo        # look for kernel detection message
systemctl status elo.service    # check driver service
```

### Touch detected but not working in Cage

```bash
# Confirm elomtusbd ran at boot
sudo journalctl -u elo.service --no-pager

# Check uinput is loaded
lsmod | grep uinput

# Test raw events
sudo evtest   # select Elo device, touch screen
```

### Touch freezes after idle

USB autosuspend may be interfering. Confirm the power rule is active:

```bash
cat /sys/bus/usb/devices/*/power/control 2>/dev/null
# Expected: "on" for the Elo device
```

If missing, check `/etc/udev/rules.d/99-elo-usb-power.rules` is present and
re-run `sudo udevadm control --reload-rules && sudo udevadm trigger`.

### Cursor visible after touch

The Elo device is classified as a pointer by libinput. This is expected and
does not affect kiosk operation. If cursor hiding is required, see
`docs/elo-cage-wayland-kiosk-hardening.md` section 3 for the udev conflict fix.

## Calibration

PCAP touchscreens generally do not require calibration. If touch coordinates
are consistently offset:

```bash
sudo libinput list-devices | grep -A20 -i elo
# Check for LIBINPUT_CALIBRATION_MATRIX property
```

To set a calibration matrix via udev (edit `/etc/udev/rules.d/99-elo-touchscreen.rules`):

```udev
SUBSYSTEM=="input", ATTRS{idVendor}=="04e7", ATTRS{idProduct}=="0020", \
  ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0"
```

The identity matrix above is a no-op template. Replace with the correct
transform values. See `docs/elo-cage-wayland-kiosk-hardening.md` section 10.

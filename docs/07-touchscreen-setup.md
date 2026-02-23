# Touchscreen Setup

## Connection Overview

Touchscreens require **two separate connections**:

```
┌─────────────┐                      ┌─────────────────┐
│             │  Video (HDMI/DP/VGA) │                 │
│  Mini PC    │  ─────────────────→  │  Touchscreen    │
│             │                      │    Monitor      │
│             │  ← USB (touch data)  │                 │
└─────────────┘                      └─────────────────┘
```

| Cable | Direction | Purpose |
|-------|-----------|---------|
| HDMI / DisplayPort / VGA | PC → Display | Video signal |
| USB | Bidirectional | Touch input data |

**Important:** VGA, HDMI, and DisplayPort do NOT carry touch data. Touch always requires a separate USB (or serial) connection.

## Video Connection Options

| Type | Quality | Audio | Recommended |
|------|---------|-------|-------------|
| **DisplayPort** | Best | Yes | Yes |
| **HDMI** | Excellent | Yes | Yes |
| VGA | Good (analog) | No | Legacy only |

## Touch Connection Options

| Type | Notes |
|------|-------|
| **USB HID** | Most common, plug-and-play on Linux |
| USB with driver | Some panels need vendor drivers |
| Serial (RS-232) | Older industrial panels |

## Linux Touch Support

Debian/Linux supports most USB touchscreens automatically via:
- `hid-multitouch` driver (multi-touch panels)
- `usb_touchscreen` driver (single-touch panels)

### Verify Touch is Detected

```bash
# List input devices
xinput list

# Example output:
# ⎡ Virtual core pointer
# ⎜   ↳ ELAN Touchscreen          id=10   [slave pointer]

# List event devices
ls -la /dev/input/event*

# Get detailed info
sudo libinput list-devices | grep -A 10 -i touch
```

### Test Touch Events

```bash
# Install evtest
sudo apt install evtest

# Run test (select your touch device)
sudo evtest

# Touch the screen - you should see coordinate events:
# Event: type 3 (EV_ABS), code 0 (ABS_X), value 512
# Event: type 3 (EV_ABS), code 1 (ABS_Y), value 384
```

## Calibration

Most modern touchscreens don't need calibration, but if touch coordinates are off:

### Using xinput_calibrator (X11)

```bash
# Install
sudo apt install xinput-calibrator

# Run calibration
xinput_calibrator

# Follow on-screen instructions (tap the crosshairs)
# Save the output to /etc/X11/xorg.conf.d/99-calibration.conf
```

### Using libinput (modern method)

```bash
# Get device calibration matrix
sudo libinput list-devices | grep -A 20 "Touchscreen"

# Calibration is usually automatic with libinput
# If needed, create /etc/libinput/local-overrides.quirks
```

## Multi-Monitor Touch Mapping

If you have multiple monitors but only one touchscreen, map touch to the correct display:

```bash
# List displays
xrandr

# List touch devices
xinput list

# Map touch device to specific display
xinput map-to-output "ELAN Touchscreen" HDMI-1
```

To make permanent, add to `/home/kiosk/.xinitrc`:

```bash
xinput map-to-output "ELAN Touchscreen" HDMI-1
```

## Troubleshooting

### Touch not detected

```bash
# Check USB devices
lsusb

# Check kernel messages
dmesg | grep -i touch

# Check for input devices
cat /proc/bus/input/devices | grep -A 5 -i touch
```

### Touch detected but not working in Chromium

Ensure touch events are enabled in Chromium:

```bash
chromium --touch-events=enabled --kiosk http://localhost
```

### Touch coordinates inverted or rotated

Create `/etc/X11/xorg.conf.d/99-touch-rotation.conf`:

```
Section "InputClass"
    Identifier "calibration"
    MatchProduct "your touchscreen name"
    Option "TransformationMatrix" "0 1 0 -1 0 1 0 0 1"
EndSection
```

Common transformation matrices:

| Rotation | Matrix |
|----------|--------|
| Normal | `1 0 0 0 1 0 0 0 1` |
| 90° CW | `0 1 0 -1 0 1 0 0 1` |
| 90° CCW | `0 -1 1 1 0 0 0 0 1` |
| 180° | `-1 0 1 0 -1 1 0 0 1` |
| X-inverted | `-1 0 1 0 1 0 0 0 1` |
| Y-inverted | `1 0 0 0 -1 1 0 0 1` |

### Touch works but multi-touch doesn't

Check if the panel supports multi-touch:

```bash
# Look for ABS_MT_POSITION_X in capabilities
sudo evtest
# Select touch device, then check "Supported events"
```

## Recommended Touchscreen Specifications

For kiosk use:

| Feature | Recommendation |
|---------|----------------|
| Touch type | Capacitive (more responsive than resistive) |
| Multi-touch | 10-point (for gestures, though not needed for this app) |
| Interface | USB HID (plug-and-play) |
| Response time | < 10ms |
| Surface | Anti-glare, scratch-resistant |

## VirtualBox Touch Testing

VirtualBox doesn't emulate touchscreens directly, but:

1. Mouse clicks work as single-touch events
2. Chromium in kiosk mode treats clicks as touch
3. For real touch testing, deploy to physical hardware

To test multi-touch in VM, you can pass through a USB touchscreen:

```
VirtualBox → Settings → USB → Add Filter → Select touchscreen
```

## Summary

| Component | Connection | Driver |
|-----------|------------|--------|
| Video | HDMI/DP (preferred) or VGA | Automatic |
| Touch | USB | `hid-multitouch` (automatic) |
| Calibration | Usually not needed | `xinput_calibrator` if required |

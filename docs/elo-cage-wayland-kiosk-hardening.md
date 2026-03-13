# Elo 3239L / Elo 2700 IntelliTouch on Cage + Wayland

This guide is for an Elo 3239L using the Elo 2700 IntelliTouch USB controller:

- USB vendor/product: `04e7:0020`
- Kernel path: `hid-generic` / `usbhid`
- Intended compositor: `cage`
- Intended session type: Wayland

The main issue being addressed is that the touchscreen is exposed as both a touchscreen and a pointer-like device, which can make Cage/libinput show a cursor after the first touch and can produce conflicting input behavior.

---

## 1. Prerequisites

Install the packages used for runtime and verification:

```bash
sudo apt update
sudo apt install cage chromium libinput-tools evtest
```

Notes:

- `cage` runs the kiosk session.
- `chromium` is the example browser kiosk client. Replace it if you use another Wayland-capable browser/app.
- `libinput-tools` provides `libinput list-devices` and `libinput debug-events`.
- `evtest` is useful for low-level event verification.
- You need a seat-management backend. On Debian, this is usually provided by an existing `systemd-logind` login session. If you are launching Cage outside a normal logged-in session, you may need `seatd` instead.

Optional package if you want display/output inspection:

```bash
sudo apt install wlr-randr
```

---

## 2. Confirm the touchscreen is detected correctly

### Kernel detection

```bash
sudo dmesg | grep -i elo
```

Expected pattern:

```text
Elo TouchSystems 2700 IntelliTouch(r) USB Touchmonitor Interface
hid-generic 0003:04E7:0020
```

### libinput detection

```bash
sudo libinput list-devices
```

You want to find the Elo device and verify what capabilities libinput sees.

### Raw event testing

```bash
sudo evtest
```

Select the Elo `event` device and confirm that touch events are produced.

---

## 3. Fix the pointer/touch conflict with a udev rule

This is the core fix.

Create the rule:

```bash
sudo vi /etc/udev/rules.d/99-elo-touchscreen.rules
```

Use this content:

```udev
SUBSYSTEM=="input", ATTRS{idVendor}=="04e7", ATTRS{idProduct}=="0020", ENV{ID_INPUT_MOUSE}="0"
SUBSYSTEM=="input", ATTRS{idVendor}=="04e7", ATTRS{idProduct}=="0020", ENV{ID_INPUT_JOYSTICK}="0"
```

Reload udev and retrigger devices:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Then unplug/replug the touchscreen USB cable, or reboot.

### Why this works

`libinput` uses udev properties such as `ID_INPUT_MOUSE`, `ID_INPUT_TOUCHSCREEN`, and `ID_INPUT_JOYSTICK` to determine the device type. Only one device type should generally be set at a time. Clearing the mouse and joystick tags keeps the Elo device from also being treated as a pointer/joystick-style device.

---

## 4. Verify the fix

Run:

```bash
sudo libinput list-devices
```

For the Elo device, the target state is that it should behave as a touchscreen and no longer present a pointer capability.

Then test events:

```bash
sudo libinput debug-events
```

Touch the screen. You want to see touch events such as:

```text
TOUCH_DOWN
TOUCH_MOTION
TOUCH_UP
```

If pointer events are still shown for the Elo device after reboot/replug, check whether the rule file name is correct and whether the attributes still match `04e7:0020`.

---

## 5. Optional: disable the joystick compatibility module globally

If `/dev/input/js0` keeps appearing and you do not want joystick compatibility anywhere on the system:

```bash
sudo vi /etc/modprobe.d/blacklist-joydev.conf
```

Add:

```text
blacklist joydev
```

Then reboot.

This is optional. The udev rule above is the main fix for the Elo device.

---

## 6. Keep USB autosuspend from interfering with the touchscreen

Touch panels in kiosk systems sometimes become unreliable after idle/power state changes. Force the device power policy to `on`.

Create:

```bash
sudo vi /etc/udev/rules.d/99-elo-usb-power.rules
```

Add:

```udev
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="04e7", ATTR{idProduct}=="0020", TEST=="power/control", ATTR{power/control}="on"
```

Reload rules and retrigger:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Verify:

```bash
cat /sys/bus/usb/devices/*/power/control 2>/dev/null
```

You can also inspect the specific Elo USB path from `udevadm info` if needed.

---

## 7. Cage launch command for kiosk use

A minimal manual test:

```bash
cage -- chromium --kiosk --noerrdialogs --disable-session-crashed-bubble https://example.com
```

If Chromium is not already running natively on Wayland, force it:

```bash
env OZONE_PLATFORM=wayland XDG_SESSION_TYPE=wayland \
  cage -- chromium --ozone-platform=wayland --kiosk --noerrdialogs --disable-session-crashed-bubble https://example.com
```

---

## 8. Suggested systemd user service

Create:

```bash
mkdir -p ~/.config/systemd/user
vi ~/.config/systemd/user/cage-kiosk.service
```

Use:

```ini
[Unit]
Description=Cage kiosk session
After=graphical-session-pre.target
Wants=graphical-session-pre.target

[Service]
Environment=OZONE_PLATFORM=wayland
Environment=XDG_SESSION_TYPE=wayland
ExecStart=/usr/bin/cage -- /usr/bin/chromium --ozone-platform=wayland --kiosk --noerrdialogs --disable-session-crashed-bubble https://example.com
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
```

Enable it:

```bash
systemctl --user daemon-reload
systemctl --user enable --now cage-kiosk.service
```

If you instead launch from a TTY/login shell, adapt the command to your own startup script.

---

## 9. Output mapping and rotation

Many kiosk installations need output rotation or explicit display checking.

Inspect outputs:

```bash
wlr-randr
```

If the display must be rotated, set the output transform using your output-management method. In wlroots-based compositors, output handling is compositor-specific; `wlr-randr` is commonly used for inspection and adjustment on wlroots stacks.

If touch alignment is wrong after rotation, the next step is a `LIBINPUT_CALIBRATION_MATRIX` udev property for the Elo device.

---

## 10. Calibration hook if rotation causes offset

Create or extend the touchscreen rule:

```bash
sudo vi /etc/udev/rules.d/99-elo-touchscreen.rules
```

Example template:

```udev
SUBSYSTEM=="input", ATTRS{idVendor}=="04e7", ATTRS{idProduct}=="0020", ENV{ID_INPUT_MOUSE}="0", ENV{ID_INPUT_JOYSTICK}="0", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0"
```

The identity matrix above does nothing by itself. Replace it only when you have confirmed a specific transform is needed.

After changes:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Then reconnect the device or reboot.

---

## 11. Troubleshooting checklist

### A. Cursor still appears after first touch

1. Re-run:

   ```bash
   sudo libinput list-devices
   ```

2. Confirm the Elo device is not showing pointer capability.
3. Confirm the kiosk app is actually running on Wayland rather than Xwayland when possible.
4. Reboot after changing udev rules.

### B. Touch works in `evtest` but not in Cage

1. Verify Cage is running in a valid seat/logind session.
2. Verify the browser/app supports Wayland correctly.
3. Test with a simpler client if needed:

   ```bash
   cage -- foot
   ```

### C. Touch freezes after idle or overnight

1. Confirm the USB power rule is present.
2. Recheck the device after resume/replug:

   ```bash
   sudo dmesg | grep -i elo
   ```

### D. Device still shows as both touch and pointer

Inspect udev properties directly:

```bash
udevadm info --query=property --name=/dev/input/event3
```

Replace `event3` with the Elo event node on your system.

Look for:

```text
ID_INPUT_TOUCHSCREEN=1
ID_INPUT_MOUSE=0
ID_INPUT_JOYSTICK=0
```

---

## 12. Recommended final state

The stable target state is:

- Kernel driver: `hid-generic`
- Elo device recognized by `libinput`
- Device behaves as a touchscreen, not as a pointer
- No visible cursor generated by touchscreen input
- USB autosuspend disabled for the Elo controller
- Cage started with a native Wayland browser/app

---

## 13. Files created by this guide

```text
/etc/udev/rules.d/99-elo-touchscreen.rules
/etc/udev/rules.d/99-elo-usb-power.rules
/etc/modprobe.d/blacklist-joydev.conf          (optional)
~/.config/systemd/user/cage-kiosk.service      (example)
```

---

## 14. Reference notes

This guide is based on the current libinput documentation for device typing and static udev configuration, the libinput documentation for ignoring/misclassifying devices, and current public Cage/wlroots discussion indicating that cursor hiding in Cage is not a simple built-in toggle, so the clean solution is to stop the Elo device from also being treated as a pointer in the first place.

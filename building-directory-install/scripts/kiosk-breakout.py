#!/usr/bin/env python3
"""
kiosk-breakout.py — watches raw input devices for a breakout key combo
and kills cage when it sees it.

Default combo: Right-Shift + Right-Ctrl (hold both, then press Backspace)

Requires: python3-evdev   (apt install python3-evdev)
Run as:   python3 kiosk-breakout.py [--combo KEY,KEY,KEY]
"""

import sys
import signal
import subprocess
import argparse
import logging
from selectors import DefaultSelector, EVENT_READ

try:
    import evdev
    from evdev import ecodes as e
except ImportError:
    sys.stderr.write("python3-evdev not found. Install with: sudo apt install python3-evdev\n")
    sys.exit(1)

logging.basicConfig(level=logging.WARNING, format='%(levelname)s %(message)s')
log = logging.getLogger('kiosk-breakout')

# ── Default breakout combo ────────────────────────────────────────────────────
# Right-Shift + Right-Ctrl + Backspace
DEFAULT_COMBO = frozenset([e.KEY_RIGHTSHIFT, e.KEY_RIGHTCTRL, e.KEY_BACKSPACE])

def parse_combo(spec):
    """Parse a comma-separated list of evdev key names, e.g. KEY_LEFTCTRL,KEY_LEFTALT,KEY_BACKSPACE"""
    keys = set()
    for name in spec.split(','):
        name = name.strip().upper()
        if not name.startswith('KEY_'):
            name = 'KEY_' + name
        code = getattr(e, name, None)
        if code is None:
            sys.exit(f"Unknown key name: {name}")
        keys.add(code)
    return frozenset(keys)

def open_keyboards():
    """Return InputDevice objects for all keyboards found."""
    keyboards = []
    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
            caps = dev.capabilities()
            # Must have EV_KEY and have at least KEY_A (filters out mice/touchpads)
            if e.EV_KEY in caps and e.KEY_A in caps[e.EV_KEY]:
                keyboards.append(dev)
                log.warning("Watching %s (%s)", path, dev.name)
        except (PermissionError, OSError):
            pass
    return keyboards

def do_breakout():
    log.warning("Breakout combo detected — killing cage")
    subprocess.run(['pkill', '-x', 'cage'], check=False)

def watch(combo):
    keyboards = open_keyboards()
    if not keyboards:
        sys.stderr.write("kiosk-breakout: no keyboard devices found (permission issue?)\n")
        sys.exit(1)

    sel = DefaultSelector()
    for dev in keyboards:
        sel.register(dev, EVENT_READ)

    held = set()

    while True:
        events = sel.select(timeout=5)
        # Re-scan for new keyboards (e.g., USB plugged in) every 5 s if idle
        if not events:
            new_keyboards = open_keyboards()
            for dev in new_keyboards:
                if dev not in keyboards:
                    sel.register(dev, EVENT_READ)
                    keyboards.append(dev)
            continue

        for key, _ in events:
            dev = key.fileobj
            try:
                for event in dev.read():
                    if event.type != e.EV_KEY:
                        continue
                    if event.value == 1:    # key down
                        held.add(event.code)
                    elif event.value == 0:  # key up
                        held.discard(event.code)
                    # Trigger on key-down when all combo keys are held
                    if event.value == 1 and combo.issubset(held):
                        do_breakout()
                        held.clear()
            except OSError:
                # Device disconnected
                sel.unregister(dev)
                keyboards.remove(dev)

def main():
    parser = argparse.ArgumentParser(description='Kiosk breakout key watcher')
    parser.add_argument('--combo', default=None,
                        help='Comma-separated evdev key names, e.g. KEY_RIGHTSHIFT,KEY_RIGHTCTRL,KEY_BACKSPACE')
    args = parser.parse_args()

    combo = parse_combo(args.combo) if args.combo else DEFAULT_COMBO
    names = [k for k, v in e.__dict__.items() if isinstance(v, int) and v in combo]
    sys.stderr.write(f"kiosk-breakout: watching for combo: {' + '.join(sorted(names))}\n")

    # Exit cleanly if killed
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    watch(combo)

if __name__ == '__main__':
    main()

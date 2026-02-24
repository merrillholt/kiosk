#!/usr/bin/env python3
"""
Unit tests for kiosk-breakout.py
Tests combo detection logic, parse_combo, do_breakout, and open_keyboards
without requiring real hardware or /dev/uinput access.
"""

import sys
import os
import unittest
from unittest.mock import patch, MagicMock, call
from types import SimpleNamespace

# Add the scripts dir to path so we can import kiosk-breakout
sys.path.insert(0, os.path.dirname(__file__))

# kiosk-breakout.py has a hyphen in the name so we use importlib
import importlib.util
spec = importlib.util.spec_from_file_location(
    "kiosk_breakout",
    os.path.join(os.path.dirname(__file__), "kiosk-breakout.py")
)
kb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kb)

from evdev import ecodes as e

# ── Helpers ───────────────────────────────────────────────────────────────────

def make_event(etype, code, value):
    """Build a minimal evdev-like event object."""
    return SimpleNamespace(type=etype, code=code, value=value)

def run_events_through_combo(events, combo):
    """
    Simulate the inner event-processing loop from watch() and return
    how many times do_breakout() would be called.
    """
    held = set()
    fired = 0
    for event in events:
        if event.type != e.EV_KEY:
            continue
        if event.value == 1:        # key down
            held.add(event.code)
        elif event.value == 0:      # key up
            held.discard(event.code)
        if event.value == 1 and combo.issubset(held):
            fired += 1
            held.clear()
    return fired

# ── Tests ─────────────────────────────────────────────────────────────────────

class TestParseCombo(unittest.TestCase):

    def test_default_combo_keys_exist(self):
        combo = kb.DEFAULT_COMBO
        self.assertIn(e.KEY_RIGHTSHIFT,  combo)
        self.assertIn(e.KEY_RIGHTCTRL,   combo)
        self.assertIn(e.KEY_BACKSPACE,   combo)
        self.assertEqual(len(combo), 3)

    def test_parse_explicit_combo(self):
        combo = kb.parse_combo('KEY_RIGHTSHIFT,KEY_RIGHTCTRL,KEY_BACKSPACE')
        self.assertEqual(combo, kb.DEFAULT_COMBO)

    def test_parse_without_key_prefix(self):
        combo = kb.parse_combo('RIGHTSHIFT,RIGHTCTRL,BACKSPACE')
        self.assertEqual(combo, kb.DEFAULT_COMBO)

    def test_parse_mixed_case(self):
        combo = kb.parse_combo('key_rightshift,KEY_RIGHTCTRL,backspace')
        self.assertEqual(combo, kb.DEFAULT_COMBO)

    def test_parse_two_key_combo(self):
        combo = kb.parse_combo('KEY_LEFTCTRL,KEY_F12')
        self.assertIn(e.KEY_LEFTCTRL, combo)
        self.assertIn(e.KEY_F12,      combo)

    def test_invalid_key_exits(self):
        with self.assertRaises(SystemExit):
            kb.parse_combo('KEY_DOESNOTEXIST')


class TestDoBreakout(unittest.TestCase):

    def test_calls_pkill_cage(self):
        with patch('subprocess.run') as mock_run:
            kb.do_breakout()
            mock_run.assert_called_once_with(['pkill', '-x', 'cage'], check=False)


class TestComboDetection(unittest.TestCase):

    COMBO = frozenset([e.KEY_RIGHTSHIFT, e.KEY_RIGHTCTRL, e.KEY_BACKSPACE])

    def _press(self, code):
        return make_event(e.EV_KEY, code, 1)

    def _release(self, code):
        return make_event(e.EV_KEY, code, 0)

    def test_full_combo_triggers(self):
        events = [
            self._press(e.KEY_RIGHTSHIFT),
            self._press(e.KEY_RIGHTCTRL),
            self._press(e.KEY_BACKSPACE),   # trigger point
        ]
        self.assertEqual(run_events_through_combo(events, self.COMBO), 1)

    def test_order_independent(self):
        """Combo fires regardless of which order modifiers are pressed."""
        events = [
            self._press(e.KEY_RIGHTCTRL),
            self._press(e.KEY_BACKSPACE),   # not yet — RIGHTSHIFT missing
        ]
        self.assertEqual(run_events_through_combo(events, self.COMBO), 0)

        events = [
            self._press(e.KEY_RIGHTCTRL),
            self._press(e.KEY_RIGHTSHIFT),
            self._press(e.KEY_BACKSPACE),   # trigger
        ]
        self.assertEqual(run_events_through_combo(events, self.COMBO), 1)

    def test_partial_combo_does_not_trigger(self):
        events = [
            self._press(e.KEY_RIGHTSHIFT),
            self._press(e.KEY_BACKSPACE),   # RIGHTCTRL still missing
        ]
        self.assertEqual(run_events_through_combo(events, self.COMBO), 0)

    def test_wrong_keys_do_not_trigger(self):
        events = [
            self._press(e.KEY_LEFTSHIFT),
            self._press(e.KEY_LEFTCTRL),
            self._press(e.KEY_BACKSPACE),
        ]
        self.assertEqual(run_events_through_combo(events, self.COMBO), 0)

    def test_extra_keys_held_do_not_block_trigger(self):
        """Holding extra keys alongside the combo should still fire."""
        events = [
            self._press(e.KEY_A),
            self._press(e.KEY_RIGHTSHIFT),
            self._press(e.KEY_RIGHTCTRL),
            self._press(e.KEY_BACKSPACE),   # trigger with extra KEY_A held
        ]
        self.assertEqual(run_events_through_combo(events, self.COMBO), 1)

    def test_modifier_released_before_trigger_key_prevents_fire(self):
        events = [
            self._press(e.KEY_RIGHTSHIFT),
            self._press(e.KEY_RIGHTCTRL),
            self._release(e.KEY_RIGHTSHIFT),   # released before trigger
            self._press(e.KEY_BACKSPACE),       # only one modifier held → no fire
        ]
        self.assertEqual(run_events_through_combo(events, self.COMBO), 0)

    def test_re_triggers_after_release_and_re_press(self):
        events = [
            # First trigger
            self._press(e.KEY_RIGHTSHIFT),
            self._press(e.KEY_RIGHTCTRL),
            self._press(e.KEY_BACKSPACE),
            # Release all
            self._release(e.KEY_BACKSPACE),
            self._release(e.KEY_RIGHTCTRL),
            self._release(e.KEY_RIGHTSHIFT),
            # Second trigger
            self._press(e.KEY_RIGHTSHIFT),
            self._press(e.KEY_RIGHTCTRL),
            self._press(e.KEY_BACKSPACE),
        ]
        self.assertEqual(run_events_through_combo(events, self.COMBO), 2)

    def test_non_key_events_ignored(self):
        """EV_SYN / EV_ABS events mixed in should not affect detection."""
        syn = make_event(e.EV_SYN, e.SYN_REPORT, 0)
        events = [
            self._press(e.KEY_RIGHTSHIFT),
            syn,
            self._press(e.KEY_RIGHTCTRL),
            syn,
            self._press(e.KEY_BACKSPACE),
            syn,
        ]
        self.assertEqual(run_events_through_combo(events, self.COMBO), 1)

    def test_key_repeat_does_not_double_trigger(self):
        """value=2 is key-repeat; should not add to held or fire again."""
        repeat = make_event(e.EV_KEY, e.KEY_RIGHTSHIFT, 2)
        events = [
            self._press(e.KEY_RIGHTSHIFT),
            repeat,                          # repeat event — value != 1, not added
            self._press(e.KEY_RIGHTCTRL),
            self._press(e.KEY_BACKSPACE),    # trigger — only one fire expected
        ]
        self.assertEqual(run_events_through_combo(events, self.COMBO), 1)


class TestOpenKeyboards(unittest.TestCase):

    def _make_device(self, caps):
        dev = MagicMock()
        dev.capabilities.return_value = caps
        return dev

    def test_keyboard_with_key_a_included(self):
        caps = {e.EV_KEY: [e.KEY_A, e.KEY_RIGHTSHIFT]}
        dev = self._make_device(caps)
        with patch('evdev.list_devices', return_value=['/dev/input/event0']), \
             patch('evdev.InputDevice', return_value=dev):
            result = kb.open_keyboards()
        self.assertEqual(result, [dev])

    def test_device_without_key_a_excluded(self):
        """A device with EV_KEY but no KEY_A (e.g. a mouse button) is excluded."""
        caps = {e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT]}
        dev = self._make_device(caps)
        with patch('evdev.list_devices', return_value=['/dev/input/event0']), \
             patch('evdev.InputDevice', return_value=dev):
            result = kb.open_keyboards()
        self.assertEqual(result, [])

    def test_device_without_ev_key_excluded(self):
        """A device with no EV_KEY at all (e.g. accelerometer) is excluded."""
        caps = {e.EV_ABS: [e.ABS_X]}
        dev = self._make_device(caps)
        with patch('evdev.list_devices', return_value=['/dev/input/event0']), \
             patch('evdev.InputDevice', return_value=dev):
            result = kb.open_keyboards()
        self.assertEqual(result, [])

    def test_permission_error_skipped(self):
        with patch('evdev.list_devices', return_value=['/dev/input/event0']), \
             patch('evdev.InputDevice', side_effect=PermissionError):
            result = kb.open_keyboards()
        self.assertEqual(result, [])

    def test_multiple_keyboards_all_included(self):
        caps = {e.EV_KEY: [e.KEY_A]}
        dev0 = self._make_device(caps)
        dev1 = self._make_device(caps)
        with patch('evdev.list_devices', return_value=['/dev/input/event0', '/dev/input/event1']), \
             patch('evdev.InputDevice', side_effect=[dev0, dev1]):
            result = kb.open_keyboards()
        self.assertEqual(result, [dev0, dev1])


# ── Run ───────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    for cls in [TestParseCombo, TestDoBreakout, TestComboDetection, TestOpenKeyboards]:
        suite.addTests(loader.loadTestsFromTestCase(cls))

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)

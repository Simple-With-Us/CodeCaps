#!/usr/bin/env python3
"""Tests for the simulator picker the App Store screenshot capture depends on.

No simulator and no network: the device list is a fixture that mirrors the
names Xcode reports, including the iPad storage variants that a plain equality
match would miss.
"""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pick_simulator import select_device  # noqa: E402

# The names Xcode 27.x reports.  The iPads carry their storage variant in the
# name, which is exactly what an equality match would miss.
DEVICES = [
    {"name": "iPhone 18 Pro", "udid": "A0", "isAvailable": True},
    {"name": "iPhone 17 Pro Max", "udid": "A1", "isAvailable": True},
    {"name": "iPhone 16 Plus", "udid": "A2", "isAvailable": True},
    {"name": "iPad Pro 13-inch (M5) (16GB)", "udid": "B0", "isAvailable": True},
    {"name": "iPad Pro 13-inch (M5) (12GB)", "udid": "B1", "isAvailable": True},
    {"name": "iPad Pro 11-inch (M5) (16GB)", "udid": "B2", "isAvailable": True},
    {"name": "iPhone 15 Pro Max", "udid": "A3", "isAvailable": False},
]

IPHONE_PREFERRED = "iPhone 17 Pro Max|iPhone 16 Pro Max|iPhone 15 Pro Max"
IPAD_PREFERRED = (
    "iPad Pro 13-inch (M5)|iPad Pro 13-inch (M4)"
    "|iPad Pro 12.9-inch (6th generation)"
)


class SelectDeviceTests(unittest.TestCase):
    def test_picks_the_first_preferred_name(self):
        device = select_device(DEVICES, IPHONE_PREFERRED.split("|"))
        self.assertIsNotNone(device)
        self.assertEqual(device["udid"], "A1")

    def test_matches_an_ipad_named_with_its_storage_variant(self):
        device = select_device(DEVICES, IPAD_PREFERRED.split("|"))
        self.assertIsNotNone(device)
        self.assertTrue(device["name"].startswith("iPad Pro 13-inch (M5)"))

    def test_falls_through_to_the_next_preferred_name(self):
        device = select_device(DEVICES, ["iPhone 16 Pro Max", "iPhone 16 Plus"])
        self.assertIsNotNone(device)
        self.assertEqual(device["udid"], "A2")

    def test_skips_a_device_that_is_not_available(self):
        device = select_device(DEVICES, ["iPhone 15 Pro Max"])
        self.assertIsNone(device)

    def test_returns_nothing_when_no_name_matches(self):
        device = select_device(DEVICES, ["iPad Pro 12.9-inch (3rd generation)"])
        self.assertIsNone(device)

    def test_does_not_match_a_different_model_with_a_shared_prefix(self):
        device = select_device(DEVICES, ["iPad Pro 13-inch (M4)"])
        self.assertIsNone(device)


if __name__ == "__main__":
    unittest.main()

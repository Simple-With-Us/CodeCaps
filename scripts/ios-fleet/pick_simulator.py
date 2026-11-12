#!/usr/bin/env python3
"""Print the UDID of the first available iOS simulator matching a preferred name.

The capture script needs one iPhone simulator and one iPad simulator, and it
needs them to be the models whose screen size App Store Connect accepts.  The
preferred names are given as a pipe-separated list, most wanted first, and the
first device whose name starts with one of them wins.

The match is a prefix rather than an equality because Xcode names some iPads
with their storage variant ("iPad Pro 13-inch (M5) (16GB)").  An exact match
finds no iPad at all on a runner that only has the current runtime, and the
capture then fails after an hour of runner time.
"""
from __future__ import annotations

import json
import subprocess
import sys


def select_device(devices, preferred):
    """Return the first available device whose name starts with a preferred name.

    `devices` is the flat list simctl reports; `preferred` is a list of names
    in order of preference.  Returns the device dict, or None when nothing
    matches.
    """
    available = [device for device in devices if device.get("isAvailable")]
    for want in preferred:
        for device in available:
            if device.get("name", "").startswith(want):
                return device
    return None


def list_devices():
    """Return every simulator device simctl reports, available or not."""
    raw = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    data = json.loads(raw)
    return [device for group in data.get("devices", {}).values() for device in group]


def main(argv):
    if len(argv) != 2:
        print(
            "usage: pick_simulator.py <preferred-names-pipe-separated>",
            file=sys.stderr,
        )
        return 2
    device = select_device(list_devices(), argv[1].split("|"))
    if device is None:
        return 1
    print(device["udid"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""Measure how much of a simulator screenshot is not background.

The companion app needs several seconds to draw its first frame on a cold
simulator, and a fixed sleep captured a blank window more than once.  The
capture script polls instead: it takes a frame and asks this module whether
the screen holds more than the status bar.

The measurement is the share of pixels that differ from the frame's own
background colour.  A blank app window is the background plus the status bar,
which measures about 0.2 percent; a drawn screen measures tens of percent.
The threshold sits far from both, so a slow frame is never mistaken for a
blank one and a blank one is never mistaken for a slow frame.
"""
from __future__ import annotations

import argparse
import os
import struct
import subprocess
import sys
import tempfile
from collections import Counter

# The share of non-background pixels a drawn screen has to reach before the
# capture script keeps the frame.  A blank window measures about 0.2 percent
# and a drawn one about 48 percent.
DEFAULT_MIN_PERCENT = 1.0


def ink_percent(channels):
    """Return the share of pixels that differ from the frame's background.

    `channels` is a sequence of byte strings, one per colour channel, each
    holding one byte per pixel.  The background is the most common value of a
    channel, and a pixel counts as ink when its byte differs from that
    channel's background.  The largest per-channel count wins: it over-counts
    a pixel that differs in more than one channel and never under-counts one
    that differs in any.
    """
    if not channels:
        return 0.0
    worst = 0
    for channel in channels:
        if not channel:
            continue
        background = Counter(channel).most_common(1)[0][0]
        differing = len(channel) - channel.count(background)
        worst = max(worst, differing)
    return worst * 100.0 / len(channels[0])


def read_bmp_channels(path):
    """Return the colour channels of a BMP file, one byte per pixel each.

    Both 24-bit and 32-bit BMPs are read, in either row order, because that is
    what `sips` writes depending on whether the source had an alpha channel.
    The channel order inside a pixel does not matter: the measurement only
    compares each channel against its own background.
    """
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:2] != b"BM":
        raise ValueError(f"{path} is not a BMP file")
    offset = struct.unpack_from("<I", data, 10)[0]
    width = struct.unpack_from("<i", data, 18)[0]
    height = struct.unpack_from("<i", data, 22)[0]
    bits = struct.unpack_from("<H", data, 28)[0]
    if bits not in (24, 32):
        raise ValueError(f"{path} has an unsupported depth of {bits} bits per pixel")
    top_down = height < 0
    height = abs(height)
    bytes_per_pixel = bits // 8
    stride = width * bytes_per_pixel
    stride += (-stride) % 4
    rows = []
    for y in range(height):
        start = offset + y * stride
        line = data[start:start + width * bytes_per_pixel]
        if len(line) < width * bytes_per_pixel:
            raise ValueError(f"{path} is truncated")
        rows.append((line[0::bytes_per_pixel], line[1::bytes_per_pixel], line[2::bytes_per_pixel]))
    if not top_down:
        rows.reverse()
    return tuple(b"".join(row[index] for row in rows) for index in range(3))


def measure(path):
    """Return the percentage of the frame at `path` that is not background."""
    with tempfile.TemporaryDirectory() as work:
        converted = os.path.join(work, "frame.bmp")
        subprocess.run(
            ["sips", "-s", "format", "bmp", path, "--out", converted],
            check=True,
            capture_output=True,
        )
        channels = read_bmp_channels(converted)
    return ink_percent(channels)


def main(argv):
    parser = argparse.ArgumentParser(description="Measure the ink in a screenshot.")
    parser.add_argument("image", help="the PNG or JPEG to measure")
    parser.add_argument(
        "--min-percent",
        type=float,
        default=DEFAULT_MIN_PERCENT,
        help="exit 0 only when the frame holds at least this much non-background",
    )
    args = parser.parse_args(argv[1:])
    try:
        percent = measure(args.image)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"screenshot_ink: {error}", file=sys.stderr)
        return 2
    print(
        f"screenshot_ink: {os.path.basename(args.image)} holds {percent:.2f}% non-background pixels",
        file=sys.stderr,
    )
    return 0 if percent >= args.min_percent else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

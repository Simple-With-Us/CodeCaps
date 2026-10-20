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

# The modal byte value is taken from a strided sample rather than from every
# byte of the channel.  A full Counter over the 3.8 million bytes of one
# channel of a 1320x2868 frame took about 0.96 seconds, and the capture script
# measures every frame it throws away, so that cost was paid several times per
# screen.  A sample of every sixteenth byte names the same background in
# about 0.02 seconds, and the count that follows it is still exact because it
# runs over the whole channel.
MODE_SAMPLE_STRIDE = 16

# A frame whose sampled background does not hold at least this share of the
# channel has no dominant background, so the sample is not trustworthy and the
# exact mode is computed instead.  A simulator frame is a page on a flat
# background and never reaches this, so the slow path is the exception.
DOMINANT_BACKGROUND_MINIMUM = 0.10

# The share of the frame's height that is header: the status bar and the
# navigation bar.  Both are drawn before the content, so a frame that has drawn
# only its header has no ink at all below this line.  The content region is
# what tells a finished screen from a half-drawn one, because a threshold on
# the whole frame cannot separate "a navigation bar and nothing else" from "a
# screen with a little on it".
HEADER_SHARE = 0.15


def background_value(channel):
    """Return the most common byte value in `channel`.

    The value is found from a strided sample and then confirmed against the
    whole channel, so the answer is exact for any frame that has a dominant
    background.  A frame without one falls back to counting every value.
    """
    candidate = Counter(channel[::MODE_SAMPLE_STRIDE]).most_common(1)[0][0]
    if channel.count(candidate) >= len(channel) * DOMINANT_BACKGROUND_MINIMUM:
        return candidate
    return Counter(channel).most_common(1)[0][0]


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
        background = background_value(channel)
        differing = len(channel) - channel.count(background)
        worst = max(worst, differing)
    return worst * 100.0 / len(channels[0])


def read_bmp_frame(path):
    """Return the colour channels of a BMP file, with its size.

    Both 24-bit and 32-bit BMPs are read, in either row order, because that is
    what `sips` writes depending on whether the source had an alpha channel.
    The channel order inside a pixel does not matter: the measurement only
    compares each channel against its own background.

    The rows come back in image order, so the first row of a channel is the
    top of the frame and the last is the bottom.
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
    channels = tuple(b"".join(row[index] for row in rows) for index in range(3))
    return channels, width, height


def read_bmp_channels(path):
    """Return the colour channels of a BMP file, one byte per pixel each."""
    channels, _width, _height = read_bmp_frame(path)
    return channels


def ink_shares(channels, width, height):
    """Return the share of the frame, and of its content region, that is ink.

    The overall share counts every pixel.  The content share counts only the
    pixels below the header, which is where a screen's content lives.

    The two answers together are what tell a finished screen from a half-drawn
    one.  A frame that has drawn its navigation bar and none of its content
    has ink in the header and none at all below it, so a threshold on the
    content share rejects it even when the overall share is high enough to
    have cleared a threshold on the whole frame.

    As in `ink_percent`, the largest per-channel count wins: it over-counts a
    pixel that differs in more than one channel and never under-counts one
    that differs in any.
    """
    if not channels or width <= 0 or height <= 0:
        return 0.0, 0.0
    total = len(channels[0])
    if total <= 0:
        return 0.0, 0.0
    start = min(int(height * HEADER_SHARE), max(height - 1, 0))
    region = total - start * width
    if region <= 0:
        region = 1
    worst_total = 0
    worst_region = 0
    for channel in channels:
        if not channel:
            continue
        background = background_value(channel)
        worst_total = max(worst_total, total - channel.count(background))
        segment = channel[start * width:]
        worst_region = max(worst_region, len(segment) - segment.count(background))
    return worst_total * 100.0 / total, worst_region * 100.0 / region


def measure(path):
    """Return the overall and content ink percentages of the frame at `path`."""
    with tempfile.TemporaryDirectory() as work:
        converted = os.path.join(work, "frame.bmp")
        subprocess.run(
            ["sips", "-s", "format", "bmp", path, "--out", converted],
            check=True,
            capture_output=True,
        )
        channels, width, height = read_bmp_frame(converted)
    return ink_shares(channels, width, height)


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
        overall, content = measure(args.image)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"screenshot_ink: {error}", file=sys.stderr)
        return 2
    print(
        f"screenshot_ink: {os.path.basename(args.image)} holds {overall:.2f}% ink overall "
        f"and {content:.2f}% below the header",
        file=sys.stderr,
    )
    # The two numbers go to stdout so the capture script can read them and
    # compare two polls.  The human line stays on stderr, so it never becomes
    # part of a captured value.
    print(f"{overall:.4f} {content:.4f}")
    return 0 if overall >= args.min_percent else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

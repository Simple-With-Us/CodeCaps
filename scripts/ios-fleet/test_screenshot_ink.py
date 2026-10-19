#!/usr/bin/env python3
"""Tests for the screenshot ink measurement the App Store capture depends on.

No simulator and no image library: the frames are synthetic BMPs built here,
in both pixel depths and both row orders, because that is the whole range
`sips` produces for the capture.
"""
from __future__ import annotations

import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from screenshot_ink import ink_percent, read_bmp_channels  # noqa: E402


def build_bmp(width, height, rows, bits=24, top_down=True):
    """Return a BMP whose pixels are the given rows of (b, g, r) tuples."""
    bytes_per_pixel = bits // 8
    stride = width * bytes_per_pixel
    stride += (-stride) % 4
    order = rows if top_down else list(reversed(rows))
    pixels = bytearray()
    for row in order:
        for pixel in row:
            blue, green, red = pixel
            pixels += bytes((blue, green, red))
            if bytes_per_pixel == 4:
                pixels += b"\xff"
        pixels += b"\x00" * (stride - width * bytes_per_pixel)
    offset = 54
    header = b"BM" + struct.pack("<IHHI", offset + len(pixels), 0, 0, offset)
    dib = struct.pack(
        "<IiiHHIIiiII",
        40,
        width,
        -height if top_down else height,
        1,
        bits,
        0,
        len(pixels),
        2835,
        2835,
        0,
        0,
    )
    return header + dib + bytes(pixels)


def blank_frame(width=200, height=200, status_bar_pixels=80):
    """A frame that is the background everywhere except a few status-bar dots.

    The size matters: a blank simulator window is the background plus the
    status bar, and the status bar is a fixed handful of pixels on a frame of
    millions, which is why a blank window measures about 0.2 percent.
    """
    rows = [[(255, 255, 255) for _ in range(width)] for _ in range(height)]
    for index in range(status_bar_pixels):
        rows[0][index] = (0, 0, 0)
    return rows


def drawn_frame(width=200, height=200):
    """A frame with a card, a bar and some text on it."""
    rows = [[(255, 255, 255) for _ in range(width)] for _ in range(height)]
    for y in range(20, 170):
        for x in range(10, 190):
            rows[y][x] = (247, 242, 242)
    for y in range(80, 110):
        for x in range(20, 150):
            rows[y][x] = (136, 148, 13)
    return rows


class InkPercentTests(unittest.TestCase):
    def test_a_uniform_frame_measures_nothing(self):
        channels = [b"\xff" * 100, b"\xff" * 100, b"\xff" * 100]
        self.assertEqual(ink_percent(channels), 0.0)

    def test_no_channels_measures_nothing(self):
        self.assertEqual(ink_percent([]), 0.0)

    def test_counts_the_bytes_that_differ_from_the_background(self):
        channels = [b"\xff" * 99 + b"\x00", b"\xff" * 100, b"\xff" * 100]
        self.assertAlmostEqual(ink_percent(channels), 1.0)

    def test_takes_the_worst_channel(self):
        #  The first channel differs on 10 bytes and the second on 40, so the
        #  measurement is the larger of the two.
        channels = [b"\xff" * 90 + b"\x00" * 10, b"\xff" * 60 + b"\x00" * 40, b"\xff" * 100]
        self.assertAlmostEqual(ink_percent(channels), 40.0)


class ReadBmpChannelsTests(unittest.TestCase):
    def test_reads_a_24_bit_top_down_bmp(self):
        rows = [[(1, 2, 3), (4, 5, 6)], [(7, 8, 9), (10, 11, 12)]]
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "frame.bmp")
            with open(path, "wb") as handle:
                handle.write(build_bmp(2, 2, rows, bits=24, top_down=True))
            channels = read_bmp_channels(path)
        self.assertEqual(channels[0], bytes((1, 4, 7, 10)))
        self.assertEqual(channels[1], bytes((2, 5, 8, 11)))
        self.assertEqual(channels[2], bytes((3, 6, 9, 12)))

    def test_reads_a_32_bit_bottom_up_bmp(self):
        rows = [[(1, 2, 3), (4, 5, 6)], [(7, 8, 9), (10, 11, 12)]]
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "frame.bmp")
            with open(path, "wb") as handle:
                handle.write(build_bmp(2, 2, rows, bits=32, top_down=False))
            channels = read_bmp_channels(path)
        #  A bottom-up BMP holds the bottom row first, and reading it has to
        #  put the rows back in image order.
        self.assertEqual(channels[0], bytes((1, 4, 7, 10)))

    def test_rejects_a_file_that_is_not_a_bmp(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "frame.bmp")
            with open(path, "wb") as handle:
                handle.write(b"not a bitmap at all")
            with self.assertRaises(ValueError):
                read_bmp_channels(path)


class BlankVersusDrawnTests(unittest.TestCase):
    def test_a_blank_window_stays_under_the_threshold(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "frame.bmp")
            with open(path, "wb") as handle:
                handle.write(build_bmp(200, 200, blank_frame()))
            channels = read_bmp_channels(path)
        self.assertLess(ink_percent(channels), 1.0)

    def test_a_drawn_screen_clears_the_threshold(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "frame.bmp")
            with open(path, "wb") as handle:
                handle.write(build_bmp(200, 200, drawn_frame()))
            channels = read_bmp_channels(path)
        self.assertGreater(ink_percent(channels), 1.0)


if __name__ == "__main__":
    unittest.main()

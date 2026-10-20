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
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from screenshot_ink import (  # noqa: E402
    background_value,
    ink_percent,
    ink_shares,
    read_bmp_channels,
    read_bmp_frame,
)


def header_only_frame(width=200, height=200, header_rows=20):
    """A frame with a navigation bar and nothing below it.

    This is the shape of a screen that has drawn its header and is still
    waiting for its content, and it is the case the whole-frame threshold
    cannot see: it covers a few percent of the frame, but none of the content
    region.
    """
    rows = [[(255, 255, 255) for _ in range(width)] for _ in range(height)]
    for y in range(header_rows):
        for x in range(width):
            rows[y][x] = (136, 148, 13)
    return rows


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


class BackgroundValueTests(unittest.TestCase):
    def test_finds_the_background_of_a_frame_with_a_dominant_colour(self):
        channel = b"\xf8" * 4000 + b"\x11" * 40
        self.assertEqual(background_value(channel), 0xF8)

    def test_a_stride_that_lands_only_on_ink_does_not_hide_the_background(self):
        #  Every sixteenth byte is ink and the rest is the background, so a
        #  strided sample names the wrong value.  The sample has to be
        #  confirmed against the whole channel before it is believed.
        channel = b"\x00" * 16 + b"\xff" * 240
        self.assertEqual(background_value(channel), 0xFF)

    def test_a_frame_without_a_dominant_background_still_measures(self):
        channel = bytes(range(256)) * 4
        self.assertEqual(background_value(channel), Counter(channel).most_common(1)[0][0])


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


class InkSharesTests(unittest.TestCase):
    def test_a_header_only_frame_has_ink_but_no_content(self):
        #  The whole-frame share sees the navigation bar.  The content share
        #  does not, because the bar is above the content region.  That is the
        #  difference the capture gate depends on.
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "frame.bmp")
            with open(path, "wb") as handle:
                handle.write(build_bmp(200, 200, header_only_frame()))
            channels, width, height = read_bmp_frame(path)
        overall, content = ink_shares(channels, width, height)
        self.assertGreater(overall, 0.0)
        self.assertEqual(content, 0.0)

    def test_a_drawn_screen_holds_content_below_the_header(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "frame.bmp")
            with open(path, "wb") as handle:
                handle.write(build_bmp(200, 200, drawn_frame()))
            channels, width, height = read_bmp_frame(path)
        overall, content = ink_shares(channels, width, height)
        self.assertGreater(overall, 0.0)
        self.assertGreater(content, 0.0)

    def test_the_content_share_is_a_share_of_the_content_region(self):
        #  The content region is the part below the header, so it excludes the
        #  ink in the header and is a share of a smaller area.  The card fills
        #  most of the content region, so the two numbers stay close.
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "frame.bmp")
            with open(path, "wb") as handle:
                handle.write(build_bmp(200, 200, drawn_frame()))
            channels, width, height = read_bmp_frame(path)
        overall, content = ink_shares(channels, width, height)
        self.assertLess(content, overall, "the header region holds ink, so it is excluded")
        self.assertGreater(content, overall * 0.7, "the card fills most of the content region")

    def test_no_channels_measures_nothing(self):
        self.assertEqual(ink_shares([], 100, 100), (0.0, 0.0))

    def test_read_bmp_frame_reports_the_size(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "frame.bmp")
            with open(path, "wb") as handle:
                handle.write(build_bmp(7, 11, blank_frame(width=7, height=11, status_bar_pixels=2)))
            channels, width, height = read_bmp_frame(path)
        self.assertEqual(width, 7)
        self.assertEqual(height, 11)
        self.assertEqual(len(channels[0]), 7 * 11)


if __name__ == "__main__":
    unittest.main()

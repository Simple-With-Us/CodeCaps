#!/usr/bin/env python3
"""Regenerate the bundled provider marks from their vector / high-resolution sources.

Why this exists
---------------
The provider marks were sharp on paper and soft on screen.  They were not
low-resolution in the sense of a small canvas -- the canvases were 256px and
512px -- they were blurry upscales.  The artwork inside each canvas was
carried by a wide anti-aliased edge band, and an edge that is several pixels
wide becomes several device pixels of blur once the mark is drawn at 28pt on
a 2x display.  A real raster of the same artwork has a one-pixel edge.

Measured, not assumed: the width of the anti-aliased transition at a mark's
silhouette, in the pixels the mark is drawn at.  `edge_band` below measures
it, and the shipped Cursor, Gemini, Grok and Claude marks came out at 1.70 to
2.07 device pixels where the marks that were already right sat at 0.27 to
0.47.

The fix is not new artwork.  It is the *same* artwork, taken from a source that
still has the detail, and placed back at exactly the size and position it
already occupied so nothing moves on screen.

Rules this script holds itself to
----------------------------------
1.  Never invent artwork.  Every source is either a vector that already ships
    in this repository, or a file from the owner's own icon library
    (`~/Code/Icons-Logos`), and every source is the *same mark* as the file it
    replaces.
2.  Never guess.  Before writing, the rebuilt mark is compared with the file
    it replaces at the size the mark is drawn at, over neutral grey so that
    every mark shows its shape.  That one measurement covers the silhouette
    and the palette together: a mark that is a different shape, or the same
    shape in a different colour, does not match it.  A file that fails the
    check is reported and left alone.
3.  Never move the artwork.  The art's bounding box inside the canvas is
    taken from the file being replaced and reproduced in the new file.
4.  The ink variants keep the ink they already had.  `-light` and `-dark` are
    rendered as templates, so only their alpha channel matters; the colour is
    carried over from the existing file rather than hard-coded.
5.  Never make a mark worse.  A rebuild that softens the silhouette is
    refused, and so is one that does not actually sharpen anything.  Both
    are reported and skipped.

Usage
-----
    python3 -m pip install --user cairosvg pillow numpy
    python3 scripts/regenerate-provider-marks.py             # report only
    python3 scripts/regenerate-provider-marks.py --write     # rewrite assets

Reporting is the default: it prints what would change and whether each file
passes the same-art check, and writes nothing.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
from dataclasses import dataclass

try:
    import numpy as np
    from PIL import Image
except ImportError:  # pragma: no cover - developer tool
    sys.exit("regenerate-provider-marks: needs Pillow and numpy (pip install pillow numpy)")

try:
    import cairosvg
except ImportError:  # pragma: no cover - developer tool
    sys.exit("regenerate-provider-marks: needs cairosvg (pip install cairosvg)")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARKS = os.path.join(REPO, "Sources/CodeCaps/Resources/ProviderMarks")
IOS_ASSETS = os.path.join(REPO, "ios/CodeCapsCompanion/Assets.xcassets")

OWNER = os.path.expanduser("~/Code/Icons-Logos")
OWNER_AI = os.path.join(OWNER, "AI Platforms : Models")

# The size a mark is actually drawn at, in device pixels.  A provider mark is
# drawn into a square frame: 28pt at 2x in the Mac app, 36pt at 3x in the
# companion.  That is the only size at which a mark has to look right, so it
# is the size every comparison here is made at.
MAC_DISPLAY_PIXELS = 56
IOS_DISPLAY_PIXELS = 108

# Two marks may differ at the pixel level and still be the same mark, so the
# same-art check is made where the mark is seen.  Above this, the two are
# genuinely different artwork.
DISPLAY_TOLERANCE = 6.0

# A rebuild has to be an improvement, not just a change.  A source that
# renders softer than the file it replaces is left alone.
MIN_SHARPNESS_GAIN = 0.02

# A rebuild may not soften the silhouette.  The edge band is the width of the
# anti-aliased transition at the mark's outline, in the pixels the mark is
# drawn at.  A mark with real detail has a one-pixel edge; a mark that is a
# blurry upscale of a smaller raster has an edge several pixels wide, and that
# is what reads on screen as a soft logo.  A rebuild may widen the band by
# this much and no more, measured in display pixels.
MAX_EDGE_WIDENING = 0.20

# The absolute limit a delivered mark has to meet, in the pixels the mark is
# drawn at.  These are the same numbers ProviderMarkDetailTests uses, and
# that test reads them from here, so the two cannot drift apart.  A rebuild
# that would still be over the limit is refused: the script must never write
# a mark the test would reject.
MAC_EDGE_LIMIT = 1.0
IOS_EDGE_LIMIT = 1.65

# Marks whose own artwork is soft, and for which this repository holds no
# same-art higher-resolution copy.  The test allows them; the script does not
# try to raise them.
SOFT_BY_DESIGN = {
    "openai-color.png", "openai-dark.png", "openai-light.png",
    "grok-bot-color.png", "grok-bot-dark.png", "grok-bot-light.png",
}

# A rebuild that hardens the silhouette is an improvement even when the
# gradient energy barely moves.  For a mark whose detail is in its outline --
# the Cursor cube, the Claude starburst -- a soft edge is the whole defect,
# and the edge band measures it where the gradient does not.
MIN_EDGE_GAIN = 0.40

DARK_INK_VARIANTS = ("-dark",)
LIGHT_INK_VARIANTS = ("-light",)


@dataclass(frozen=True)
class Target:
    """One file to regenerate, and where its artwork comes from."""

    path: str          # path relative to the repository root
    source: str        # source artwork; "{owner}" expands to the owner's library
    kind: str          # "svg" or "png"
    note: str          # where the source lives, for the provenance table

    def with_owner(self, owner_root: str) -> "Target":
        if "{owner}" not in self.source:
            return self
        return Target(self.path, self.source.format(owner=owner_root), self.kind, self.note)

    def resolved_source(self) -> str:
        return self.source.replace("{owner}", OWNER_AI)


def repo_svg(name: str) -> str:
    return os.path.join(MARKS, name)





def owner(*parts: str) -> str:
    """An artwork from the owner's icon library, resolved at run time."""
    return "{owner}/" + "/".join(parts)


# ---------------------------------------------------------------------------
# The source table.  A row is a file in the repository and the artwork that
# carries the same mark with the detail still in it.
#
# Marked "own" are the vectors this repository already ships: the PNGs were
# rasterisations of them, so re-rasterising the vector at the file's own size
# recovers the detail the raster threw away.
#
# Marked "owner" come from the owner's icon library and were checked against
# the file they replace.
# ---------------------------------------------------------------------------

MUSE = owner("square", "Muse_BlueM_TransparentBG.png")
GEMINI = owner("square", "Google_Gemini_icon_2025.svg copy.png")
CLAUDE = owner("square", "Claude_AI_symbol.png")
MINIMAX = owner("square", "minimax-color.png")
MINIMAX_DARK = owner("square", "minimax_dark.png")
MINIMAX_LIGHT = owner("square", "minimax_light.png")
ANTIGRAVITY = owner("google-antigravity-icon.svg")

# Two families are deliberately absent.  `openai.svg` draws a solid knot where
# the shipped PNG draws a hollow one, and `grok-bot.svg` changes the eye
# cutouts: those are different renderings of the mark, not lower-resolution
# copies of it, so swapping them in would be substituting artwork.  They are
# left exactly as they are.
#
MAC_TARGETS: list[Target] = [
    # Claude -- own vector.  The owner's 1517px raster of the same mark is
    # measurably softer at draw size, so the vector wins even though the
    # owner's file is bigger.
    Target("Sources/CodeCaps/Resources/ProviderMarks/claude-color.png", repo_svg("claude.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/claude-dark.png", repo_svg("claude.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/claude-light.png", repo_svg("claude.svg"), "svg", "own"),
    # Cursor -- own vector (Simple Icons, CC0).
    Target("Sources/CodeCaps/Resources/ProviderMarks/cursor-color.png", repo_svg("cursor.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/cursor-dark.png", repo_svg("cursor.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/cursor-light.png", repo_svg("cursor.svg"), "svg", "own"),
    # Copilot -- own vector (official outline, owner-supplied).
    Target("Sources/CodeCaps/Resources/ProviderMarks/copilot-color.png", repo_svg("copilot.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/copilot-dark.png", repo_svg("copilot.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/copilot-light.png", repo_svg("copilot.svg"), "svg", "own"),
    # OpenAI -- own vector.
    # Grok -- own vector.
    Target("Sources/CodeCaps/Resources/ProviderMarks/grok-color.png", repo_svg("grok.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/grok-dark.png", repo_svg("grok.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/grok-light.png", repo_svg("grok.svg"), "svg", "own"),
    # xAI -- own vector.
    Target("Sources/CodeCaps/Resources/ProviderMarks/xai-color.png", repo_svg("xai.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/xai-dark.png", repo_svg("xai.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/xai-light.png", repo_svg("xai.svg"), "svg", "own"),
    # Gemini -- the Antigravity colour star from the owner, and this
    # repository's own two star vectors.
    Target("Sources/CodeCaps/Resources/ProviderMarks/gemini-color.png", GEMINI, "png", "owner"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/gemini-color-color.png", GEMINI, "png", "owner"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/gemini-color-dark.png", GEMINI, "png", "owner"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/gemini-color-light.png", GEMINI, "png", "owner"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/gemini-mono-color.png", repo_svg("gemini-mono.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/gemini-mono-dark.png", repo_svg("gemini-mono.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/gemini-mono-light.png", repo_svg("gemini-mono.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/gemini-dark.png", repo_svg("gemini.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/gemini-light.png", repo_svg("gemini.svg"), "svg", "own"),
    # Muse -- owner raster with 840px of art.
    Target("Sources/CodeCaps/Resources/ProviderMarks/muse.png", MUSE, "png", "owner"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/muse-color.png", MUSE, "png", "owner"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/muse-dark.png", MUSE, "png", "owner"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/muse-light.png", MUSE, "png", "owner"),
    # Muse Code -- own vector.
    Target("Sources/CodeCaps/Resources/ProviderMarks/muse-code.png", repo_svg("muse-code.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/muse-code-color.png", repo_svg("muse-code.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/muse-code-dark.png", repo_svg("muse-code.svg"), "svg", "own"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/muse-code-light.png", repo_svg("muse-code.svg"), "svg", "own"),
    # MiniMax -- owner rasters.
    Target("Sources/CodeCaps/Resources/ProviderMarks/minimax-color.png", MINIMAX, "png", "owner"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/minimax-dark.png", MINIMAX_DARK, "png", "owner"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/minimax-light.png", MINIMAX_LIGHT, "png", "owner"),
    # Antigravity -- owner vector of the supplied arch.
    Target("Sources/CodeCaps/Resources/ProviderMarks/antigravity-color.png", ANTIGRAVITY, "svg", "owner"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/antigravity-dark.png", ANTIGRAVITY, "svg", "owner"),
    Target("Sources/CodeCaps/Resources/ProviderMarks/antigravity-light.png", ANTIGRAVITY, "svg", "owner"),
]

IOS_TARGETS: list[Target] = [
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-muse.imageset/provider-muse.png", MUSE, "png", "owner"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-muse.imageset/provider-muse@2x.png", MUSE, "png", "owner"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-muse.imageset/provider-muse@3x.png", MUSE, "png", "owner"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-muse-assist.imageset/provider-muse-assist.png", MUSE, "png", "owner"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-muse-assist.imageset/provider-muse-assist@2x.png", MUSE, "png", "owner"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-muse-assist.imageset/provider-muse-assist@3x.png", MUSE, "png", "owner"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-muse-code.imageset/provider-muse-code.png", repo_svg("muse-code.svg"), "svg", "own"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-muse-code.imageset/provider-muse-code@2x.png", repo_svg("muse-code.svg"), "svg", "own"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-muse-code.imageset/provider-muse-code@3x.png", repo_svg("muse-code.svg"), "svg", "own"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-minimax.imageset/provider-minimax.png", MINIMAX, "png", "owner"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-minimax.imageset/provider-minimax@2x.png", MINIMAX, "png", "owner"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-minimax.imageset/provider-minimax@3x.png", MINIMAX, "png", "owner"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-gemini.imageset/provider-gemini.png", GEMINI, "png", "owner"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-gemini.imageset/provider-gemini@2x.png", GEMINI, "png", "owner"),
    Target(f"ios/CodeCapsCompanion/Assets.xcassets/provider-gemini.imageset/provider-gemini@3x.png", GEMINI, "png", "owner"),
]


# ---------------------------------------------------------------------------
# Measurement helpers
# ---------------------------------------------------------------------------

GREY = 128.0


def _alpha_array(image: Image.Image) -> np.ndarray:
    return np.asarray(image.convert("RGBA"), dtype=np.float32)[..., 3]


def art_bbox(image: Image.Image) -> tuple[int, int, int, int] | None:
    return image.convert("RGBA").getchannel("A").getbbox()


def composite_grey(image: Image.Image) -> np.ndarray:
    """Composite over neutral grey.

    Over white a white-ink mark disappears and only a black-ink mark shows;
    over grey every mark shows its shape, so the measure is comparable
    across all of them.
    """
    arr = np.asarray(image.convert("RGBA"), dtype=np.float32)
    alpha = arr[..., 3:4] / 255.0
    return arr[..., :3] * alpha + GREY * (1 - alpha)


def sharpness_at(image: Image.Image, display_px: int) -> float:
    """How much edge survives when the mark is drawn at the size the app draws
    it.  Higher is sharper."""
    drawn = image.convert("RGBA").resize((display_px, display_px), Image.LANCZOS)
    grey = composite_grey(drawn).mean(axis=2)
    dx = float(np.abs(np.diff(grey, axis=1)).mean())
    dy = float(np.abs(np.diff(grey, axis=0)).mean())
    return dx + dy


def compare_at_display(a: Image.Image, b: Image.Image, display_px: int) -> tuple[float, float, float]:
    """How different two marks look as drawn, and how sharp each one is."""
    drawn_a = a.convert("RGBA").resize((display_px, display_px), Image.LANCZOS)
    drawn_b = b.convert("RGBA").resize((display_px, display_px), Image.LANCZOS)
    difference = float(np.abs(composite_grey(drawn_a) - composite_grey(drawn_b)).mean())
    return difference, sharpness_at(a, display_px), sharpness_at(b, display_px)


SOLID_ALPHA = 247
VISIBLE_ALPHA = 8


def _erode(mask: np.ndarray) -> np.ndarray:
    out = mask.copy()
    out[1:, :] &= mask[:-1, :]
    out[:-1, :] &= mask[1:, :]
    out[:, 1:] &= mask[:, :-1]
    out[:, :-1] &= mask[:, 1:]
    return out


def drawn_device_pixels(relative_path: str, canvas_width: int) -> int:
    """The device pixels the mark is drawn at.

    The edge has to be measured in the pixels a user sees, and that depends
    on the file.  The Mac app draws a mark into a 28pt frame at 2x, so 56
    device pixels.  A companion mark in a density set is drawn on a screen of
    its own density, so the file's own pixels are already device pixels.  A
    single-file image set is drawn at the companion's mark size, which is at
    most 108 device pixels, and that is the conservative reading.
    """
    if relative_path.startswith("Sources"):
        return MAC_DISPLAY_PIXELS
    imageset = os.path.join(REPO, os.path.dirname(relative_path), "Contents.json")
    try:
        with open(imageset, "r", encoding="utf-8") as handle:
            contents = json.load(handle)
    except (OSError, ValueError):
        return IOS_DISPLAY_PIXELS
    name = os.path.basename(relative_path)
    for image in contents.get("images", []):
        if image.get("filename") == name and image.get("scale"):
            return canvas_width
    return IOS_DISPLAY_PIXELS


def edge_band(image: Image.Image, display_px: int) -> float | None:
    """Width of the anti-aliased transition at the mark's silhouette, in the
    pixels the mark is actually drawn at.

    The perimeter is the ring of visible pixels with a non-visible neighbour.
    The band is the number of partially transparent pixels over that
    perimeter, which is how wide the transition runs: a mark whose outline is
    a hard step has almost no partially transparent pixels and the band is
    well under one, and a mark that is a blurry upscale of a smaller raster
    spreads its transition over several pixels and the band is well over one.
    That is what reads on screen as a soft logo.

    Interior translucency counts towards the band as well, so a mark that is
    soft inside reads as soft here.  That errs towards flagging a mark rather
    than hiding one.
    """
    rgba = image.convert("RGBA")
    bbox = rgba.getchannel("A").getbbox()
    if bbox is None:
        return None
    alpha = np.asarray(rgba.crop(bbox), dtype=np.float32)[..., 3]

    visible = alpha > VISIBLE_ALPHA
    if not visible.any():
        return None
    partial = (alpha > VISIBLE_ALPHA) & (alpha < SOLID_ALPHA)
    if not partial.any():
        return 0.0
    perimeter = float((visible & ~_erode(visible)).sum())
    if perimeter == 0:
        return None
    width = float(partial.sum()) / perimeter
    return width * (display_px / image.size[0])


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

_SOURCE_CACHE: dict[tuple[str, str], Image.Image] = {}


def render_source(target: Target) -> Image.Image:
    """Render the source artwork once per file and reuse it.

    Several marks share one source, and rasterising a vector is by far the
    slowest thing this script does.
    """
    source_path = target.resolved_source()
    key = (target.kind, source_path)
    cached = _SOURCE_CACHE.get(key)
    if cached is not None:
        return cached
    if target.kind == "svg":
        png = cairosvg.svg2png(url=source_path, parent_width=1024, parent_height=1024)
        rendered = Image.open(io.BytesIO(png)).convert("RGBA")
    else:
        rendered = Image.open(source_path).convert("RGBA")
    _SOURCE_CACHE[key] = rendered
    return rendered


def dominant_ink(image: Image.Image) -> tuple[int, int, int] | None:
    """The colour a template variant is painted in, taken from the file itself."""
    arr = np.asarray(image.convert("RGBA"))
    visible = arr[..., :3][arr[..., 3] > 128]
    if visible.size == 0:
        return None
    colours, counts = np.unique(visible.reshape(-1, 3), axis=0, return_counts=True)
    best = colours[int(np.argmax(counts))]
    return int(best[0]), int(best[1]), int(best[2])


def rebuild(current: Image.Image, source: Image.Image, ink: tuple[int, int, int] | None) -> Image.Image:
    """Place the source artwork where the current artwork sits.

    The bounding box of the art inside the canvas is taken from `current` and
    reproduced exactly, so the mark occupies the same share of the frame it
    always did.  The source art keeps its own proportions and is centred in
    that box.
    """
    canvas_w, canvas_h = current.size
    target_box = art_bbox(current)
    if target_box is None:
        raise ValueError("current file has no visible pixels")
    x0, y0, x1, y1 = target_box

    src_box = art_bbox(source)
    if src_box is None:
        raise ValueError("source has no visible pixels")
    art = source.convert("RGBA").crop(src_box)
    sw, sh = art.size

    box_w, box_h = x1 - x0, y1 - y0
    scale = min(box_w / sw, box_h / sh)
    nw, nh = max(1, int(round(sw * scale))), max(1, int(round(sh * scale)))
    if abs(nw - box_w) > 1 or abs(nh - box_h) > 1:
        # The source artwork has a different shape from the artwork it
        # replaces, so it cannot fill the same box.  Letterboxing it would
        # shrink and shift the mark, which is the one thing this script must
        # never do, so the rebuild is refused instead.
        raise ValueError(
            f"the source artwork is {nw}x{nh} and cannot fill the {box_w}x{box_h} box it replaces")
    art = art.resize((nw, nh), Image.LANCZOS)

    out = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    out.paste(art, (x0 + (box_w - nw) // 2, y0 + (box_h - nh) // 2))

    if ink is not None:
        arr = np.asarray(out).copy()
        mask = arr[..., 3] > 0
        arr[..., 0][mask] = ink[0]
        arr[..., 1][mask] = ink[1]
        arr[..., 2][mask] = ink[2]
        out = Image.fromarray(arr, "RGBA")
    return out


def is_template_variant(relative_path: str) -> bool:
    """Is this one of the ink variants, whose colour is carried over rather
    than inherited?  The check is on the stem: "cursor-dark.png" does not end
    with "-dark"."""
    stem = os.path.splitext(os.path.basename(relative_path))[0]
    return stem.endswith(DARK_INK_VARIANTS) or stem.endswith(LIGHT_INK_VARIANTS)


def main() -> int:
    global OWNER, OWNER_AI
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="write the regenerated files")
    parser.add_argument("--owner-root", default=OWNER, help="the owner's icon library root")
    args = parser.parse_args()

    OWNER = args.owner_root
    OWNER_AI = os.path.join(OWNER, "AI Platforms : Models")

    targets = [t.with_owner(OWNER_AI) for t in MAC_TARGETS + IOS_TARGETS]
    print(f"{'file':<70} {'dMAD':>6} {'sharp before':>13} {'sharp after':>12} {'gain':>7} {'edge':>14}  result")
    failures = 0
    changed = 0
    rejected = 0
    skipped = 0
    for target in targets:
        path = os.path.join(REPO, target.path)
        if not os.path.exists(path):
            print(f"{target.path:<70} MISSING")
            failures += 1
            continue
        if not os.path.exists(target.resolved_source()):
            print(f"{target.path:<70} SOURCE MISSING: {target.resolved_source()}")
            failures += 1
            continue
        try:
            current = Image.open(path).convert("RGBA")
            source = render_source(target)
            ink = dominant_ink(current) if is_template_variant(target.path) else None
            rebuilt = rebuild(current, source, ink)
        except ValueError as exc:
            # A rebuild the script deliberately refuses -- a source whose
            # artwork cannot fill the box it replaces -- is a documented
            # outcome, not a read failure.
            print(f"{target.path:<70} skipped -- {exc}")
            skipped += 1
            continue
        except Exception as exc:  # noqa: BLE001 - one bad file must not stop the run
            # A single unreadable file must not leave a batch half-written or
            # suppress the summary, so it is reported and the run continues.
            print(f"{target.path:<70} FAILED -- {exc}")
            failures += 1
            continue
        drawn = drawn_device_pixels(target.path, current.size[0])
        difference, sharp_before, sharp_after = compare_at_display(current, rebuilt, drawn)
        display = drawn
        gain = (sharp_after - sharp_before) / sharp_before if sharp_before else 0.0
        band_before = edge_band(current, display)
        band_after = edge_band(rebuilt, display)
        band_text = (f"{band_before:5.2f}->{band_after:5.2f}" if band_before is not None and band_after is not None
                     else "   n/a")

        if difference > DISPLAY_TOLERANCE:
            print(f"{target.path:<70} {difference:6.2f} {sharp_before:13.3f} {sharp_after:12.3f} "
                  f"{gain:+6.1%} {band_text}  REJECTED -- different artwork as drawn")
            rejected += 1
            continue
        if (band_before is not None and band_after is not None
                and band_after > band_before + MAX_EDGE_WIDENING):
            print(f"{target.path:<70} {difference:6.2f} {sharp_before:13.3f} {sharp_after:12.3f} "
                  f"{gain:+6.1%} {band_text}  skipped -- would soften the edge")
            skipped += 1
            continue
        limit = MAC_EDGE_LIMIT if target.path.startswith("Sources") else IOS_EDGE_LIMIT
        name = os.path.basename(target.path)
        if band_after is not None and band_after > limit and name not in SOFT_BY_DESIGN:
            print(f"{target.path:<70} {difference:6.2f} {sharp_before:13.3f} {sharp_after:12.3f} "
                  f"{gain:+6.1%} {band_text}  skipped -- still over the {limit} device px limit")
            skipped += 1
            continue
        if gain < MIN_SHARPNESS_GAIN and not (band_before is not None and band_after is not None
                                               and band_before - band_after >= MIN_EDGE_GAIN):
            print(f"{target.path:<70} {difference:6.2f} {sharp_before:13.3f} {sharp_after:12.3f} "
                  f"{gain:+6.1%} {band_text}  skipped -- no gain")
            skipped += 1
            continue
        if args.write:
            rebuilt.save(path, format="PNG", optimize=True)
        changed += 1
        print(f"{target.path:<70} {difference:6.2f} {sharp_before:13.3f} {sharp_after:12.3f} "
              f"{gain:+6.1%} {band_text}  " + ("written" if args.write else "improves -- would write"))
    print()
    print(f"{changed} of {len(targets)} files improve; {rejected} rejected as different artwork; "
          f"{skipped} skipped with no gain; {failures} could not be read.")
    if not args.write:
        print("Nothing was written.  Re-run with --write to apply.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

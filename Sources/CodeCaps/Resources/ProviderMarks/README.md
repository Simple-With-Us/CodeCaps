# Provider Marks

`PlatformLogoImage` maps provider keys to the bundled files in this directory.  Standard style preserves an asset's colors, except marks identified as monochrome, which adapt to the current appearance.  Light/Dark style renders a template.  Custom style uses the owner's imported mark and falls back to the bundled standard mark when no custom mark is available.  Providers without bundled artwork use the neutral SF Symbol fallback.

MiniMax uses `minimax.png`; there is no MiniMax SVG in the active resource map.  MiniMax is treated as a monochrome mark in every style, so it adapts to Light and Dark appearances.

`claude.svg`, `openai.svg`, `grok.svg`, and `grok-bot.svg` are bundled for local display.  Antigravity uses the Gemini mark, and Grok CLI uses the Grok mark.

`grok-bot.svg` is the Grok X-mark with a small filled dot in the upper-right corner, so the bot variant reads as related but distinguishable from `grok.svg` in a row.

`gemini.svg` is the BotFleet mark with its elliptical-arc flags separated (`a14.147 14.147 0 01-4.45-3.001` → `a 14.147 14.147 0 0 1 -4.45 -3.001`) and its three redundant gradient-overlay copies of the base path dropped.  Apple's CoreSVG decoder does not tokenize the terse back-to-back arc flags the minified original used, and silently dropped most of the path — the mark rendered as an unrecognisable fragment.  A `gemini.png` rasterization used to stand in for it; with the arc fix the SVG loads correctly at every size, so the PNG is gone.

`cursor.svg` is from the Simple Icons CDN (`https://cdn.simpleicons.org/cursor`, slug `cursor`), released under CC0 1.0 Universal; the Cursor name and mark remain trademarks of their owner.  It replaces the `cursor.png` raster that was carried because BotFleet ships no Cursor SVG.

`gemini-color.png` and `gemini-mono.svg` are the two Antigravity pool marks (owner ruling 2026-09-30), keyed `google-antigravity:gemini` and `google-antigravity:third-party`.  Both come from `Google_Gemini_icon_2025.svg` in the owner's icon folder.  The colour star keeps its gradient, which is built from blurred shapes under a star mask: Apple's CoreSVG decoder draws the mask but not the blur, so the SVG is rasterized once through QuickLook (which renders it with WebKit) at 1024px, re-masked with the star path for a transparent background, and scaled to 128px.  The Third-Party star is that same star path as one solid shape, with its terse arc flags spelled out for CoreSVG, and is drawn as a template in every style so it reads near-black on Light and light grey on Dark.

October 16 update: Antigravity and its Third-Party pool now use the supplied arch in `antigravity-{color,light,dark}.png`. The older solid Gemini star is no longer the Third-Party mark. Gemini keeps its star. See `antigravity-source.md`.

October 19 update: the marks were sharp on paper and soft on screen, and the reason was measured rather than assumed.  They were not low-resolution in the sense of a small canvas — the canvases were 256px and 512px — they were *blurry upscales*.  The artwork inside each canvas was carried by a wide anti-aliased edge band, which is several device pixels of blur once the mark is drawn at 28pt on a 2x display.  A real raster of the same artwork has a one-pixel edge.  The shipped Cursor, Gemini, Grok and Claude marks measured 1.70 to 2.07 device pixels of edge at draw size; the marks that were already right sat between 0.12 and 0.47.

Twenty marks here and the three companion MiniMax files were rebuilt from a source that still carries the detail.  The geometry of every one is unchanged: the artwork's bounding box inside the canvas is taken from the file being replaced and reproduced in the new file, so the mark occupies the same share of the frame it always did and nothing moves on screen.  A `-light` or `-dark` mark keeps the ink it already had, read from the file rather than hard-coded, and a colour mark keeps the source's own colours.

The sources were the vectors this repository already ships, or a file from the owner's own icon library, and in every case the same mark:

| Mark | Source |
| --- | --- |
| Claude, Cursor, Grok, xAI, Gemini, Muse Code | this repository's own SVG |
| Muse, Muse Assist | `Muse_BlueM_TransparentBG.png`, owner library |
| Antigravity | `google-antigravity-icon.svg`, owner library |
| MiniMax (Mac and companion) | `minimax-color.png`, owner library |

Claude's colour mark is rebuilt from `claude.svg` rather than from the owner's 1517px raster of the same mark, because the vector measures sharper at draw size even though the owner's file is larger.

Several families were deliberately left alone, because there is no same-art higher-resolution copy of them to raise:

- `openai-*` and `grok-bot-*` are soft-edged artwork.  This repository ships `openai.svg` and `grok-bot.svg`, but they are *different renderings* of those marks: the OpenAI vector draws a solid knot where the shipped raster draws a hollow one, and the Grok bot vector changes the eye cutouts.  Swapping them in would be substituting artwork, not raising the resolution, so these need the owner to supply a copy of the mark that is actually shipped.
- `gemini-color*.png` is the Antigravity colour star.  The owner's copy of it is softer at the edge than the shipped file, which was re-masked with a hard star path; rebuilding it from the owner's copy would widen the edge from 0.89 to 5.43 device pixels.  It is left as it is.
- The companion's `provider-muse`, `provider-muse-assist` and `provider-muse-code` image sets do not match the owner's Muse artwork at draw size, so they are not copies of it and are left as they are.

`scripts/regenerate-provider-marks.py` rebuilds the marks.  It reports by default and writes only with `--write`.  Before it writes anything it checks that the rebuilt mark is the same artwork (the silhouette has to match at draw size, and a colour mark's palette has to match too), that the rebuild does not soften the silhouette, and that it actually sharpens something.  A source that fails any of those is reported and left alone.

`ProviderMarkDetailTests` holds the same rule as a test, so a blurry upscale cannot come back unnoticed.  It measures the same thing, against the committed assets rather than a copy the build happened to make.  A mark here may not have a silhouette edge wider than one device pixel at 28pt on a 2x display, except the two families named above, whose soft edge is the artwork's own.  The companion's marks are measured in the pixels of the screen that serves them, because a 1x file is drawn on a 1x screen and a 3x file on a 3x one; their limit is 1.60 device pixels, which is about what a 24px raster can do at all.

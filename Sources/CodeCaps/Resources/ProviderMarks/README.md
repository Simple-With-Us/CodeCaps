# Provider Marks

`PlatformLogoImage` maps provider keys to the bundled files in this directory.  Standard style preserves an asset's colors, except marks identified as monochrome, which adapt to the current appearance.  Light/Dark style renders a template.  Custom style uses the owner's imported mark and falls back to the bundled standard mark when no custom mark is available.  Providers without bundled artwork use the neutral SF Symbol fallback.

MiniMax uses `minimax.png`; there is no MiniMax SVG in the active resource map.  MiniMax is treated as a monochrome mark in every style, so it adapts to Light and Dark appearances.

`claude.svg`, `openai.svg`, `grok.svg`, and `grok-bot.svg` are bundled for local display.  Antigravity uses the Gemini mark, and Grok CLI uses the Grok mark.

`grok-bot.svg` is the Grok X-mark with a small filled dot in the upper-right corner, so the bot variant reads as related but distinguishable from `grok.svg` in a row.

`gemini.svg` is the BotFleet mark with its elliptical-arc flags separated (`a14.147 14.147 0 01-4.45-3.001` → `a 14.147 14.147 0 0 1 -4.45 -3.001`) and its three redundant gradient-overlay copies of the base path dropped.  Apple's CoreSVG decoder does not tokenize the terse back-to-back arc flags the minified original used, and silently dropped most of the path — the mark rendered as an unrecognisable fragment.  A `gemini.png` rasterization used to stand in for it; with the arc fix the SVG loads correctly at every size, so the PNG is gone.

`cursor.svg` is from the Simple Icons CDN (`https://cdn.simpleicons.org/cursor`, slug `cursor`), released under CC0 1.0 Universal; the Cursor name and mark remain trademarks of their owner.  It replaces the `cursor.png` raster that was carried because BotFleet ships no Cursor SVG.

`gemini-color.png` and `gemini-mono.svg` are the two Antigravity pool marks (owner ruling 2026-09-30), keyed `google-antigravity:gemini` and `google-antigravity:third-party`.  Both come from `Google_Gemini_icon_2025.svg` in the owner's icon folder.  The colour star keeps its gradient, which is built from blurred shapes under a star mask: Apple's CoreSVG decoder draws the mask but not the blur, so the SVG is rasterized once through QuickLook (which renders it with WebKit) at 1024px, re-masked with the star path for a transparent background, and scaled to 128px.  The Third-Party star is that same star path as one solid shape, with its terse arc flags spelled out for CoreSVG, and is drawn as a template in every style so it reads near-black on Light and light grey on Dark.

# Logo and icon inventory — which file is for what

One brand mark, many deliveries.  The vector sources live here; everything
else is generated from them or checked in for a target that cannot run a
generator.  Do not add a new logo file without a row in this table.

## The copy rule — read before duplicating anything

One source per artwork, referenced everywhere, duplicated nowhere —
**except where tooling forces a copy**:

- Xcode `.imageset` folders must contain their own file.  The iOS provider
  SVGs mirror `Sources/CodeCaps/Resources/ProviderMarks/*.svg`, and
  `codecaps-mark.imageset/codecaps-mark.png` mirrors the menu-bar icon.
  Same bytes on purpose; the catalog cannot point outside itself.
- The iOS `AppIcon.appiconset` manifest references distinct filenames that
  share pixels at different point sizes.  Same bytes on purpose; the
  manifest needs the names.
- A `-color` variant that equals its base file (e.g. `gemini-color-color.png`
  next to `gemini-color.png`) is the loader's Standard-variant lookup, not
  a spare copy.  Leave it.

Copies are caught by hash in review; the tests below are the enforcement.
Yes, this file lists files — that is unusual on purpose.  The layout is
still converging (SWU-22), and until it does, an explicit map beats
archaeology.

## Brand sources (`assets/brand/`)

| File | For |
| ---- | --- |
| `codecaps-logo-transparent.svg` | Primary mark: teal ring, red ring, dark needle + dots.  App (About, menu-bar popover, alerts), Simple-With-Us site, anything color-on-transparent. |
| `codecaps-logo-dark.svg` / `codecaps-logo-light.svg` | Monochrome variants for single-color surfaces. |
| `brand-colors.json` | Palette tokens (`--codecaps-*`), mirrored in the website CSS.  Not artwork. |

## Mac app (`assets/`, `Sources/CodeCaps/Resources/`)

| File | For | Regenerate from |
| ---- | --- | --------------- |
| `assets/icon-1024.png` | Icon MASTER.  Release script derives the `.icns` from it (`make_icon.swift`: 824 plate + shadow). | Source SVG at 1024, off-white ground `#F5F3EF`, mark at SVG fill. |
| `assets/AppIcon.icns` | Checked-in built icon; the release script prefers it over rebuilding.  Delete it to force a regen from the master. | `script/build_and_run.sh` on a Mac. |
| `Resources/CodeCapsBrandMark.png` | In-app color mark (About, Glance header, plan popup). | Transparent SVG at 512. |
| `Resources/CodeCapsMenuBarIcon.png` | Black template for the menu-bar icon and PiP header. | Black fill of the same vector at 850. |
| `Resources/ProviderMarks/*` | Per-provider triplets (`-color`, `-light`, `-dark`) plus source SVGs where the vector is owned. | `scripts/regenerate-provider-marks.py` on a Mac (needs cairosvg). |

## iOS companion (`ios/CodeCapsCompanion/`)

| File | For | Regenerate from |
| ---- | --- | --------------- |
| `Assets.xcassets/AppIcon.appiconset/` | iPhone/iPad + Mac-companion icons.  Dark ground, full-color mark.  Every file in the set is manifest-referenced; strays get deleted. | 1024 master, PIL downscale per manifest size. |
| `Assets.xcassets/provider-*.imageset/` | Provider marks as SVG (template-rendered, so only alpha matters). | Copy the matching `ProviderMarks/*.svg`. |

## Everything else

| File | For |
| ---- | --- |
| `assets/marketing/` | Owner screenshots filed for website use.  Not logos; never edit. |

## Enforcement (not this file)

`Tests/CodeCapsTests/ProviderMarkTripletTests.swift` requires every mapped
provider to resolve in every style and appearance as a real bitmap.
`ProviderMarkResolutionTests` requires the same without any custom file
present.  `ProviderMarkDetailTests` caps silhouette softness for Mac and
companion marks.  If an asset change breaks any of those, the asset is
wrong — not the test.

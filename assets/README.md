# Logo and icon inventory — which file is for what

One brand mark, many deliveries.  The vector sources live here; everything
else is generated from them or checked in for a target that cannot run a
generator.  Do not add a new logo file without a row in this table.

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

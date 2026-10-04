# CodeCaps

A macOS menu bar app for supported AI plan usage and quota windows.  It can share available readings across Macs through a collector you run.

**[Download CodeCaps →](https://codecaps.simplewithus.com/)** · **[Setup & Data Guide](https://codecaps.simplewithus.com/setup.html)** · **[From Simple With Us](https://simplewithus.com/)**

## Why This Exists

CodeCaps reads available usage and quota windows from supported AI apps and CLIs already signed in on this Mac — no provider API key is entered into CodeCaps.  Optional push and pull connections can show readings from other configured Macs in one Glance popover.

CodeCaps keeps local readings visible in the menu bar.  If you run a collector, it can also bring multiple Macs into one view.

## What It Shows

CodeCaps has two surfaces.  Nothing renders in both.

**Glance** is the menu bar popover — the two-second check.  One row per platform, each with its short and long quota windows side by side: a caption (`5h`, `7d`, `1m`), a usage bar, the percentage remaining, and the reset countdown.  A two-box switch beside the name shows either `From Mac` or `From Fleet`, one set at a time, and remembers the choice across launches; `From Fleet` groups rows under a heading band per reporting source.  On the right of the header, the **All** bell turns reset alarms on for every provider; turn it off and a faint bell appears at the left of each row, so providers can be picked one by one.  Countdowns show their two largest units (`4d 2h`, `2h 42m`); hover one for the full value and the reset time.  A row with more windows than its two meters opens to show only the rest, as more meters in the same columns.  Read-only aside from those switches, Refresh, Settings, and Open CodeCaps.

<img src="docs/screenshots/glance-light.png" width="760" alt="Glance, light">
<img src="docs/screenshots/glance-dark.png" width="760" alt="Glance, dark">

**Console** is a resizable window, sidebar split into Quotas and Settings: Quotas is an all-platforms overview plus a per-platform drill-down with search; Settings holds the five pages below.

<img src="docs/screenshots/console-light.png" width="760" alt="Console, light">
<img src="docs/screenshots/console-dark.png" width="760" alt="Console, dark">

## How A Platform's Headline Number Is Chosen

A platform can carry more than one quota window, so each surface has its own rule for which number leads:

- A collapsed row (Glance, or a Console card) shows the **fresh window closest to its cap** — lowest remaining percent — with that window's own reset countdown.
- The **menu bar** has its own picker (Menu Bar → Displayed Quota): *Most Urgent 5h*, *Most Urgent Weekly*, *Smart Pair* (the default for new installs), or a platform pinned by name.  Smart Pair shows short and weekly percentages from the same platform row when both apply.  Existing legacy automatic choices and individual window pins remain available and keep their saved selection.
- The Console's **Next Reset** tile is the soonest reset across every fresh window on every platform — not scoped to whichever is near its cap.

Antigravity sells two independent model pools, shown as two rows, **Gemini** (the colour Gemini star) and **Third-Party** (the same star in one colour).  Collapsing them used to show "Antigravity 0%" the moment the Third-Party weekly cap was spent, while Gemini still had most of its allowance.  Whenever a pool's weekly window hits zero, its 5-hour percentage is withheld — shown as `n/a` rather than a number that can't mean anything until the week rolls over.

<img src="docs/screenshots/platform-antigravity.png" width="760" alt="Antigravity, Gemini pool">

## Reset Alarms

A reset alarm is a notification, with the sound picked in Settings → Alerts & Alarms, when a quota window starts a new period:

- A provider's **largest** window — the weekly or monthly one — alarms every time it resets, even if usage never came near the cap, so you know a new week or month began.
- A **smaller** window — the 5-hour one — alarms on reset only if, during the period that just ended, it hit its cap or came within 20% of it.

Each reset alarms once.  The state behind it is saved on every refresh, so a reset that lands while CodeCaps is closed, or during an update, still alarms on the next reading, and one that already alarmed never repeats.  From Mac and From Fleet rows both alarm, keyed by provider; the same reset reported by both alarms once.

## Providers

| Provider | What Is Read | Where From |
|---|---|---|
| Claude | Quota windows (5h, weekly) | `~/.claude/.credentials.json`, or the `Claude Code-credentials` Keychain item |
| Codex | Rate-limit windows | `~/.codex/auth.json` |
| Antigravity / Gemini | Pooled Gemini and Third-Party quota, two rows (above) | The `antigravity-usage` CLI, plus an RPC to Antigravity's own language server |
| Cursor | Included-plan usage | Cursor.app's local session database (`state.vscdb`) |
| Grok CLI | Billing/credits, via Grok's CLI proxy | `~/.grok/auth.json` |
| Grok Bot | Weekly usage, via Cursor's dashboard service | Same Cursor session database, a different endpoint |
| MiniMax | Per-model and weekly remaining quota | `~/.mmx/config.json` |
| DeepSeek | Not supported | Balance-based, not window-based.  No local reader; a pulled window is filtered out too — never appears anywhere. |

None of the above ever asks for a typed credential — every reader reuses a session or file the CLI already created.

CodeCaps reads Claude Code's saved login through macOS's own `security` tool, so a fresh install needs no setup and never raises a Keychain panel of its own.  The **Allow Access To Claude Code** button on the Claude row (Console → Settings → Sources & Fleet) appears only if macOS explicitly refuses that read; press it and choose **Always Allow** in the panel macOS puts up.  On a heavily loaded Mac the Claude row may briefly read "temporarily unavailable" and recover on the next refresh.  CodeCaps only ever reads Claude Code's saved login: it never writes to, re-permissions, or removes it.

## Fleet Push And Pull

Both off by default, configured on Console → Settings → Sources & Fleet.

**Push formats** — two, chosen when pushing.  The producer id is `codecaps` (with `agent-bar` retained as a recognized legacy alias for seamless backwards compatibility).

`usage_monitor_v2` — one event per quota window:

```json
{
  "schemaVersion": 2,
  "producerId": "codecaps",
  "producerInstanceId": "Jay's MacBook Pro",
  "events": [
    {
      "eventId": "subq:anthropic:5h-window:2026-09-17T14:00:00Z:2026-09-17T14:41:00Z",
      "provider": "anthropic",
      "service": "codecaps",
      "label": "5h",
      "metricType": "quota",
      "billingMode": "actual",
      "confidence": "actual",
      "limit": 100,
      "credits": 62.0,
      "occurredAt": "2026-09-17T14:41:00Z",
      "metadata": {
        "bucketId": "5h-window",
        "isExhausted": false,
        "remainingUnknown": false,
        "scale": "percent_0_100",
        "source": "codecaps",
        "usedPercent": 38.0
      },
      "tier": "Max 20x"
    }
  ]
}
```

`generic_webhook` — a plainer envelope:

```json
{
  "format": "codecaps-quotas",
  "version": 1,
  "generatedAt": "2026-09-17T14:41:00Z",
  "machine": "Jay's MacBook Pro",
  "count": 1,
  "windows": [
    {
      "id": "anthropic:5h",
      "provider": "anthropic",
      "label": "5h",
      "status": "available",
      "isExhausted": false,
      "remainingPercent": 62.0,
      "resetAt": "2026-09-17T17:53:00Z",
      "window": "5h",
      "plan": "Max 20x",
      "occurredAt": "2026-09-17T14:41:00Z"
    }
  ]
}
```

**Pull.**  CodeCaps reads a server's aggregated windows back (`generatedAt`, `windows[]`, optional `providerGroups[]`) as `Fleet` rows.  A window is attributed to a machine by whatever `source`/`sourceApp` it carries — no machine identifier field exists yet, so indistinguishable Macs show up as one fleet origin.

**Endpoint rules.**  HTTPS required for any host; plain HTTP only for loopback (`localhost`, `127.0.0.1`, `::1`).  A URL with embedded credentials, a query string, or a fragment is rejected.

**Token storage.**  The Ingest Token and Read Token are the only two secrets stored, both in the macOS Keychain, not a config file.

## BotFleet Local Handoff

Independent of any server, CodeCaps writes a credential-free local snapshot to:

```
~/Library/Application Support/Usage Monitor/quota-windows.json
```

for other local consumers (for example, BotFleet's Usage Monitor).  `format` is `usage-monitor-local-quotas`, `version` `1`, alongside `producer` (`"codecaps"`), `generatedAt`, a `windows` array, and an optional `issues` map — no server URLs, account identifiers, or tokens; error strings are checked for anything credential-shaped first.  Written `0600` inside a `0700` directory, via an atomic rename.

## Install

**Homebrew**

```bash
brew install --cask Simple-With-Us/tap/codecaps
```

**Download**

Grab the signed and notarized `CodeCaps.dmg` from the [latest release](https://github.com/Simple-With-Us/codecaps/releases/latest).

**Updates**

CodeCaps updates itself.  Every change merged to `main` becomes a signed, notarized release, and an installed copy checks hourly, downloads it in the background, and installs it the next time CodeCaps is not in front.  Settings ▸ About has **Check For Updates…** for the impatient.  How it works, and how to roll a release back: [`docs/AUTO-UPDATE.md`](docs/AUTO-UPDATE.md).

**Build From Source**

Requirements: macOS 14+, Apple silicon or Intel, Xcode Command Line Tools with a Swift 5.9+ toolchain.

```bash
git clone https://github.com/Simple-With-Us/codecaps.git
cd codecaps
script/build_and_run.sh            # build, install to ~/Applications, and relaunch
```

Other modes: `--install` (same, no relaunch); `--dev` (separate `.dev` identifier into `dist/`, launched beside the installed copy; `--dev-stop` quits it and removes `dist/`); `--package` (universal Release, zipped into `dist/` with a SHA-256 file); `--release` (`--package`, then notarize and staple the app, and build, sign, notarize and staple `dist/CodeCaps.dmg`); `--build-only` (stage `dist/CodeCaps.app` only).

`--package` and `--release` build one universal binary for Apple silicon and Intel, verified with `lipo -archs`.  `CFBundleShortVersionString` comes from the `VERSION` file at the repo root, so cutting a release is one edit, and `CFBundleVersion` is the commit count.  `--release` notarizes through the keychain profile named by `AGENTBAR_NOTARY_PROFILE` (default `agentbar-notary`), which you create once with `xcrun notarytool store-credentials`.

`run` and `--install` keep exactly one installed copy, at `~/Applications/CodeCaps.app`: any other bundle with the same release identifier, in the usual install locations or this checkout's `dist/`, is Trashed and printed, including a copy still named `AgentBar.app`.  `CODECAPS_PRUNE_DRY_RUN=1` previews without moving anything; `CODECAPS_BUNDLE_ID` builds under a distinct identifier, for more than one checkout.

**Signing** is still evolving — take this as current-best, not a fixed contract.  The script signs with a Developer ID Application identity when available (`AGENTBAR_CODESIGN_IDENTITY`, or the first one already in your keychains), falling back to ad-hoc (`codesign --sign -`) if none is found or signing times out.  This matters beyond Gatekeeper: a stable identity keeps saved tokens (Sources & Fleet) readable across rebuilds; ad-hoc, every build gets a new identity, so a saved token needs Re-Authorize Saved Token afterward.

**Gatekeeper.**  Without a stable identity — always true for `--dev` — macOS blocks the first launch; right-click and choose Open, or `xattr -d com.apple.quarantine`.  `--package` signs for notarization but stops there; `--release` is the mode that actually submits to Apple and staples the ticket, which is how the published dmg opens with no warning at all.

**Icon.**  The master in `assets/` is a full-bleed square, and stays that way.  macOS before 26 does not mask an app icon, so `script/make_icon.swift` derives the macOS shape at build time — the master drawn inside an 824x824 rounded rectangle on a 1024 canvas, with the standard drop shadow — and the `.icns` is built from that.  The master files are only ever read.

## Settings

Console's sidebar has five Settings pages.

- **Menu Bar** — where the icon shows (menu bar, Dock, or both), plus its Displayed Quota picker (above).
- **Platforms** — platform list order, shared by Glance, Console, and the menu bar.
- **Sources & Fleet** — three groups: **This Mac** (readers on/off, one status row per platform), **Share This Mac** (push: Ingest Endpoint, Ingest Token, Payload Format, Save & Push Now), **Pull The Fleet** (pull: Quota Endpoint, Read Token, Save & Fetch Now).  Both fleet groups also offer Forget Token and, only when a saved token can't be read back, Re-Authorize Saved Token.
- **Appearance** — Light, Dark, or System; System follows your Mac's setting and is the default.
- **About** — version, push/pull/local-reader status, and a project page link.

<img src="docs/screenshots/settings-sources-fleet.png" width="760" alt="Sources and Fleet">

## Privacy

- Never asks for a provider API key; each CLI's own credential file, Keychain item, or session database is reused as-is.
- Nothing leaves this Mac until you turn on push or pull and enter an endpoint yourself; fields are empty by default.
- The Ingest Token and Read Token are the only two secrets stored, both in the Keychain.
- Endpoints are validated as above (HTTPS, loopback-only HTTP, no embedded credentials/query/fragment).
- The local handoff file carries quota readings only — no tokens, endpoints, or account identifiers.

## Provider Marks

Standard style preserves bundled brand colors except for monochrome marks, which adapt to the current appearance; Light/Dark style renders a template.  MiniMax uses `minimax.png` and is treated as monochrome.  Antigravity uses the Gemini mark, and Grok CLI/Grok Bot use the Grok marks.  `cursor.svg` is from [Simple Icons](https://cdn.simpleicons.org/cursor), CC0 1.0.  See `Sources/CodeCaps/Resources/ProviderMarks/README.md` for resource mappings and source notes.

## Development

```bash
swift build
swift test
```

See `AGENTBAR_BUNDLE_ID` above when building from more than one checkout at once.

## Logs

Build and notarization output goes to `$TMPDIR/CodeCaps-build-<pid>.log` (one
per run).  The app itself does not log to a file by default — Console.app →
"CodeCaps" is the place to look for menu / popover diagnostics, and
`log show --process CodeCaps --last 1h` for anything deeper.

## License

Apache License 2.0.

## Trademarks

Provider names and marks belong to their owners and are used only to identify the services.

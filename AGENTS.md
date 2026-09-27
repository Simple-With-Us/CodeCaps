# AGENTS.md — CodeCaps project memory

This file is binding on every agent that works in this repo.  Read it first.

Hosting and routing (apexes, hostnames, hosts, deploy paths): see [`Fleet-OPS/docs/DOMAINS-AND-ROUTING.md`](https://github.com/jaywedgeworth22/Fleet-OPS/blob/main/docs/DOMAINS-AND-ROUTING.md). Built from live Cloudflare, Vercel, Coolify, Namecheap/RDAP, and GitHub APIs by CLAUDE on 2026-09-25; refresh via `Fleet-OPS/scripts/domain-inventory/run-all.sh`.

## What this is

CodeCaps is a macOS menu-bar Swift app for **centralized monitoring and
alerting of every AI subscription plan on your Mac** — usage, quotas, and
caps across Claude, Codex, Cursor, Antigravity, Grok, MiniMax, and the
other AI CLIs already signed in.  No provider API key is entered; CodeCaps
reads the local files those CLIs already write.  The same readings can be
pushed to an endpoint you run and pulled back into one Glance popover.

The name "CodeCaps" is the brand; the app's scope is AI subscription
monitoring more broadly, not just coding subscriptions.  Owner ruling,
2026-09-21: marketing copy and taglines must not narrow the position to
"coding subscriptions" — frame it as a centralized monitor for AI plans
generally.  The teal "C-with-cap" mark in `assets/icon-1024.png` is the
app's primary brand; the orange 3D mark (Usage Monitor) is reserved for
the centralized-monitor landing surfaces (e.g. CodeCaps.SimpleWithUs.com)
where the monitoring + sync semantics are the headline.

Two SPM targets in `Package.swift`:

- `CodeCaps` (executable, 8 source files, AppKit + SwiftUI)
- `QuotaCore` (library, 14 source files, Foundation + SQLite)

macOS 14+.  Single platform.  External integrations: BotFleet on-disk
handoff at `~/Library/Application Support/Usage Monitor/quota-windows.json`,
HTTP push (`QuotaPublisher`, v2 ingest envelope), HTTP pull (`QuotaClient`,
`FleetPipeline`).

## Build and test

```bash
swift build
swift test
```

The `script/build_and_run.sh` script is the canonical release pipeline — it
bundles, codesigns, notarizes, staples, builds a DMG, and writes a ZIP + sha.
Run it once to read the contract; it is also the only path that knows the
icon-making and notarial profile.

`AGENTBAR_BUNDLE_ID` overrides the default bundle id when more than one
checkout is on the same Mac — keep it stable per worktree.

## Branch and worktree conventions

- Default branch is `main`.
- MM (MiniMax) worktrees live at `~/apps/codecaps-mm-<lane>` and branches at
  `mm/<lane>`.  Never edit in `~/Code/codecaps` (daemon resets it).
- The local handoff file at
  `~/Library/Application Support/Usage Monitor/quota-windows.json` is shared
  with the running instance; write through it only via
  `LocalQuotaSnapshot.write` (private 0600 + rename), never with
  `Data.write(.atomic)`.

## Tests

- `Tests/QuotaCoreTests/` covers the readers and the publisher; one test
  file per reader is the convention.
- `Tests/CodeCapsTests/` covers only three files:
  `SettingsMigrationTests`, `SourceRankingTests`, `TokenStoreTests`.  The
  remaining CodeCaps source files have no coverage — every new view or model
  should add at least one test.

## Code style

- Every QuotaCore reader returns a `LocalQuotaResult`; never throws to the
  caller.
- Tokens are never logged; provider issues that pass `LocalQuotaSnapshot.safeIssues`
  reach the file.
- Two sentences in one user-visible string use `sentenceGap` (the
  no-break-space-plus-space defined in `TokenHygiene.swift`); never a bare
  space.  Two literal ASCII spaces is the file convention; Markdown chat
  follows the same rule per fleet.

## Reviewer / merge

- One PR per audit batch or feature.  Auto-merge (`gh pr merge --squash --auto`)
  is the default once CI is green and the owner has not asked to drive.
- Audit batches use the `audit-#N` branch naming and ship in
  `docs/audits/<date>-<topic>.md`.
- UI changes must be covered by automated visual verification where feasible: Playwright screenshot assertions for web surfaces, `xcrun simctl io booted screenshot` for iOS simulator. The owner never takes manual screenshots and does not run local UI preview sessions. Native Mac app UI is verified through code review and CI.


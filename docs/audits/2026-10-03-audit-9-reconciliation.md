# Audit 9 Reconciliation — 2026-10-03

Scope: [GitHub #19](https://github.com/Simple-With-Us/CodeCaps/issues/19) against `origin/main` at `0f4bbc8`.  Open PRs #139 and #142 are pending, not counted as merged.  This batch changes only the remaining safe code and documentation items; it does not claim a cause for the Grok Heavy spike.

| Finding | Status and evidence |
|---|---|
| A9-01–03 | Fixed in PR #20.  Appearance says System is the default (`SettingsViews.swift`); the notary log is printed (`script/build_and_run.sh`); signing no longer uses a `--deep` signing fallback. |
| A9-04 | Retracted in [#19's audit revision](https://github.com/Simple-With-Us/CodeCaps/issues/19).  Submission failures already stop before stapling. |
| A9-05 | Fixed in PR #22.  `LocalQuotaReader.readGrok` checks flat and nested token paths. |
| A9-06 | This batch aligns `QuotaWindow.normalizedForExport()` and `QuotaWindowSnapshot` when an exhausted source reports a nonzero last reading.  `LocalQuotaSnapshotTests` covers exported and displayed status. |
| A9-07 | Fixed in PR #121.  `ConsoleSidebar` has focus and `.onMoveCommand` up/down navigation.  The October 3 comment on #19 that lists this as open is stale. |
| A9-08 | Open.  `GlanceViews.glanceRowStatusText` still searches issue prose for permission and sign-in words.  A structured reader state and corresponding tests belong in a separate UI/model PR after #139/#142 settle. |
| A9-09 | Covered by `ClaudeConsentTests` and `ClaudeOAuthParserTests`, including the prompt-free consent path. |
| A9-10, A9-24–25 | The original file-count claim is stale: Console, Glance, and Monitor behavior now have test files.  This does not prove every merge, freshness, or keyboard interaction.  Any new gap should name a missing behavior, not demand a file by its old name. |
| A9-11, A9-26 | The filter case-folds reasons and detects `bearer=` and `-----begin` in `LocalQuotaSnapshot.swift`.  This batch adds literal `Bearer=` and uppercase `-----BEGIN RSA PRIVATE KEY` regression cases. |
| A9-12 | Contract documented at the two header writes in `QuotaPublisher.swift`.  The publisher still sends `Authorization: Bearer` and `x-usage-ingest-token`; removing either requires proof of backend acceptance and logging behavior. |
| A9-13–15, A9-27–29 | Fixed in PRs #20/#22: `AGENTS.md`, `docs/EFFORT-LOG.md`, both `codecaps` producer identifiers, and README log and local handoff documentation are present. |
| A9-16 | This batch passes the path as an `osascript` argument and reads it from `argv`, so quotes inside a path cannot change the AppleScript source. |
| A9-17 | Superseded by the two-cadence Glance meter layout, shipped in PR #74.  The original 72/106-point branch no longer exists. |
| A9-18 | The old `compactResetCountdown` glyph helper has no call sites.  The live Glance meter supplies a spoken reset value through its accessibility element. |
| A9-19–20, A9-22 | Documented or accepted observations, not demonstrated remaining failures: second-instance warning, bounded Antigravity probes, and low-frequency process spawning. |
| A9-21 | Maintenance risk remains.  `AntigravitySummaryReader.swift` matches `language_server|language-server|/agy( |$)` with `pgrep -f`; a future process rename could require an update.  No speculative process-detection rewrite is included. |
| A9-23 | Fixed in PR #20.  README has build and app log locations. |

The [redesign umbrella #25](https://github.com/Simple-With-Us/CodeCaps/issues/25) also needs a separate truth pass.  Its two-window Glance rows, menu-bar presets, and runaway alerts have shipped; the active MiniMax artwork is `minimax.png`, but the requested 2–3 alternative design proposal is not evidenced here.  Local sample history in pending PR #139 can explain quota movement, but it cannot attribute a Grok Heavy spike to a particular agent or activity.  Do not close that investigation on an inference about typical user activity.

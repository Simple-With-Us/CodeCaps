# CodeCaps Comprehensive Audit — 2026-09-20

Scope: every Swift file in `Sources/CodeCaps/` and `Sources/QuotaCore/`, the
build script, the tests, the docs site, and the 8 already-open GitHub issues
(issues were not duplicated).

App size: 44 Swift files, ~10,487 LOC.  Two SPM targets
(`CodeCaps` executable + `QuotaCore` library).  Single platform (macOS 14+).
External integrations: BotFleet on-disk handoff at
`~/Library/Application Support/Usage Monitor/quota-windows.json`, an HTTP push
endpoint (v2 ingest), and an HTTP pull endpoint.

Numbering continues from the prior audit batches.  The previous audits (#4–#8)
shipped in PR #18.  Umbrella GH issue:
[#19](https://github.com/Simple-With-Us/codecaps/issues/19).  Board item
filed under app `codecaps`, kind `github-issue`.

---

## High severity — wrong behavior or user-visible bug

- **A9-01 — Stale "Light is the default" footer in Appearance settings.**
  `Sources/CodeCaps/SettingsViews.swift:734` still says "Light is the default."
  after commit `3b24eb8` (PR #18) reversed the default to System on
  2026-09-19.  The user-visible copy and the default disagree.  **Fix:** rewrite
  the footer to match the new default.

- **A9-02 — `notarytool log` output is discarded.**
  `script/build_and_run.sh:462` writes
  `xcrun notarytool log "$submission" ... >&2 2>/dev/null || true` —
  `>&2` (stdout → stderr) immediately followed by `2>/dev/null` (stderr
  → dev/null) sends the rejection log to the bit bucket.  The user sees
  "notarization was not accepted" but never sees the rule Apple rejected.
  **Fix:** drop `>&2 2>/dev/null`, e.g. `>&2` (correctly, stderr-only) or
  `2>&1 | tee -a "$LOG"`.

- **A9-03 — `--deep` codesign ad-hoc fallback is undocumented.**
  `script/build_and_run.sh:198-200` uses `codesign --force --deep --sign -`
  when no identity is configured.  The policy comment at `:150-152` says
  nested code is signed before its container to replace `--deep`, but does
  not call out that the ad-hoc fallback still uses `--deep`.  **Fix:** add a
  comment at the fallback explaining why `--deep` is OK there (signing the
  whole bundle in one shot, no nested signing without an identity).

- **A9-05 — `LocalQuotaReader.readGrok` only finds `key` in the outer dict.**
  `Sources/QuotaCore/LocalQuotaReader.swift:172-194` uses a
  `root.count == 1 && profiles.count == 1` heuristic to pick the inner profile,
  but when Grok's session JSON has multiple top-level keys
  (`tokens`, `expires_at`, …), the function takes `root` and then
  `firstString(root, "key")` returns `nil`.  **Fix:** look for `key` /
  `tokens` keys explicitly and walk both shapes.

- **A9-06 — `QuotaWindowSnapshot.status` derived twice with different rules.**
  `Sources/QuotaCore/QuotaModels.swift:283-309` sets `status = .exhausted` when
  `window.isExhausted || remainingPercent == 0` in init.  `normalizedForExport`
  re-derives status from percentage only, so a window with
  `isExhausted == true` but `remainingPercent == 0.5` (rounded up from 0.49)
  publishes `.exhausted` upstream and `.available` to the file — the same
  window reports two different statuses depending on which path you read.
  **Fix:** derive once and reuse.

## Medium severity — robustness, edge case, or maintenance burden

- **A9-07 — Console sidebar arrow-key navigation lost** (re-frames GH issue
  #9).  `Sources/CodeCaps/ConsoleViews.swift:262-269` uses Buttons inside a
  List to dodge the macOS 14 selection bug, but no replacement arrow-key
  handler was added.  **Fix:** add an `@FocusState` arrow-key handler so the
  sidebar behaves like a real List.

- **A9-08 — `trailingText` in Glance matches error substrings heuristically.**
  `Sources/CodeCaps/GlanceViews.swift:226-229` does
  `issue.contains("permission")` / `issue.contains("sign in")` to decide
  "needs permission" / "not signed in".  Brittle when the issue copy is
  rewritten.  **Fix:** pass structured consent / auth state to the view
  instead of pattern-matching.

- **A9-09 — `ClaudeCredentialSource` has no tests.**  The 343-line file is the
  only Keychain-touching code in the repo and has 0 unit-test coverage.  Issue
  #13 (Keychain panel during background refresh) is unprovable without
  coverage.  **Fix:** extract a pure `decodeCredentialsJSON` helper and
  test the JSON decode / expiry / error paths.

- **A9-10 — CodeCaps target has 5 untested source files.**  Only 3 test files
  (`SettingsMigrationTests`, `SourceRankingTests`, `TokenStoreTests`) cover 8
  source files.  `MonitorModel.swift` (953 lines), `ConsoleViews.swift` (734),
  `GlanceViews.swift` (412), `QuotaComponents.swift` (570), `AntigravityDisplay.swift`,
  and `PlatformLogo.swift` have no tests.  **Fix:** seed at least one
  `MonitorModelTests.swift` with the merge / sort / freshness rules.

- **A9-11 — `LocalQuotaSnapshot.safeIssues` regex misses `bearer=` (no space)
  and uppercase `-----BEGIN`.**  `Sources/QuotaCore/LocalQuotaSnapshot.swift:128-168`
  catches `"bearer "` (with trailing space) and `"-----begin"` (lowercase).
  Tokens with `Bearer=` (header line shape) or `-----BEGIN RSA PRIVATE KEY`
  pass.  **Fix:** add `bearer=` and case-fold both markers, and add the
  uppercase `-----BEGIN`.

- **A9-12 — `QuotaPublisher` sends the token in two headers.**
  `Sources/QuotaCore/QuotaPublisher.swift:120-123` sets both `Authorization:
  Bearer …` and `x-usage-ingest-token: …`.  The dual channel is intentional
  but undocumented; if a server logs `Authorization`, the token leaks.  **Fix:**
  add a doc comment, and gate `Authorization` behind a setting once one exists.

- **A9-13 — Missing `AGENTS.md` (project memory) and `EFFORT-LOG.md`.**  Fleet
  rule: every repo carries both.  **Fix:** add minimal
  `AGENTS.md` (build, test, lane conventions) and `EFFORT-LOG.md`
  (running log of work units).

## Low severity — polish, consistency, doc

- **A9-14 — `QuotaPublisher.producerId = "agent-bar"` stale brand.**  The wire
  identifier is still "agent-bar" after the rename to CodeCaps.  Downstream
  (BotFleet, Usage Monitor) parses this to recognise the producer.  Changing
  it is a wire break.  **Defer to owner decision;** keep the constant, but
  rename in the next major so consumers can be told in lockstep.

- **A9-15 — `LocalQuotaSnapshot.producerName = "agent-bar"` same issue.**
  `Sources/QuotaCore/LocalQuotaSnapshot.swift:8`.  Same wire break risk; same
  defer.

- **A9-16 — `osascript` path is unquoted in the dist-clean step.**
  `script/build_and_run.sh:375`.  `$path` may contain a `"` and break the
  AppleScript.  Low-risk today (paths are `$HOME/Applications/CodeCaps.app`)
  but brittle.  **Fix:** use `quoted form of POSIX file`.

- **A9-17 — `GlanceViews.swift:267` column-width logic is asymmetric.**
  `if percent != nil` uses the 72pt column; `else` uses the 106pt.  When
  `percent != nil` but `driving?.remainingPercent == nil` (issue is set but
  driving has no percent), the row lands in the 72pt branch with empty
  leading text — looks like a layout gap.  **Fix:** base the width on
  `driving?.remainingPercent`, not the local `percent`.

- **A9-18 — `CompactResetCountdown` returns `"⟳"` for past resets.**
  `Sources/CodeCaps/QuotaComponents.swift:112` returns the Unicode arrow
  glyph when `seconds <= 0`, but no accessible label — VoiceOver reads
  nothing.  **Fix:** `accessibilityLabel("reset pending")`.

- **A9-19 — `AppDelegate.swift` "second instance" warning never quits.**
  `Sources/CodeCaps/AppDelegate.swift:11-16` shows the warning but the
  process doesn't exit if the user dismisses.  Acceptable; flag for
  documentation only.

- **A9-20 — `AntigravitySummaryReader` makes 4 candidate PIDs × 2 schemes =
  8 requests per refresh.**  `Sources/QuotaCore/AntigravitySummaryReader.swift:92-113`.
  Each is bounded at 3s, so worst-case 24s — but the loop also pgreps
  and lsofs first.  **Fix:** add an early break once a successful response is
  seen (already does this — the `return data` inside the inner loop is fine).
  Doc-only.

- **A9-21 — `AntigravitySummaryReader` hardcodes `pgrep -f "language_server…"`
  pattern.**  `Sources/QuotaCore/AntigravitySummaryReader.swift:64`.  If the
  binary renames, this silently stops finding it.  **Fix:** factor the
  pattern into a static and document it.

- **A9-22 — `BoundedQuotaProcess` re-creates `pgrep` per call.**
  `Sources/QuotaCore/BoundedQuotaProcess.swift` spawns the helper each call.
  Acceptable for low-frequency quota refreshes; flag only.

- **A9-23 — README does not say where logs live.**  When something breaks,
  users have no obvious place to look.  The build script writes to
  `$TMPDIR/CodeCaps-build-<pid>.log`.  **Fix:** a one-line "Logs" section in
  the README pointing to it.

## Test gaps that are now blockers

- **A9-24 — Add `MonitorModelTests.swift`.**  Test the merge / sort /
  freshness rules that are scattered across `MonitorModel.swift`.
- **A9-25 — Add `ConsoleViewsTests.swift`.**  Test the `pageTitle` /
  `settingsTitle` / arrow-key navigation behavior.
- **A9-26 — Add `LocalQuotaSnapshotTests.swift` for the regex markers.**
  Existing test file covers the happy path; the dangerous-copy regex is not
  tested.  Add cases for `bearer=`, `-----BEGIN RSA PRIVATE KEY`, `/Users/jay/`,
  `xai-abc`, etc.

## Documentation gaps

- **A9-27 — No `AGENTS.md`.**  (Same as A9-13.)  Add minimal one.
- **A9-28 — No `EFFORT-LOG.md`.**  (Same as A9-13.)  Add minimal one.
- **A9-29 — README does not mention the local handoff path.**
  `~/Library/Application Support/Usage Monitor/quota-windows.json` is the
  integration contract with BotFleet — readers of the README who want to
  point another consumer at it cannot find the path.  Add a "Local Handoff"
  section.

---

## Tier-1 implementation plan (this PR)

Implement the safe, high-value fixes that do not touch wire formats or require
owner decision:

1. A9-01 — Rewrite the stale footer in SettingsViews.swift:734.
2. A9-02 — Drop `>&2 2>/dev/null` from build_and_run.sh:462 so the rejection
   log reaches the user.
3. A9-03 — Add a comment to the `--deep` fallback at build_and_run.sh:198
   explaining why it's the one path that uses it.
4. A9-13/27/28 — Add `AGENTS.md` and `EFFORT-LOG.md`.
5. A9-23 — Add a one-line "Logs" pointer to README.

**A9-04 was retracted after the script was re-read.**  `notarize_file`
already checks both `submit`'s exit status (`:451`) and the returned JSON
status (`:460`), and `exit 1` short-circuits before the caller staples.  The
rejection path is correct; only the rejection-log visibility (A9-02) was
broken.

The remaining items (A9-05 through A9-22, A9-24 through A9-26, A9-29) are
queued for the next lane(s).  A9-14 and A9-15 require an owner call before
any code changes.

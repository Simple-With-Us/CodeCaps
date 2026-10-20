# Automatic Provider Details (CC-174)

Compared CodeCaps main `d1e4fdd5e` with Paseo `068f272a00ffef3f00ec30ec4cfa3a631be97624`.  The screenshots demonstrate provider-reported data that CodeCaps should retain automatically.

## Evidence And Changes

| Information | Source | CodeCaps Change |
|---|---|---|
| Codex plan | `GET https://chatgpt.com/backend-api/wham/usage`, `plan_type` | Prefer the current usage response over older login-file metadata |
| Claude plan multiplier | Existing Claude OAuth record, `subscriptionType` and `rateLimitTier` | Display Max 5x / Max 20x when an explicit numeric multiplier is present |
| Codex credits | Usage response `credits.balance` | Show a textual balance, including an explicit zero; missing is unknown |
| Claude extra usage | Usage response `extra_usage.is_enabled` | Show enabled / disabled, independently of subscription exhaustion |
| Claude account | Best-effort `GET https://api.anthropic.com/api/oauth/profile`, `account.email` | Show the active account locally; profile failure preserves quota readings |
| Codex account | Usage response `email`, then existing access / ID token email claims | Show the active account locally; decoding claims is display-only |
| Codex additional pools | `additional_rate_limits[].rate_limit` plus `limit_name` and `metered_feature` | Read nested primary / secondary windows with separate IDs and labels |
| Code review allowance | `code_review_rate_limit` | Read its separate windows without making a scoped cap exhaust the whole subscription |

Source references:

- [Claude reader and schemas](https://github.com/getpaseo/paseo/blob/068f272a00ffef3f00ec30ec4cfa3a631be97624/plugins/claude-usage-source/server/usage.ts)
- [Codex reader and schemas](https://github.com/getpaseo/paseo/blob/068f272a00ffef3f00ec30ec4cfa3a631be97624/plugins/codex-usage-source/server/usage.ts)
- [Paseo usage card](https://github.com/getpaseo/paseo/blob/068f272a00ffef3f00ec30ec4cfa3a631be97624/packages/app/src/usage/card.tsx)

This is an independent Swift implementation informed by the provider response shapes.  No Paseo runtime or source was imported.

## Presentation And Data Boundaries

Automatic plans appear in the compact row subtitle and the Console card.  Existing custom subtitles and explicit plan overrides retain precedence; enabling cost/renewal with an empty custom plan uses the detected plan.

Account, credits and extra usage appear in the local Console card and expanded compact row, including while the subscription is capped.  Balances do not become quota windows and cannot trigger reset alarms or change subscription percentages.

`ProviderUsageDetails` is local-only and excluded from `QuotaWindow.CodingKeys`.  Email, balances and extra usage state are absent from the handoff file and fleet publisher; existing `planName` continues using the established wire field.  Offline tests use synthetic credentials and responses; no live credential output is required.

## Remaining Scope

This change covers the concrete Claude / Codex gaps in the screenshots.  Other provider windows already have readers, but this is not a claim of complete Paseo parity across every provider, credential store or account.  Pi/OpenCode/OMP account discovery, custom Codex home locations, cross-device supplemental details and generic Claude surface quotas are outside this patch.

## Validation

- `swift build --jobs 4`: passed.
- `swift test --jobs 4`: passed (468 tests in the final test process; live / visual opt-in tests skipped).
- Focused reader regression: 21 tests, one live-Keychain opt-in skipped, zero failures.
- Focused metadata / presentation tests: passed; the final rerun also covers flat pools with shared labels.
- Independent diff review: found expanded pool grouping edge cases; fixed with regression coverage.
- No claim of live installed-app acceptance or deployment; CI and release state are recorded on the PR.

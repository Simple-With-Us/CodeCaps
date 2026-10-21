# iOS App Store listing and approval readiness (CC-182)

Staged 2026-10-21 by OPENCODE against app 6814623846 (`com.simplewithus.codecaps.ios`),
version 1.0.235 (`0352a3ae`).  Everything below is staged, nothing submitted.
The owner presses Submit for Review.

## What was staged

- Description rewritten (3,304 chars): differentiators verified in-repo —
  kept usage history, anomaly vs average + peak, runaway-before-gone, widgets,
  PiP (Mac), provider marks; added vendor mid-cycle reset detection, five alert
  categories with per-kind delivery + sound on iPhone, source-scope
  disagreement flag, no-API-keys; Getting Started now mirrors the real UI
  (Mac: Push Quotas to a Server; iOS: CodeCaps Settings → Sources →
  Mac Sync Endpoint, Endpoint URL + Sync Bearer Token).  No superlatives,
  no pricing claims, no unshipped features (Running Out forecast is Mac-only
  and stays unmentioned; fleet plan-mismatch popups in open PR #277 stay
  unmentioned).
- Keywords (96/100): added `minimax,grok,monitor`, dropped `burn,pace`.
- Subtitle set: `AI Quota Monitor & Alerts` (25/30).  Promotional text kept
  (165/170, accurate).

## Verified already in place (no change)

- Age rating FOUR_PLUS with a complete questionnaire at app level; copyright
  `2026 Simple With Us`; privacy policy URL live; build 235 VALID and
  APP_STORE_ELIGIBLE; `usesNonExemptEncryption=false`; review contact +
  demo-not-required + empty-state notes on the version's review details.

## Remaining before Submit (not this item)

1. Screenshots — MM's PR #271 owns capture + upload; coordinate, do not duplicate.
2. IDFA one-tap `No` at submit (no API surface for it; app serves no ads).
3. Privacy nutrition labels — no API surface found; confirm in ASC UI against
   `ios/CodeCapsCompanion/AppStore/privacy-answers.md` before submit.
4. Submit for Review itself — owner action.

## Re-verify before any re-stage

Every bullet above names a shipped behavior.  If an alert kind, provider, or
setup step changes, update the description in the same PR.

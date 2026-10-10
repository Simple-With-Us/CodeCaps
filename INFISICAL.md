# INFISICAL.md — CodeCaps

Infisical is the sole source of truth for CodeCaps' app-level settings: secrets, environment config, and tunable settings knobs.  Per-user settings stay in the app's own store and never go in Infisical.  This file is the contract; `AGENTS.md` points here and every future change to settings follows it.

## Project

- Project ID must be entered explicitly under Settings → Infisical Sync.  There is no built-in project or migration fallback.  Legacy two-field identities are not activated; the owner enters the three-field setup.
- Every build reads `prod`, and only `prod` (`InfisicalSettings.defaultEnvironment`).  The dev and staging environments are retired (owner, 2026-10-10), so a `.dev` build reads `prod` too; `TokenStore` and `InfisicalIdentityStore` still scope Keychain items per build.  The client refuses to log in, read or write for any other environment, and a test pins that.
- REST surface used: universal-auth login → project/environment metadata verification on explicit setup Save → three named `GET /api/v3/secrets/raw/{name}` requests → `PATCH` / `POST /api/v3/secrets/raw/{name}` for write-through.  The app never lists root secrets or fetches an unrelated secret value.  A missing managed key (404) remains unset, so its existing local/default behavior applies; any other read failure keeps the entire last-known-good cache.  Implemented with zero new dependencies in `Sources/QuotaCore/InfisicalSettings.swift` (`URLSession` only).

## Key Inventory

| Key | Env | Sensitivity | Default | Notes |
|---|---|---|---|---|
| `PULL_ENDPOINT` | prod | Non-sensitive (service URL) | `https://usage.jays.services/api/quota-windows` (not yet set in prod) | Service URL the Mac app pulls other machines' quota windows from.  Migrated from the `endpoint` UserDefaults key. |
| `PUSH_ENDPOINT` | prod | Non-sensitive (service URL) | Empty — to be filled by the admin | Service URL the Mac app pushes this Mac's quota windows to.  Migrated from the `syncEndpoint` UserDefaults key. |
| `SETTINGS_REFRESH_SECONDS` | prod | Non-sensitive (knob) | `300` (not yet set in prod) | Background refresh cadence for this cache, tunable via Infisical itself.  Clamped to a 60-second floor so a typo cannot hot-loop the timer. |

The `prod` environment holds no CodeCaps keys yet: the two non-sensitive defaults above were only ever seeded in the now-retired `dev` environment and were not copied over.  Until the admin sets them in `prod`, a missing managed key stays unset and the app's local defaults apply.  `prod` values are set by the admin and never invented.  Secret keys are documented as "to be filled by admin" and left empty — no secret value is ever invented, guessed, or copied into the project.

## What Lives Here Versus What Does Not

**In Infisical (app-level):** the two fleet endpoint URLs and the refresh cadence above.  Future app-level knobs (thresholds, intervals, feature flags) go here too.

**Explicitly out — per-user settings stay in the app's own store:**
- Every display preference (`displayMode`, `menuBarStyle`, mark styles, `appearance`, `glanceView`, platform order, source ranking, disabled sources, high contrast) → `UserDefaults`.
- Reset alarms (sound, cadence, message), anomaly multipliers, burn-rate alert toggles → `UserDefaults`.
- The Read Token and Ingest Token → the Keychain (`TokenStore`), never Infisical.  They are the owner's per-server credentials; the Keychain is their correct home and Infisical only ever sees service URLs.
- The Infisical client identity itself (universal-auth client ID + secret + selected Project ID) → the Keychain (`InfisicalIdentityStore`), provisioned once by the owner under Settings → Infisical Sync.  A shipped app cannot embed a client secret, so there is no fallback identity.

**Explicitly out — build-time constants:** `SUFeedURL` / `SUPublicEDKey` (Sparkle, baked into the signed bundle — do not move these), provider API endpoints (`api.anthropic.com`, etc.), bundle identifiers, local credential file paths.

**iOS companion:** the companion cannot safely hold a client secret, so it never talks to Infisical.  The Mac app owns the Infisical read; the companion keeps reading quota data through its existing API (`https://usage.jays.services/api/quota-windows` with its read token).  No companion code changed for this rollout.

## The Runtime Contract

1. **Load at startup.**  `AppDelegate.startInfisicalSync` installs persisted configuration synchronously at launch, then asynchronously runs `refresh()` → adopt endpoints.  Revision fences discard completions from a retired setup.  A failure never blocks launch or the main thread; the app keeps its local values.
2. **Never fetch per-request.**  All runtime reads go through `InfisicalSettings.value(for:)`, a synchronous memory-only read.  The only network calls are the startup load, the refresh timer, `applicationDidBecomeActive`, and explicit admin Save actions.
3. **Background refresh.**  A one-shot timer rescheduled after every fire (so a cadence change in Infisical takes effect next cycle), plus a refresh on `applicationDidBecomeActive`.  A failed refresh is recorded on `lastError` (visible under Settings → Infisical Sync) and the last-known-good cache keeps serving — staleness is safer than an outage.
   The three named reads complete before the cache changes; partial success never replaces it.  Infisical sync remains optional and separately provisioned.  Reading settings does not turn on quota push or pull.
4. **Write-through on admin save.**  Saving the pull/push endpoint in Settings, or any managed key under Settings → Infisical Sync, writes to Infisical FIRST via `InfisicalSettings.set` and only then updates the local cache.  A failed Infisical write throws and the save is rejected with the error shown inline — the cache and Infisical never diverge silently.
5. **Adoption, not clobbering.**  After a load/refresh, `MonitorModel.adoptInfisicalEndpointsIfUnset` fills in an endpoint only when the owner never set one locally (key absent).  A deliberately cleared field (stored as `""`) is never overridden.

## Admin Gating

CodeCaps is a single-user local app: the owner is the only user and therefore the admin.  The gate is a deliberate no-op, documented here rather than implemented as a parallel auth system.  The settings surfaces (Settings → Sources & Fleet, Settings → Infisical Sync) are reachable only on his own Mac.

## Provisioning

1. In Infisical, create a machine identity scoped to the CodeCaps project, the `prod` environment, and the root secret path.  Grant read access at that scope; grant write access only if this identity will save settings from the app.  Use the narrowest permissions supported by the Infisical policy.  The client requests only the three managed keys by name, but that request pattern alone does not restrict what an overprivileged identity could access.  Copy its client ID and secret.
2. Open Settings → Infisical Sync, enter Client ID, Client Secret, and Project ID, then press Save Setup.  With an unchanged Client ID, leaving Client Secret blank retains the saved secret.  Save verifies login, project/environment metadata, and the three managed-key reads before atomically persisting all three fields in one Keychain record and switching the active cache.  A failed validation or Keychain write leaves the previous setup and cached values active.  An existing project with no managed keys is valid; a missing or inaccessible project is not.  Project metadata access is needed for setup validation; routine refresh remains the existing three named reads.
3. Set `PULL_ENDPOINT` / `PUSH_ENDPOINT` / `SETTINGS_REFRESH_SECONDS` under Managed Keys (or directly in Infisical); the app picks them up on the next refresh.

## Switching and forgetting a setup

Changing Project ID never carries cached values or status from the previous destination into the new cache.  Existing local endpoint overrides, quota modes, read/ingest tokens, and provider sign-ins remain untouched.  In-flight old reads, writes, and validation cannot install stale cache/status or initiate a follow-up create after a switch or Forget.  An already submitted HTTP write cannot be recalled, but its response cannot affect the new setup.

Forget Setup atomically deletes the single stored identity/destination record.  Legacy two-field records are never loaded.  Keychain failures retain a complete prior three-field setup.  Failed saves and clears restart the prior setup’s refresh cycle.  No credential-file fallback is added.

## Rotating A Value

Edit the key in Infisical (dashboard or API) — the app picks it up within one refresh interval, or press Reload Now under Settings → Infisical Sync.  To rotate the client identity itself: save the new identity under Settings → Infisical Sync (old Keychain items are overwritten), then revoke the old identity in Infisical.  Tokens in the Keychain rotate through the existing Re-Authorize / Forget flows and are unaffected by this file.

## Hard Rules

- No secret values in code, logs, PR bodies, or chat — names and metadata only.
- No per-request Infisical fetches anywhere in the refresh, render, or event paths.
- No per-user settings migrated into Infisical, ever.
- The local user is the admin; there is no separate admin role to invent.

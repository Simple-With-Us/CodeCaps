# INFISICAL.md — CodeCaps

Infisical is the sole source of truth for CodeCaps' app-level settings: secrets, environment config, and tunable settings knobs.  Per-user settings stay in the app's own store and never go in Infisical.  This file is the contract; `AGENTS.md` points here and every future change to settings follows it.

## Project

- Infisical is optional.  With no selected read source, CodeCaps keeps its local settings and does not contact Infisical.
- Setup contains multiple labeled bindings, each with an explicit project ID, environment, folder path, Infisical site, authentication method, and either read or write purpose.  Each binding has its own credential.
- Service tokens are the recommended new setup.  The complete `st.<id>.<secret>` token is sent as `Authorization: Bearer st.<id>.<secret>`; it is never reduced to its final segment and never sent through universal-auth login.  Infisical enforces the token's actual environment/path scopes and permissions.
- Machine identities remain supported through universal-auth client ID and secret.  Existing version-1 identities migrate in memory to the same machine-auth read binding at `prod` and `/`, without a startup Keychain rewrite or automatic write selection.
- The owner selects one read settings source and an independent write binding.  A write binding must explicitly have write purpose and match the selected read source's site, project, environment, and folder.  Read access never implies write access, even when the underlying credential has broader server permissions.
- The default environment for a new form or migrated identity remains `prod`; newly configured bindings can explicitly choose another environment and folder.
- Runtime REST operations remain the three named `GET /api/v3/secrets/raw/{name}` reads and `PATCH` / `POST` writes.  Machine-auth setup also verifies project/environment metadata.  Service-token setup validates through the named reads because a scoped service token may not have project-metadata permission.  Saving a write binding does not perform a probe write or claim that server write permission was verified.

## Key Inventory

| Key | Env | Sensitivity | Default | Notes |
|---|---|---|---|---|
| `PULL_ENDPOINT` | prod | Non-sensitive (service URL) | `https://usage.jays.services/api/quota-windows` (not yet set in prod) | Service URL the Mac app pulls other machines' quota windows from.  Migrated from the `endpoint` UserDefaults key. |
| `PUSH_ENDPOINT` | prod | Non-sensitive (service URL) | Empty — to be filled by the admin | Service URL the Mac app pushes this Mac's quota windows to.  Migrated from the `syncEndpoint` UserDefaults key. |
| `SETTINGS_REFRESH_SECONDS` | prod | Non-sensitive (knob) | `300` (not yet set in prod) | Background refresh cadence for this cache, tunable via Infisical itself.  Clamped to a 60-second floor so a typo cannot hot-loop the timer. |

Missing managed keys remain unset, so the app's existing defaults apply.  Credentials and values are supplied by the owner, never invented or copied from unrelated projects.  Bindings do not create service tokens, machine identities, or new server-side grants.

## What Lives Here Versus What Does Not

**In Infisical (app-level):** the two fleet endpoint URLs and the refresh cadence above.  Future app-level knobs (thresholds, intervals, feature flags) go here too.

**Explicitly out — per-user settings stay in the app's own store:**
- Every display preference (`displayMode`, `menuBarStyle`, mark styles, `appearance`, `glanceView`, platform order, source ranking, disabled sources, high contrast) → `UserDefaults`.
- Reset alarms (sound, cadence, message), anomaly multipliers, burn-rate alert toggles → `UserDefaults`.
- The Read Token and Push Token → the Keychain (`TokenStore`), never Infisical.  They are the owner's per-server credentials; the Keychain is their correct home and Infisical only ever sees service URLs.
- Infisical setup bindings, including full service tokens or machine client secrets and their scope metadata → one versioned, build-scoped Keychain record (`InfisicalIdentityStore`).  No credential is persisted in UserDefaults, bundled into the app, logged, or included in an error message.

**Explicitly out — build-time constants:** `SUFeedURL` / `SUPublicEDKey` (Sparkle, baked into the signed bundle — do not move these), provider API endpoints (`api.anthropic.com`, etc.), bundle identifiers, local credential file paths.

**Build-time CI secrets (Infisical prod, not runtime app keys):** `SENTRY_DSN` and `SENTRY_AUTH_TOKEN` live in the Fleet-OPS Infisical project (prod `/`) for the TestFlight / Sparkle ship jobs; both `ios-ship.yml` and `mac-release.yml` read that project, and no ship job reads a CodeCaps Infisical project.  The iOS TestFlight workflow (`ios-ship.yml`) also reads `SENTRY_DSN_CODECAPS` from Fleet-OPS prod `/`:  the DSN of Sentry project `codecaps`, to be filled by admin, which replaces the shared fleet `SENTRY_DSN` for the iOS archive.  A missing `SENTRY_DSN_CODECAPS` falls back to the shared key and turns the run red.  The Mac and iOS apps never fetch them at runtime; `InfisicalSettings` does not grow a fourth named read.  Ship workflows load them through `.github/actions/infisical-secrets` (GitHub repository secrets of the same name as fallback) and inject `SENTRY_DSN` into the archive as an xcodebuild / Info.plist build setting.  `SentryTelemetry` skips init when the value is empty.  `SENTRY_AUTH_TOKEN` is used only by `sentry-cli` on the runner for dSYM / Size Analysis upload (org `simple-with-us`, project `codecaps`).  `SENTRY_FLEET_DSN` is a GitHub repository secret for `.github/workflows/sentry-ci-report.yml` (fleet-infra), not an Infisical app key.

**iOS companion:** the companion cannot safely hold a client secret, so it never talks to Infisical.  The Mac app owns the Infisical read; the companion keeps reading quota data through its existing API (`https://usage.jays.services/api/quota-windows` with its read token).  No companion code changed for this rollout.

## The Runtime Contract

1. **Load at startup.**  `AppDelegate.startInfisicalSync` installs persisted configuration synchronously at launch, then asynchronously runs `refresh()` → adopt endpoints.  Revision fences discard completions from a retired setup.  A failure never blocks launch or the main thread; the app keeps its local values.
2. **Never fetch per-request.**  All runtime reads go through `InfisicalSettings.value(for:)`, a synchronous memory-only read.  The only network calls are the startup load, the refresh timer, `applicationDidBecomeActive`, and explicit admin Save actions.
3. **Background refresh.**  A one-shot timer rescheduled after every fire (so a cadence change in Infisical takes effect next cycle), plus a refresh on `applicationDidBecomeActive`.  A failed refresh is recorded on `lastError` (visible under Dashboard → Infisical Sync) and the last-known-good cache keeps serving — staleness is safer than an outage.
   The three named reads complete before the cache changes; partial success never replaces it.  Infisical sync remains optional and separately provisioned.  Reading settings does not turn on quota push or pull.
4. **Write-through on admin save.**  When Infisical is selected, saving managed settings requires an explicit matching write binding.  `InfisicalSettings.set` authenticates with that write binding, writes to Infisical first, and only then updates the cache.  The read credential is never used as a write fallback.  A failed write leaves the cache untouched; a retired setup cannot install values or begin a follow-up create.
5. **Adoption, not clobbering.**  After a load/refresh, `MonitorModel.adoptInfisicalEndpointsIfUnset` fills in an endpoint only when the owner never set one locally (key absent).  A deliberately cleared field (stored as `""`) is never overridden.

## Admin Gating

CodeCaps is a single-user local app: the owner is the only user and therefore the admin.  The gate is a deliberate no-op, documented here rather than implemented as a parallel auth system.  The settings surfaces (Dashboard → Sources & Fleet, Dashboard → Infisical Sync) are reachable only on his own Mac.

## Setup

1. Open Dashboard → Infisical Sync and add a labeled binding.  Choose Service Token (recommended) or Machine Identity, the explicit read or write purpose, project ID, environment, folder, and HTTPS Infisical site.
2. Paste an existing complete service token, or the existing machine client ID and client secret.  Save Binding stores the credential in this build's Keychain.  Blank credential fields retain the existing credential only for the same binding and authentication method; a changed machine client ID requires its secret again.
3. Add separate read and write bindings as needed for different project/environment/folder scopes.  Select Read Settings From to activate one source.  Select Write Settings With separately if managed settings should be editable; only matching write bindings appear.  Save Selection validates the selected read source and commits runtime configuration and Keychain persistence together.
4. Saving a candidate fails without replacing the active setup if validation or Keychain persistence fails.  Read-source validation requests only managed keys; missing keys are allowed, while authentication and other read failures preserve the prior setup.
5. Choose Local Settings Only to disconnect while retaining bindings.  Remove deletes one local binding; Forget All Bindings removes the app's stored setup.  Neither action deletes Infisical secrets or revokes server credentials.

## Switching, Migration, And Rotation

Switching any selected scope retires old requests and clears the settings cache before the new source is installed.  Old completions cannot replace the new cache or status, and a delayed write cannot start a create request after a switch or Forget.  An already submitted HTTP request cannot be recalled.

Existing version-1 machine setup is read without rewriting it at launch.  The next explicit save writes the version-2 binding list into the same build-scoped Keychain item.  The migrated machine binding retains its client credentials, project, `prod`, and `/`; write selection remains empty until the owner explicitly provides one.

To rotate credentials, edit the corresponding binding and paste its replacement, save successfully, then revoke the old credential through the normal owner-approved process.  Working credentials are never automatically minted, refreshed, or revoked by this setup flow.

## Hard Rules

- No secret values in code, logs, PR bodies, or chat — names and metadata only.
- No per-request Infisical fetches anywhere in the refresh, render, or event paths.
- No write without an explicit matching write binding; never reuse the read credential implicitly.
- Preserve complete service-token values and keep every credential in the app's own Keychain record.
- No per-user settings migrated into Infisical, ever.
- The local user is the admin; there is no separate admin role to invent.

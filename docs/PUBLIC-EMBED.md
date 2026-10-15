# Public Read API And Web Embeds (CC-81)

CodeCaps is a **client**.  Quota aggregation, authenticated read APIs, and any HTML or JavaScript meant for third-party sites belong on the **Usage Monitor** service you configure under Settings → Sources & Fleet, not in this repository.

## Ownership

| Surface | Owner repo | Notes |
|---|---|---|
| Mac menu bar, Console, Glance | CodeCaps | Local readers plus optional fleet pull |
| Native WidgetKit widgets (iOS and macOS) | CodeCaps | See [`docs/WIDGETS.md`](WIDGETS.md) |
| HTTP push ingest (`usage_monitor_v2`, `generic_webhook`) | Usage Monitor (server you run) | CodeCaps ships `QuotaPublisher` |
| HTTP pull `GET /api/quota-windows` | Usage Monitor (server you run) | CodeCaps ships `QuotaClient` |
| Embeddable quota bars for other apps and websites | **Usage Monitor** (future) | Not implemented in CodeCaps |

Fleet recall and board reconciliation (2026-10-03, migration `board:8d2557b1246b48f69257cc398d84df1f`) recorded this split so agents do not duplicate server work here.

## What already exists

CodeCaps already documents push and pull in [`README.md`](../README.md) and the live [Setup & Data Guide](https://codecaps.[REDACTED].com/setup.html).  On the server side, Usage Monitor exposes an authenticated read contract that CodeCaps consumes:

- **Method and path:** `GET /api/quota-windows`
- **Auth:** `Authorization: Bearer <read token>` (the Read Token saved in Keychain on the Mac)
- **Response shape:** `generatedAt`, `windows[]`, optional `providerGroups[]` and `skipModelTypes[]` — see `QuotaResponse` in `Sources/QuotaCore/QuotaModels.swift` and `Tests/QuotaCoreTests/FleetPipelineTests.swift` for examples.

`QuotaClient` enforces HTTPS (loopback HTTP only), rejects URLs with embedded credentials, queries, or fragments, uses an ephemeral `URLSession` with **no redirects**, and caps response size so a bearer token cannot be forwarded to another origin.

That API is appropriate for **server-side or trusted native clients** (CodeCaps, the iOS companion widget pull path, automation).  It is not, by itself, a safe model for dropping a read token into a public web page.

## What does not belong in CodeCaps

- iframe or script tags served from this repo for arbitrary sites
- A “public” unauthenticated mirror of fleet quota data
- Copying Usage Monitor’s ingest or quota-windows handlers into the Mac app bundle

Native widgets are the supported way to show CodeCaps quota bars **on Apple devices** without building a separate website.

## Security constraints for any future embed

When Usage Monitor adds embeddable bars:

1. **Never** ship the fleet Read Token to browser JavaScript, query strings, or static HTML.  Tokens in page source are public.
2. Prefer a **server-mediated** model: your backend holds the token and returns only the fields you intend to expose, or Usage Monitor issues **scoped, revocable embed credentials** tied to explicit windows or machines.
3. Reuse the existing `windows[]` vocabulary where possible so CodeCaps, BotFleet, and embeds stay aligned.

## Open owner decision (blocks UM embed implementation)

Usage Monitor still needs a product choice before building the embed surface:

- **Authenticated API only** — integrators call `GET /api/quota-windows` from their own backend with a stored read token (no first-party embed widget).
- **Per-user public selected-bar sharing** — Usage Monitor mints limited public URLs or tokens for explicitly chosen windows, with clear privacy copy and revocation.

CodeCaps does not implement either path; this document closes the **repo ownership** portion of CC-81 and points embed work at Usage Monitor once the owner picks a model.

## Related code in this repo

- Pull client: `Sources/QuotaCore/QuotaClient.swift`
- Push publisher: `Sources/QuotaCore/QuotaPublisher.swift`
- Settings UI: Console → Settings → Sources & Fleet (Quota Endpoint, Read Token)
- Local handoff (not a public API): `~/Library/Application Support/Usage Monitor/quota-windows.json` — credential-free, machine-local only

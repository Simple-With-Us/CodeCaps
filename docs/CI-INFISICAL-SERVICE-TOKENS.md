# CodeCaps CI Infisical Service Tokens

This file records automation secret names and their intended scopes.  It contains no token values.  The Mac app’s optional user-configured Infisical setup is documented separately in `INFISICAL.md`.

## Expected Secret Names

| Secret name | Project | Environment | Path | Permission | Consumer |
|---|---|---|---|---|---|
| `INFISICAL_CODECAPS_CI_READ_SERVICE_TOKEN` | `INFISICAL_FLEET_OPS_PROJECT_ID` | `prod` | `/` and `/asc` | Read | GitHub release certificate/Sentry fetches and Mac/iOS release ASC credential staging |
| `INFISICAL_CODECAPS_PROD_ROOT_READ_SERVICE_TOKEN` | `INFISICAL_PROJECT_ID` from `.cursor/infisical.env` | `prod` | `/` | Read | Cursor Cloud startup export |

The Actions composite fetcher and ASC reader share one read-only Fleet-OPS token scoped to the required prod `/` and `/asc` folders.  Both consumers pass the full service token directly as a Bearer token.  It does not log in or accept machine-identity client IDs or secrets.  Root-path certificate and Sentry values keep their same-named GitHub secret fallbacks.  ASC staging has no GitHub fallback and fails closed if its `/asc` service token or required ASC values are unavailable.

Infisical service tokens should be provisioned with the listed project, environment, path, read-only permission, and an owner-selected expiry.  The repository records environment variable names only; token values must be supplied through the existing authorized secret channel.  No service token is embedded, generated, or provisioned by this change.

# Endpoint Plugins: Add A Subscription Without A CodeCaps Update

CodeCaps can monitor an extra AI subscription plan from a declarative
endpoint plugin: a small JSON file that names one quota endpoint and the
JSON paths of the numbers to show.  Plugins are data, never code — no
script, shell, dynamic library, or expression is ever run — so a plugin
cannot execute anything, and a bad file is skipped rather than half-applied.

## Install

Save one JSON file per plan in
`~/Library/Application Support/CodeCaps/Plugins/` (create the folder first),
then toggle the new row in **Settings → Sources & Fleet**.  Removing the
file removes the plan at the next refresh.

## Example

```json
{
  "id": "plugin:acme",
  "displayName": "Acme Plan",
  "providerKey": "acme-plan",
  "endpoint": "https://api.example.com/usage",
  "auth": { "type": "bearerEnv", "env": "ACME_API_KEY" },
  "windows": [
    {
      "idSuffix": "monthly",
      "label": "Monthly",
      "window": "monthly",
      "usedPercentPath": "usage.monthly.percent",
      "resetAtPath": "usage.monthly.resetsAt"
    }
  ]
}
```

With `ACME_API_KEY` in CodeCaps' environment, the plugin sends it as a
Bearer token, reads `usage.monthly.percent` as the used percentage, and
shows the remaining percentage resetting at `usage.monthly.resetsAt`.

## Fields

| Field | Meaning |
|---|---|
| `id` | `plugin:<slug>`; unique, and never a built-in reader's id |
| `displayName` | Row label in Settings and quota cards |
| `providerKey` | Lowercase slug the windows are filed under; built-in provider keys are reserved and refused |
| `endpoint` | One GET endpoint; HTTPS only (loopback HTTP needs `"allowLoopback": true`), no query, fragment, or credentials in the URL |
| `auth` | `{ "type": "none" }` or `{ "type": "bearerEnv", "env": "VAR_NAME" }`; the token value never lives in the file and is never logged |
| `windows` | 1–10 windows; each needs a remaining-percent path, a used-percent path, or an absolute remaining/limit path pair |

Window paths use a restricted dot/index grammar (`usage.monthly.percent`,
`items[0].remaining`).  A reset path may be ISO-8601 text or an epoch
seconds/milliseconds number.  Absolute paths (`absoluteRemainingPath`,
`absoluteLimitPath`, `quotaUnit`) show real balances where the endpoint
reports them.

## Safety Rules

Endpoints on private, loopback, link-local, or cloud-metadata literal
addresses are refused, redirects are refused, responses are capped, and
every plugin is an optional reader that can be switched off in Settings.
A descriptor is trusted configuration you place on disk — the same trust
class as the push/pull endpoint in Settings — so only install files whose
endpoint you recognise.  Anything this format cannot express (OAuth
refresh, request signing, POST bodies) belongs in a built-in reader, not
in a plugin.

## Built-In Equivalents

OpenCode Go, Alibaba Token Plan and Coding Plan (the Qwen Code plans), and
Xiaomi MiMo Token Plan (the MiMo Code plan) are built in; see
`docs/TOKEN-PLAN-SOURCES.md`.  They do not need plugin files.

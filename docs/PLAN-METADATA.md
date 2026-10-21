# Provider Plans And Shared Settings

CodeCaps reads explicit provider plan fields rather than guessing a subscription from quotas, prices, or text keywords.  Codex uses the authenticated usage response's `plan_type`.  Claude uses OAuth `subscriptionType` and a reported numeric multiplier in `rateLimitTier`.  GitHub Copilot uses `copilot_plan` from `gh api --hostname github.com /copilot_internal/user`, with the existing GitHub CLI sign-in.

Copilot reports the structured quota snapshots for premium interactions, chat, and completions, plus the provider's reset date.  Unlimited or missing percentages remain unknown.  A plan without a numeric quota still produces a plan-details window.  A live endpoint check returned an `individual` plan and all three snapshot names; this does not guarantee every GitHub account can access that endpoint.

## Transport Contract

Every quota window may include optional `planMetadata`:

| Field | Meaning | Maximum UTF-8 Bytes |
| --- | --- | --- |
| `detectedPlanName` | Explicit provider-reported plan | 256 |
| `userPlanName` | Entered plan name | 256 |
| `userCostUsd` | Entered cost text | 128 |
| `userRenewalDateText` | Entered renewal text | 512 |
| `userSubtitle` | Entered subtitle | 1024 |
| `showCostAndRenewal` | Entered display preference | Boolean |
| `userUpdatedAt` | Persisted settings revision, epoch seconds | Number |
| `hasMismatch` | Known reported and entered plans disagree | Boolean |

Legacy `planName` always means the detected plan.  Entered values never replace it or automatically change another app's billing configuration.  Authentication material and account emails are excluded from this contract.

The private local handoff, generic HTTP push, and quota read APIs use the nested object.  Usage Monitor's v2 ingest schema permits scalar metadata, so its event fields are `planDetectedName`, `planUserName`, `planUserCostUsd`, `planUserRenewalDateText`, `planUserSubtitle`, `planShowCostAndRenewal`, `planHasMismatch`, and numeric `planUserUpdatedAt`.  This persisted edit revision distinguishes settings reversions and orders delayed updates without advancing the quota observation time.  Consumers reconstruct the nested object through a typed allowlist.

Settings edits update the local handoff and widget cache after a short debounce, and push when sync is enabled.  Provider settings without a quota reading use an unknown-quota metadata window; no artificial remaining percentage is generated.  Disabling local provider checks prevents those settings-only windows.  Remote fleet windows preserve their originating metadata.

## Warning Behavior

On launch, activation, or opening a CodeCaps surface, fresh local provider reports are compared with the plan entered in Settings.  A known disagreement presents **Plan Information Mismatch**, showing both values and offering **Open Settings** or **Continue**.  Acknowledging the warning suppresses it only for that open; the next open warns again while the disagreement persists.

Unknown or stale reports do not warn.  Formatting and provider prefixes are normalized, `Pro` and `Pro+` remain distinct, and generic Claude `Max` does not contradict an unspecified multiplier.  Typing in Settings does not interrupt the edit; the completed value is checked on the next open.  No setting is silently overwritten.

## Consumers

- BotFleet reads the local handoff and authenticated remote quota windows: [PR 1280](https://github.com/Simple-With-Us/BotFleet/pull/1280).
- Usage Monitor persists scalar fields and returns typed metadata from its authenticated quota APIs: [PR 1737](https://github.com/Simple-With-Us/Usage-Monitor/pull/1737).
- Clutch adds an authenticated, bounded local handoff adapter at `GET /clutch/v1/quotas`: [PR 172](https://github.com/Simple-With-Us/Clutch/pull/172).

The contract is available to other authorized fleet consumers.  These changes do not publish entered costs, notes, or renewal details to anonymous web embeds.

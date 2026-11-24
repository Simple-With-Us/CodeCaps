# Antigravity Pool Windows Reach The Phone

Jay reported that the iPhone showed one bar per Antigravity entry (Gemini 7d only, Third-Party 5h only) while the Mac showed both.

## Cause

The Mac publishes four pooled Antigravity windows: Gemini 5h, Gemini weekly, Third-Party 5h and Third-Party weekly.  They carry no model id, so `UsageMonitorPushMetadata.fallbackBucketId` fell through to the bare cadence token.  Gemini 5h and Third-Party 5h both became bucket `5h`, and the two weekly windows both became `weekly`.  The server keeps one window per bucket, so one of each pair was overwritten and the phone drew a single bar per pool.

The live server payload showed exactly this: one fresh `5h` row (Third-Party) and one fresh `weekly` row (Gemini), with no fresh Gemini 5h.

## Change

Antigravity pool windows now bucket as `gemini-5h`, `gemini-weekly`, `3p-5h` and `3p-weekly`, the ids the server and `AntigravityQuotaGroups.pool` already read.  A new test in `UsageMonitorPushMetadataTests` pins the four distinct buckets.

## Rollout note

The fix is on the publishing side.  The phone shows both bars once the Mac app that pushes is rebuilt with this change and has pushed once.

## Verification

```sh
swift test -j 4 --filter UsageMonitorPushMetadataTests
```

The iOS `CompanionQuotaModel` was also run against the live server payload and against the payload the fixed publisher produces: before, Gemini showed only the 7-day bar; after, Gemini shows 5h and 7-day, and Third-Party shows 5h and 7-day.

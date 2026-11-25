# Alibaba, Qwen Code, and Xiaomi MiMo quota sources

In **Settings → Sources & Fleet**, enable Alibaba Token Plan after installing the
[official Bailian CLI](https://www.alibabacloud.com/help/en/model-studio/cli/installation)
and signing in to the appropriate console site. Check
`bl usage token-plan --output json` locally first. CodeCaps runs only that bounded
[quota command](https://www.alibabacloud.com/help/en/model-studio/cli/usage-quota).
A successful command without usage windows is unavailable, not a full allowance.
Availability depends on the console site and plan; no browser profile is read.

## Qwen Code subscriptions

Qwen Code is a client; select the source for the plan you used under `/auth`.

- **Alibaba ModelStudio → Token Plan:** Enable the existing **Alibaba Token Plan**
  source above. Using it from Qwen Code does not create a separate quota.
- **Alibaba ModelStudio → Coding Plan:** Enable **Alibaba Coding Plan (Qwen Code)**.
  Check `bl usage coding-plan --output json` after signing in on the matching
  Bailian console site. CodeCaps shows only the reported five-hour, weekly, and
  monthly request windows and their reset times. This is a separate meter from
  the Alibaba Token Plan.
- **Qwen Account with Subscription (Plus/Pro):** Qwen Code's
  [subscription design](https://github.com/QwenLM/qwen-code/blob/main/docs/design/qwen-subscription.md)
  describes `/usage` as local statistics, not remaining subscription quota.
  CodeCaps does not use these statistics as a quota meter.
- **QwenCloud → Token Plan:** QwenCloud publishes
  [console usage instructions](https://docs.qwencloud.com/token-plan/token-plan-usage-quota).
  There is no CodeCaps reader for this separate source. Do not use the Alibaba
  meter as a proxy for QwenCloud credits or submit inference to estimate them.

## Xiaomi MiMo Token Plan

For Xiaomi, choose the region shown on the MiMo Token Plan dashboard and save the
individual plan key in CodeCaps. CodeCaps keeps that key in the local macOS
Keychain, checks only the matching Xiaomi region’s
[credits endpoint](https://mimo.mi.com/docs/en-US/api/asset/credits-get), and never
performs inference. Team and pay-as-you-go keys are not supported. The poll
preserves Xiaomi’s reported credit balance and exact billing-cycle end rather
than assuming it is monthly. Do not paste the key into a support report.

MiMo Code is a client of this same plan: signing MiMo Code in with an
individual Token Plan key and saving that key above monitors the one shared
allowance. Local `mimo stats` output is consumption history, not remaining
quota, and is never shown as a quota meter.

## OpenCode Go

Enable **OpenCode Go** in **Settings → Sources & Fleet** after signing in
with `opencode auth login`. CodeCaps reads the Go key read-only from the
OpenCode CLI's local auth file and checks OpenCode's documented usage
endpoint for the rolling five-hour, weekly, and monthly windows. Local
`opencode stats` output is a consumption estimate, not remaining quota,
and is never shown as a quota meter.

## Other Plans

Any other subscription whose provider publishes a quota endpoint can be
added without a CodeCaps update as a declarative endpoint plugin; see
`docs/ENDPOINT-PLUGINS.md`.

Use these with signed-in test subscriptions to verify the Mac settings and quota
meters. The fixtures do not prove any specific account or region is eligible.
The iPhone companion still uses synced snapshots, not these local collectors.

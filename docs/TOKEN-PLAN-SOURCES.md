# Alibaba and Xiaomi MiMo Token Plan quota sources

In **Settings → Sources & Fleet**, enable Alibaba Token Plan after installing the
[official Bailian CLI](https://www.alibabacloud.com/help/en/model-studio/cli/installation)
and signing in to the appropriate console site. Check
`bl usage token-plan --output json` locally first. CodeCaps runs only that bounded
[quota command](https://www.alibabacloud.com/help/en/model-studio/cli/usage-quota).
A successful command without usage windows is unavailable, not a full allowance.
Availability depends on the console site and plan; no browser profile is read.

For Xiaomi, choose the region shown on the MiMo Token Plan dashboard and save the
individual plan key in CodeCaps. CodeCaps keeps that key in the local macOS
Keychain, checks only the matching Xiaomi region’s
[credits endpoint](https://mimo.mi.com/docs/en-US/api/asset/credits-get), and never
performs inference. Team and pay-as-you-go keys are not supported. The poll
preserves Xiaomi’s reported credit balance and exact billing-cycle end rather
than assuming it is monthly. Do not paste the key into a support report.

Use both with signed-in test subscriptions to verify the Mac settings and quota
meters. The fixtures do not prove any specific account or region is eligible.
The iPhone companion still uses synced snapshots, not these local collectors.

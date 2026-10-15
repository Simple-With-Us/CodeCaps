# 2026-10-15 — CC-19: Swift compile gate (hosted macOS CI + ruleset handoff)

## Summary

CodeCaps had hosted Swift CI (`.github/workflows/swift-ci.yml`) but ruleset
`default-main-protection` (id `24433457`) did not require any status checks,
so merges and Sparkle releases could proceed while compile jobs were still
queued.  CC-19 wires the lane for a real gate: one macOS runner per pull
request, Mac Release waits for the same compile checks on `main`, and this
document gives Jay the exact check names to add in GitHub (admin-only).

## What changed

- **Swift CI** — stay on `macos-latest` (Swift 6 toolchain required by
  `sentry-cocoa` 9.30.x), cancel stale pull-request runs, run `companion`
  only after `package` (`needs:`) so a PR never holds two macOS runners at
  once.  Explicit job `name:` values match the contexts GitHub reports for
  required checks.
- **Mac Release (Sparkle)** — new `await-swift-ci` job on `ubuntu-latest`
  polls until `package` and `companion` succeed on the merge commit (or fails
  closed if either fails, is cancelled, or times out).  The release job
  `needs: await-swift-ci`, closing the race where Sparkle published while
  companion was still running.
- **This rollout** — owner steps for ruleset required checks (not applied in
  CI; Jay has the admin grant).

## Verification (agents)

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/swift-ci.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/mac-release.yml'))"
```

Hosted macOS compile is validated on the pull request’s Swift CI run after push.

## Required status checks (Jay — after this is on `main`)

Ruleset: **Settings → Rules → Rulesets → `default-main-protection`**
(`24433457`) → add a **Require status checks to pass** rule.

Require these **job** contexts (not the workflow title `Swift CI`):

| Context | Workflow | What it proves |
| --- | --- | --- |
| `Mac package build and test` | Swift CI | `swift build`, `swift test`, native UI fixture render |
| `iOS companion compile` | Swift CI | Companion XcodeGen build, simulator smoke, Mac widget target |
| `gitleaks` | Secret scanning | Secret scan on the PR commit range |

**Order of operations:** land this PR and confirm at least one green Swift CI
on `main` **before** ticking the two Swift contexts required.  If macOS hosted
runners are backlogged, a required check that has not started yet blocks every
pull request — fix queue health first, then enable the Swift contexts.

Optional strictness: leave **Require branches to be up to date before merging**
off unless you want merge-queue semantics; Swift CI already runs on the head
commit.

Confirm live contexts:

```bash
gh api repos/Simple-With-Us/CodeCaps/rulesets/24433457 \
  --jq '.rules[] | select(.type=="required_status_checks")'
```

After you add the rule, the same command should list the three contexts above
under `parameters.required_status_checks` (or `contexts`, depending on API
shape).

Do **not** require workflow names (`Swift CI`, `Secret scanning`).  Require the
**job** names exactly as in the table.

## Deferred

- Ruleset edit itself (Jay admin).
- Moving compile to self-hosted macOS runners (fleet BotFleet pinning work).
- Requiring Mac Release or TestFlight workflows as merge gates (ship lanes, not
  compile).

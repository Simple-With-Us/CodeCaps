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
- **Mac Release (Sparkle)** — `await-swift-ci` on `ubuntu-latest` polls until
  `Mac package build and test` and `iOS companion compile` succeed on the
  commit (or fails closed if either fails, is skipped, is cancelled, or
  times out).  Push, pull request, and `workflow_dispatch` all wait, so the
  bundle build does not take a macOS runner beside Swift CI.  The release job
  `needs: await-swift-ci`, so Sparkle cannot publish while companion is
  still running.
- **iOS and Mac TestFlight** — the same wait runs before a ship.  The
  scheduled iOS gate itself runs on ubuntu, so a skip no longer queues a
  macOS runner.
- **Ruleset script** — `scripts/apply-main-compile-gate-ruleset.sh` prints
  the rule change and refuses `--apply` until the three contexts below are
  already success on the default branch.  It is not run from CI.

## Verification (agents)

```bash
python3 scripts/compile_gate_checks_test.py
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/swift-ci.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/mac-release.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ios-ship.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/macos-ship.yml'))"
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

- Applying the ruleset.  After a green Swift CI on `main`, someone with
  ruleset admin runs `scripts/apply-main-compile-gate-ruleset.sh --apply`.
  A dry run is the same command without `--apply`.
- Moving compile to self-hosted macOS runners (fleet BotFleet pinning work).
- Requiring the ship workflows themselves as merge checks.  They wait on the
  compile checks; they are not compile checks.

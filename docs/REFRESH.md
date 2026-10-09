# Refresh Sources and Intervals

CodeCaps has two kinds of local quota input.  Configure them separately in Settings → Sources & Fleet under Read Quotas From This Mac.

| Input | Available Sources | Default | What a Check Does |
|---|---|---|---|
| Provider Checks | Seven direct HTTP reader paths and three helper paths, covering eight provider families | Every five minutes | Uses existing sign-ins and supported helpers to obtain quotas |
| Codex Session File Checks | One passive quota source | Every minute | Reads quota events already written by the signed-in Codex CLI |

These are available reader paths, not a count of network requests.  A missing sign-in can skip a request; retries, fallback paths, and helper behavior can change the number of requests.  Reading a credential file and then calling a provider belongs to Provider Checks.

Each group supports one-, three-, five-, and fifteen-minute intervals and has its own off switch.  Read Quotas From This Mac turns both groups off.  Faster checks do not make a provider or CLI publish fresher data sooner.

| Interval | Scheduled Cycles per Hour | Scheduled Cycles per Day |
|---|---:|---:|
| One minute | 60 | 1,440 |
| Three minutes | 20 | 480 |
| Five minutes | 12 | 288 |
| Fifteen minutes | 4 | 96 |

These figures assume the app is running and the Mac is awake for the entire period.  Manual refreshes and other refresh triggers are additional; overlapping work can be coalesced.  A one-minute interval produces five times as many scheduled cycles as five minutes, while three minutes produces about 1.7 times as many.

## Passive File Reading

The Codex reader reads bounded session files and accepts only quota events whose session metadata matches the current local account.  It does not start the CLI, contact a provider, or read tokens from Keychain.  It retains the event's original observation time; checking an unchanged file does not turn an old observation into a new one.

A file-only check does not pull from a server or upload quota data.  Changed readings update local app history and local sharing caches.  A CLI must first write usable quota events; an inactive CLI may provide no recent reading.

## Sharing and Widgets

Upload and download remain separate, optional controls.  Choosing a short file-check interval does not enable either.  Widgets display the app's shared snapshots and follow the operating system's timeline scheduling; an app refresh interval is not a promise that a widget refreshes at that exact interval.

History graphs show measured quota percentages and recorded observation times.  Missing observations, account changes, and quota resets break the lines.  Quota percentages do not identify which conversation or agent consumed them.

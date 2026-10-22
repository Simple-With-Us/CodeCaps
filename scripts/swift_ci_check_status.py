#!/usr/bin/env python3
"""Classify GitHub Actions check runs for the CodeCaps compile gate.

Reads one or more check-run list payloads (the ``check_runs`` array from
``GET /repos/{owner}/{repo}/commits/{sha}/check-runs``) and prints one word
on stdout: ``success``, ``failure``, or ``pending``.

Exit status matches that word: 0, 1, or 2.  The newest github-actions run
for each requested name wins, so a rerun replaces a cancelled attempt.

A CANCELLED run is a FAILURE by default.  It never finished, so it says
nothing about the code, but a caller that cannot replace it has nothing to
wait for either:  the honest answer is that the run did not pass, and the
gate says so at once instead of polling for a run that will never arrive.
With ``--redispatch-on-cancel`` the caller says it can replace the run, so a
cancelled run is reported as pending and the gate waits for the replacement
instead of failing on a run that never ran.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Iterable, Mapping, Sequence

_WORKFLOW_RUN_URL = re.compile(r"/actions/runs/(\d+)(?:/|$)")


def _runs_from(payloads: Iterable[Mapping]) -> list[Mapping]:
    runs: list[Mapping] = []
    for payload in payloads:
        chunk = payload.get("check_runs") or []
        if not isinstance(chunk, list):
            raise ValueError("check_runs must be a list")
        runs.extend(chunk)
    return runs


def latest_by_name(runs: Sequence[Mapping], names: Sequence[str]) -> dict[str, Mapping]:
    """Newest github-actions run for each name.  A missing app slug is kept."""
    wanted = set(names)
    latest: dict[str, Mapping] = {}
    for run in runs:
        name = run.get("name")
        if name not in wanted:
            continue
        app = run.get("app") or {}
        slug = app.get("slug") if isinstance(app, Mapping) else None
        if slug not in (None, "", "github-actions"):
            continue
        run_id = int(run.get("id") or 0)
        previous = latest.get(name)
        if previous is None or run_id >= int(previous.get("id") or 0):
            latest[name] = run
    return latest


def workflow_run_id(run: Mapping) -> int:
    """The workflow run behind a check run, or 0 when it is unknown.

    The check-run payload carries no run id.  The job URL does:
    https://github.com/owner/repo/actions/runs/12345/job/678.
    """
    match = _WORKFLOW_RUN_URL.search(str(run.get("details_url") or ""))
    return int(match.group(1)) if match else 0


def latest_runs_by_name(
    runs: Sequence[Mapping], names: Sequence[str]
) -> list[tuple[str, int, int]]:
    """Newest github-actions run per name: (name, check run id, run id).

    The check run id tells a fresh run from the stale row the gate already
    replaced.  The workflow run id is what the gate re-runs to replace a
    cancelled attempt.  A name with no run gets (name, 0, 0).
    """
    latest = latest_by_name(runs, names)
    rows: list[tuple[str, int, int]] = []
    for name in names:
        run = latest.get(name) or {}
        rows.append((name, int(run.get("id") or 0), workflow_run_id(run)))
    return rows


def decide(
    payloads: Iterable[Mapping],
    names: Sequence[str],
    redispatch_on_cancel: bool = False,
) -> tuple[str, list[str]]:
    """Return (verdict, details).

    Any concluded non-success fails the gate immediately, including a
    skipped companion after a failed package.  A missing or still-running
    check stays pending so the caller can poll.  Failure wins over pending
    so a red package is not hidden behind a companion that has not started.

    A cancelled run is a failure unless the caller can replace it:  it
    never finished, so it says nothing about the code, but a caller with no
    replacement has nothing to wait for.  With ``redispatch_on_cancel`` the
    cancelled run stays pending and the caller waits for the replacement.
    """
    if not names:
        raise ValueError("at least one check name is required")
    latest = latest_by_name(_runs_from(payloads), names)
    failed: list[str] = []
    pending: list[str] = []
    for name in names:
        run = latest.get(name)
        if run is None:
            pending.append(f"{name}=missing")
            continue
        conclusion = run.get("conclusion")
        status = run.get("status") or ""
        if conclusion == "success":
            continue
        if conclusion == "cancelled":
            if redispatch_on_cancel:
                pending.append(f"{name}=cancelled")
            else:
                failed.append(f"{name}=cancelled")
            continue
        if conclusion:
            failed.append(f"{name}={conclusion}")
            continue
        pending.append(f"{name}={status or 'pending'}")
    if failed:
        return "failure", failed
    if pending:
        return "pending", pending
    return "success", []


def _load(paths: Sequence[str]) -> list[dict]:
    payloads = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            payloads.append(json.load(handle))
    return payloads


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--names", nargs="+", required=True)
    parser.add_argument("--json", nargs="+", required=True, dest="json_paths")
    parser.add_argument(
        "--redispatch-on-cancel",
        action="store_true",
        help="a cancelled run is pending, because the caller can replace it",
    )
    parser.add_argument(
        "--latest-runs",
        action="store_true",
        help="print name, check run id and workflow run id per requested name",
    )
    args = parser.parse_args(argv)
    payloads = _load(args.json_paths)
    if args.latest_runs:
        for name, check_id, run_id in latest_runs_by_name(_runs_from(payloads), args.names):
            print(f"{name}\t{check_id}\t{run_id}")
        return 0
    verdict, details = decide(
        payloads, args.names, redispatch_on_cancel=args.redispatch_on_cancel
    )
    print(verdict)
    for line in details:
        print(line, file=sys.stderr)
    return {"success": 0, "failure": 1, "pending": 2}[verdict]


if __name__ == "__main__":
    sys.exit(main())

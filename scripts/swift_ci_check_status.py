#!/usr/bin/env python3
"""Classify GitHub Actions check runs for the CodeCaps compile gate.

Reads one or more check-run list payloads (the ``check_runs`` array from
``GET /repos/{owner}/{repo}/commits/{sha}/check-runs``) and prints one word
on stdout: ``success``, ``failure``, or ``pending``.

Exit status matches that word: 0, 1, or 2.  The newest github-actions run
for each requested name wins, so a rerun replaces a cancelled attempt.

A CANCELLED run is reported as pending, not as a failure:  a cancelled run
never finished, so it carries no verdict about the code.  The gate waits for
a replacement instead of failing on a run that never ran.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Iterable, Mapping, Sequence


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


def decide(payloads: Iterable[Mapping], names: Sequence[str]) -> tuple[str, list[str]]:
    """Return (verdict, details).

    Any concluded non-success fails the gate immediately, including a
    skipped companion after a failed package.  A missing or still-running
    check stays pending so the caller can poll.  Failure wins over pending
    so a red package is not hidden behind a companion that has not started.

    A cancelled run stays pending rather than failing:  it never finished,
    so it says nothing about the code, and a replacement may still arrive.
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
            pending.append(f"{name}=cancelled")
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
    args = parser.parse_args(argv)
    verdict, details = decide(_load(args.json_paths), args.names)
    print(verdict)
    for line in details:
        print(line, file=sys.stderr)
    return {"success": 0, "failure": 1, "pending": 2}[verdict]


if __name__ == "__main__":
    sys.exit(main())

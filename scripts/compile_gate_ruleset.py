#!/usr/bin/env python3
"""Build the CodeCaps main-branch ruleset body with a compile gate.

The live contexts are the Swift CI job names ``Mac package build and test``
and ``iOS companion compile``, plus the gitleaks job.  Renaming a job
without updating REQUIRED_CONTEXTS makes the gate wait for a check that
will never arrive.

Usage: compile_gate_ruleset.py --ruleset ruleset.json
Prints the PUT body for the repository ruleset API.  Does not call GitHub.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Mapping, Sequence

# Match Usage-Monitor's working ruleset: do not require the branch to be
# up to date with the base, and do not enforce the checks when a branch
# is created.  The contexts themselves are what block a merge.
# These are the Swift CI job `name:` values on main (CC-19 / #236), not the
# job ids.  GitHub reports the name as the status context.
REQUIRED_CONTEXTS = (
    "Mac package build and test",
    "iOS companion compile",
    "gitleaks",
)


def required_status_checks_rule() -> dict:
    return {
        "type": "required_status_checks",
        "parameters": {
            "do_not_enforce_on_create": True,
            "strict_required_status_checks_policy": False,
            "required_status_checks": [{"context": name} for name in REQUIRED_CONTEXTS],
        },
    }


def contexts_of(ruleset: Mapping) -> list[str]:
    found: list[str] = []
    for rule in ruleset.get("rules") or []:
        if rule.get("type") != "required_status_checks":
            continue
        parameters = rule.get("parameters") or {}
        for check in parameters.get("required_status_checks") or []:
            context = check.get("context")
            if context:
                found.append(context)
    return found


def with_required_checks(ruleset: Mapping) -> dict:
    """Return a ruleset update body.  Other rules are copied through."""
    for key in ("name", "target", "enforcement"):
        if not ruleset.get(key):
            raise ValueError(f"ruleset is missing {key}")
    updated_rules = []
    replaced = False
    new_rule = required_status_checks_rule()
    for rule in ruleset.get("rules") or []:
        if rule.get("type") == "required_status_checks":
            updated_rules.append(new_rule)
            replaced = True
        else:
            updated_rules.append(rule)
    if not replaced:
        updated_rules.append(new_rule)
    return {
        "name": ruleset["name"],
        "target": ruleset["target"],
        "enforcement": ruleset["enforcement"],
        "bypass_actors": list(ruleset.get("bypass_actors") or []),
        "conditions": ruleset.get("conditions"),
        "rules": updated_rules,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ruleset", required=True, help="GET ruleset JSON")
    args = parser.parse_args(argv)
    with open(args.ruleset, encoding="utf-8") as handle:
        current = json.load(handle)
    body = with_required_checks(current)
    json.dump(body, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Self-tests for the AFC-626 cron-monitor rules in scripts/sentry-ci-report.py.

Stdlib only, no network: send_envelope is replaced with a recorder and the
Actions API lookup is disabled by clearing GITHUB_TOKEN.
Run with `python3 scripts/sentry_ci_report_test.py`.
"""

import importlib.util
import os
import re
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "sentry_ci_report", ROOT / "scripts" / "sentry-ci-report.py")
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)

DSN = "https://abc123@o1.ingest.example.test/42"
SHIP = "iOS TestFlight ship (GitHub-hosted macOS)"


def run_reporter(workflow_name, conclusion, action="completed", event="schedule", branch="main",
                 workflow_names=None):
    """Run main() with send_envelope recorded.

    The stale-key drift guard is stubbed to report nothing, so these
    assertions do not depend on the live checkout's workflow names, unless
    workflow_names is given: then discover_workflow_names() returns it and the
    real drift guard runs against it.
    """
    sent = []
    env = {
        "SENTRY_FLEET_DSN": DSN,
        "WORKFLOW_NAME": workflow_name,
        "WORKFLOW_CONCLUSION": conclusion,
        "WORKFLOW_EVENT": event,
        "WORKFLOW_BRANCH": branch,
        "WORKFLOW_ACTOR": "agent",
        "WORKFLOW_RUN_URL": "https://example.test/run/1",
        "WORKFLOW_RUN_ID": "1",
        "WORKFLOW_RUN_ACTION": action,
        "WORKFLOW_RUN_ATTEMPT": "1",
        "GITHUB_TOKEN": "",
    }
    if workflow_names is None:
        drift_patch = mock.patch.object(reporter, "find_cron_schedule_drift", return_value=[])
    else:
        drift_patch = mock.patch.object(
            reporter, "discover_workflow_names", return_value=set(workflow_names))
    with mock.patch.object(
        reporter, "send_envelope", lambda url, auth, item_type, payload: sent.append((item_type, payload))
    ), mock.patch.dict(os.environ, env, clear=False), drift_patch:
        rc = reporter.main()
    return rc, sent


class UnmonitoredScheduleTests(unittest.TestCase):
    def test_every_scheduled_workflow_is_mapped_or_unmonitored(self):
        found = {}
        for path in sorted(reporter.WORKFLOWS_DIR.glob("*.y*ml")):
            text = path.read_text(encoding="utf-8", errors="replace")
            crons = re.findall(r"^\s*-\s*cron:\s*['\"]?([^'\"#\n]+?)['\"]?\s*(?:#.*)?$", text, re.MULTILINE)
            name = re.search(r"^name:\s*(.+?)\s*$", text, re.MULTILINE)
            if crons and name:
                found[name.group(1).strip().strip("\"'")] = crons[0].strip()
        # Case-folded on both sides, like main() and find_cron_schedule_drift().
        unmonitored_folded = {name.casefold() for name in reporter.UNMONITORED_SCHEDULES}
        self.assertEqual(unmonitored_folded - {name.casefold() for name in found}, set())
        self.assertEqual(
            {name.casefold(): cron for name, cron in reporter.CRON_SCHEDULES.items()},
            {
                name.casefold(): cron
                for name, cron in found.items()
                if name.casefold() not in unmonitored_folded
            },
        )

    def test_requested_sweep_opens_no_checkin_and_raises_no_drift(self):
        rc, sent = run_reporter("Auto-merge PRs", "", action="requested")
        self.assertEqual(rc, 0)
        self.assertEqual(sent, [])

    def test_completed_sweep_sends_no_checkin_and_no_drift(self):
        rc, sent = run_reporter("Auto-merge PRs", "success")
        self.assertEqual(rc, 0)
        self.assertEqual(sent, [])

    def test_failed_sweep_still_raises_its_error_event(self):
        rc, sent = run_reporter("Auto-merge PRs", "failure")
        self.assertEqual(rc, 0)
        self.assertEqual([item_type for item_type, _ in sent], ["event"])
        self.assertEqual(sent[0][1]["fingerprint"], ["ci-failure", "codecaps", "Auto-merge PRs"])

    def test_an_unlisted_unmapped_schedule_still_raises_drift(self):
        rc, sent = run_reporter("Some new scheduled job", "success")
        self.assertEqual(rc, 0)
        self.assertEqual(len(sent), 1)
        self.assertIn("unmapped-schedule", sent[0][1]["fingerprint"])


class ConfigDriftTests(unittest.TestCase):
    def test_stale_unmonitored_entry_is_reported_like_a_stale_cron_key(self):
        live = set(reporter.CRON_SCHEDULES)
        self.assertEqual(
            reporter.find_cron_schedule_drift(live), sorted(reporter.UNMONITORED_SCHEDULES))

    def test_unmonitored_entry_matches_live_names_case_insensitively(self):
        live = {name.casefold() for name in reporter.CRON_SCHEDULES}
        live |= {name.casefold() for name in reporter.UNMONITORED_SCHEDULES}
        self.assertEqual(reporter.find_cron_schedule_drift(live), [])

    def test_name_in_both_maps_is_reported_as_drift(self):
        live = set(reporter.CRON_SCHEDULES) | set(reporter.UNMONITORED_SCHEDULES)
        with mock.patch.dict(reporter.CRON_SCHEDULES, {"Auto-merge PRs": "*/15 * * * *"}):
            self.assertEqual(reporter.find_cron_schedule_drift(live), ["Auto-merge PRs"])

    def test_stale_unmonitored_entry_raises_the_stale_cron_key_event(self):
        rc, sent = run_reporter(
            "CI", "success", event="push", workflow_names=set(reporter.CRON_SCHEDULES))
        self.assertEqual(rc, 0)
        self.assertEqual([item_type for item_type, _ in sent], ["event"])
        payload = sent[0][1]
        self.assertEqual(payload["fingerprint"], ["ci-report-config-drift", "codecaps", "stale-cron-key"])
        self.assertEqual(payload["extra"]["stale_keys"], sorted(reporter.UNMONITORED_SCHEDULES))


class FailureThresholdTests(unittest.TestCase):
    def test_ship_monitor_needs_three_misses_in_a_row(self):
        config = reporter.build_monitor_config(SHIP, "26,56 * * * *")
        self.assertEqual(config["failure_issue_threshold"], 3)
        self.assertEqual(config["recovery_threshold"], 1)
        self.assertEqual(config["checkin_margin"], reporter.DEFAULT_CHECKIN_MARGIN)
        self.assertEqual(config["max_runtime"], reporter.DEFAULT_MAX_RUNTIME)

    def test_unlisted_monitor_keeps_sentry_defaults(self):
        config = reporter.build_monitor_config("CI", "47 7 * * *")
        self.assertNotIn("failure_issue_threshold", config)
        self.assertNotIn("recovery_threshold", config)

    def test_both_ship_phases_send_the_threshold(self):
        for action, conclusion in (("requested", ""), ("completed", "success")):
            rc, sent = run_reporter(SHIP, conclusion, action=action)
            self.assertEqual(rc, 0)
            checkins = [payload for item_type, payload in sent if item_type == "check_in"]
            self.assertEqual(len(checkins), 1, action)
            self.assertEqual(checkins[0]["monitor_config"]["failure_issue_threshold"], 3)
            self.assertEqual(checkins[0]["monitor_config"]["recovery_threshold"], 1)


if __name__ == "__main__":
    unittest.main()

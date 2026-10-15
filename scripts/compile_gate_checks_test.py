#!/usr/bin/env python3
"""Unit tests for the compile-gate check classifier and ruleset body."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def load(name: str):
    path = ROOT / name
    spec = importlib.util.spec_from_file_location(name.replace(".py", ""), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


status = load("swift_ci_check_status.py")
ruleset = load("compile_gate_ruleset.py")


def run_check(name: str, conclusion, run_id: int, state: str = "completed", app: str = "github-actions"):
    payload = {
        "name": name,
        "id": run_id,
        "status": state,
        "conclusion": conclusion,
    }
    if app is not None:
        payload["app"] = {"slug": app}
    return payload


class DecideTests(unittest.TestCase):
    names = ["package", "companion"]

    def test_both_success(self):
        payload = {"check_runs": [
            run_check("package", "success", 2),
            run_check("companion", "success", 3),
            run_check("gitleaks", "failure", 4),
        ]}
        verdict, details = status.decide([payload], self.names)
        self.assertEqual(verdict, "success")
        self.assertEqual(details, [])

    def test_package_failure_hides_nothing(self):
        payload = {"check_runs": [
            run_check("package", "failure", 2),
            run_check("companion", None, 3, state="queued"),
        ]}
        verdict, details = status.decide([payload], self.names)
        self.assertEqual(verdict, "failure")
        self.assertIn("package=failure", details)

    def test_missing_companion_is_pending(self):
        payload = {"check_runs": [run_check("package", "success", 2)]}
        verdict, details = status.decide([payload], self.names)
        self.assertEqual(verdict, "pending")
        self.assertEqual(details, ["companion=missing"])

    def test_newer_success_replaces_cancelled(self):
        payload = {"check_runs": [
            run_check("package", "cancelled", 1),
            run_check("package", "success", 5),
            run_check("companion", "success", 6),
        ]}
        verdict, _details = status.decide([payload], self.names)
        self.assertEqual(verdict, "success")

    def test_newer_failure_replaces_success(self):
        payload = {"check_runs": [
            run_check("package", "success", 1),
            run_check("package", "failure", 9),
            run_check("companion", "success", 3),
        ]}
        verdict, details = status.decide([payload], self.names)
        self.assertEqual(verdict, "failure")
        self.assertIn("package=failure", details)

    def test_skipped_companion_is_failure(self):
        payload = {"check_runs": [
            run_check("package", "failure", 2),
            run_check("companion", "skipped", 4),
        ]}
        verdict, details = status.decide([payload], self.names)
        self.assertEqual(verdict, "failure")
        self.assertIn("companion=skipped", details)

    def test_in_progress_is_pending(self):
        payload = {"check_runs": [
            run_check("package", "success", 2),
            run_check("companion", None, 3, state="in_progress"),
        ]}
        verdict, details = status.decide([payload], self.names)
        self.assertEqual(verdict, "pending")
        self.assertEqual(details, ["companion=in_progress"])

    def test_foreign_app_does_not_count(self):
        payload = {"check_runs": [
            run_check("package", "success", 8, app="some-other-app"),
            run_check("companion", "success", 9),
        ]}
        verdict, details = status.decide([payload], self.names)
        self.assertEqual(verdict, "pending")
        self.assertEqual(details, ["package=missing"])

    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "checks.json"
            path.write_text(json.dumps({"check_runs": [
                run_check("package", "success", 1),
                run_check("companion", "success", 2),
            ]}), encoding="utf-8")
            completed = subprocess.run(
                ["python3", str(ROOT / "swift_ci_check_status.py"),
                 "--names", "package", "companion", "--json", str(path)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(completed.stdout.strip(), "success")


class RulesetTests(unittest.TestCase):
    def live_shape(self):
        return {
            "id": 24433457,
            "name": "default-main-protection",
            "target": "branch",
            "enforcement": "active",
            "bypass_actors": [],
            "conditions": {"ref_name": {"exclude": [], "include": ["~DEFAULT_BRANCH"]}},
            "rules": [
                {"type": "pull_request", "parameters": {"required_approving_review_count": 0}},
                {"type": "non_fast_forward", "parameters": None},
                {"type": "deletion", "parameters": None},
            ],
        }

    def test_adds_contexts_and_keeps_other_rules(self):
        body = ruleset.with_required_checks(self.live_shape())
        self.assertEqual(
            ruleset.contexts_of(body),
            ["Mac package build and test", "iOS companion compile", "gitleaks"],
        )
        self.assertEqual(
            [rule["type"] for rule in body["rules"]],
            ["pull_request", "non_fast_forward", "deletion", "required_status_checks"],
        )
        self.assertEqual(body["conditions"]["ref_name"]["include"], ["~DEFAULT_BRANCH"])
        self.assertNotIn("id", body)
        parameters = body["rules"][-1]["parameters"]
        self.assertTrue(parameters["do_not_enforce_on_create"])
        self.assertFalse(parameters["strict_required_status_checks_policy"])

    def test_replaces_existing_required_checks_once(self):
        current = self.live_shape()
        current["rules"].append({
            "type": "required_status_checks",
            "parameters": {
                "do_not_enforce_on_create": True,
                "strict_required_status_checks_policy": False,
                "required_status_checks": [{"context": "verify"}],
            },
        })
        once = ruleset.with_required_checks(current)
        twice = ruleset.with_required_checks(once)
        self.assertEqual(
            ruleset.contexts_of(twice),
            ["Mac package build and test", "iOS companion compile", "gitleaks"],
        )
        self.assertEqual(
            sum(1 for rule in twice["rules"] if rule["type"] == "required_status_checks"),
            1,
        )


class AwaitScriptTests(unittest.TestCase):
    def test_fixture_success_and_pending(self):
        script = ROOT / "await-swift-ci-checks.sh"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "checks.json"
            path.write_text(json.dumps({"check_runs": [
                run_check("Mac package build and test", "success", 1),
                run_check("iOS companion compile", "success", 2),
            ]}), encoding="utf-8")
            ok = subprocess.run(
                ["bash", str(script)],
                check=False,
                capture_output=True,
                text=True,
                env={"CHECKS_JSON": str(path), "PATH": "/usr/bin:/bin"},
            )
            self.assertEqual(ok.returncode, 0, ok.stderr)
            self.assertEqual(ok.stdout.strip(), "success")

            path.write_text(json.dumps({"check_runs": [
                run_check("Mac package build and test", "success", 1),
            ]}), encoding="utf-8")
            pending = subprocess.run(
                ["bash", str(script)],
                check=False,
                capture_output=True,
                text=True,
                env={"CHECKS_JSON": str(path), "PATH": "/usr/bin:/bin"},
            )
            self.assertEqual(pending.returncode, 2, pending.stderr)


if __name__ == "__main__":
    unittest.main()

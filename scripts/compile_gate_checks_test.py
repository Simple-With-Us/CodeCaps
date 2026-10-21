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

    def test_cancelled_run_is_pending_not_failure(self):
        # A cancelled run never finished, so it is no verdict about the
        # code.  The gate waits for a replacement instead of failing on a
        # run that never ran.
        payload = {"check_runs": [
            run_check("package", "cancelled", 3),
            run_check("companion", "success", 4),
        ]}
        verdict, details = status.decide([payload], self.names)
        self.assertEqual(verdict, "pending")
        self.assertEqual(details, ["package=cancelled"])

    def test_failure_still_wins_over_a_cancelled_sibling(self):
        payload = {"check_runs": [
            run_check("package", "cancelled", 3),
            run_check("companion", "failure", 4),
        ]}
        verdict, details = status.decide([payload], self.names)
        self.assertEqual(verdict, "failure")
        self.assertIn("companion=failure", details)

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

    def test_cancelled_fixture_is_pending_not_failure(self):
        script = ROOT / "await-swift-ci-checks.sh"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "checks.json"
            path.write_text(json.dumps({"check_runs": [
                run_check("Mac package build and test", "cancelled", 1),
            ]}), encoding="utf-8")
            pending = subprocess.run(
                ["bash", str(script)],
                check=False,
                capture_output=True,
                text=True,
                env={"CHECKS_JSON": str(path), "PATH": "/usr/bin:/bin"},
            )
            self.assertEqual(pending.returncode, 2, pending.stderr)


class RedispatchTests(unittest.TestCase):
    """The gate replaces a cancelled compile run instead of waiting forever."""

    def _stub_gh(self, root: Path, good: Path, current: Path, log: Path) -> Path:
        stub_dir = root / "bin"
        stub_dir.mkdir()
        gh = stub_dir / "gh"
        gh.write_text(
            "#!/usr/bin/env bash\n"
            "set -u\n"
            'if [[ "$*" == *"/dispatches"* ]]; then\n'
            f'  echo "$*" >> "{log}"\n'
            f'  cp "{good}" "{current}"\n'
            "  exit 0\n"
            "fi\n"
            'if [[ "$*" == *"check-runs"* ]]; then\n'
            f'  cat "{current}"\n'
            "  exit 0\n"
            "fi\n"
            "exit 0\n",
            encoding="utf-8")
        gh.chmod(0o755)
        return stub_dir

    def test_cancelled_run_is_replaced_and_the_gate_waits_for_the_replacement(self):
        script = ROOT / "await-swift-ci-checks.sh"
        sha = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "dispatch.log"
            current = root / "current.json"
            good = root / "good.json"
            current.write_text(json.dumps({"check_runs": [
                run_check("Mac package build and test", "cancelled", 1),
            ]}), encoding="utf-8")
            good.write_text(json.dumps({"check_runs": [
                run_check("Mac package build and test", "success", 2),
                run_check("iOS companion compile", "success", 3),
            ]}), encoding="utf-8")
            stub_dir = self._stub_gh(root, good, current, log)
            completed = subprocess.run(
                ["bash", str(script)],
                check=False,
                capture_output=True,
                text=True,
                env={
                    "PATH": f"{stub_dir}:/usr/bin:/bin",
                    "REPO": "Simple-With-Us/CodeCaps",
                    "SHA": sha,
                    "GH_TOKEN": "stub",
                    "REDISPATCH_ON_CANCEL": "1",
                    "DEADLINE_SECONDS": "60",
                    "POLL_SECONDS": "1",
                },
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(log.exists(), "the gate did not dispatch a replacement run")
            dispatched = log.read_text(encoding="utf-8")
            self.assertIn(f"ref={sha}", dispatched)
            self.assertIn("actions/workflows/swift-ci.yml/dispatches", dispatched)

    def test_without_the_opt_in_the_gate_does_not_dispatch(self):
        script = ROOT / "await-swift-ci-checks.sh"
        sha = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "dispatch.log"
            current = root / "current.json"
            good = root / "good.json"
            current.write_text(json.dumps({"check_runs": [
                run_check("Mac package build and test", "cancelled", 1),
            ]}), encoding="utf-8")
            good.write_text(json.dumps({"check_runs": []}), encoding="utf-8")
            stub_dir = self._stub_gh(root, good, current, log)
            completed = subprocess.run(
                ["bash", str(script)],
                check=False,
                capture_output=True,
                text=True,
                env={
                    "PATH": f"{stub_dir}:/usr/bin:/bin",
                    "REPO": "Simple-With-Us/CodeCaps",
                    "SHA": sha,
                    "GH_TOKEN": "stub",
                    "DEADLINE_SECONDS": "2",
                    "POLL_SECONDS": "1",
                },
            )
            self.assertEqual(completed.returncode, 1, completed.stderr)
            self.assertFalse(log.exists(), "the gate dispatched a replacement without the opt-in")


if __name__ == "__main__":
    unittest.main()

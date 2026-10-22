#!/usr/bin/env python3
"""Unit tests for the compile-gate check classifier and ruleset body."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import time
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

PACKAGE = "Mac package build and test"
COMPANION = "iOS companion compile"


def run_check(name: str, conclusion, run_id: int, state: str = "completed",
              app: str = "github-actions", details_url: str = ""):
    payload = {
        "name": name,
        "id": run_id,
        "status": state,
        "conclusion": conclusion,
    }
    if app is not None:
        payload["app"] = {"slug": app}
    if details_url:
        payload["details_url"] = details_url
    return payload


def job_url(workflow_run: int, check_run: int) -> str:
    """The job URL GitHub puts in a check run's details_url."""
    return (f"https://github.com/Simple-With-Us/CodeCaps/actions/runs/"
            f"{workflow_run}/job/{check_run}")


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

    def test_cancelled_run_is_a_failure_when_no_replacement_is_possible(self):
        # A cancelled run never finished, so it is no verdict about the
        # code.  A caller that cannot replace it has nothing to wait for
        # either, so the honest answer is that the run did not pass.
        payload = {"check_runs": [
            run_check("package", "cancelled", 3),
            run_check("companion", "success", 4),
        ]}
        verdict, details = status.decide([payload], self.names)
        self.assertEqual(verdict, "failure")
        self.assertIn("package=cancelled", details)

    def test_cancelled_run_is_pending_when_a_replacement_can_be_started(self):
        # With the opt-in the gate can replace the run, so a cancelled run
        # waits for its replacement instead of failing on a run that never
        # ran.
        payload = {"check_runs": [
            run_check("package", "cancelled", 3),
            run_check("companion", "success", 4),
        ]}
        verdict, details = status.decide([payload], self.names, redispatch_on_cancel=True)
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

    def test_failure_wins_over_a_cancelled_sibling_with_the_opt_in(self):
        payload = {"check_runs": [
            run_check("package", "cancelled", 3),
            run_check("companion", "failure", 4),
        ]}
        verdict, details = status.decide([payload], self.names, redispatch_on_cancel=True)
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


class LatestRunsTests(unittest.TestCase):
    def test_reports_the_check_run_id_and_the_workflow_run_id(self):
        runs = [
            run_check("package", "cancelled", 7, details_url=job_url(4242, 7)),
            run_check("package", "success", 3, details_url=job_url(1111, 3)),
        ]
        rows = status.latest_runs_by_name(runs, ["package", "companion"])
        self.assertEqual(rows, [("package", 7, 4242), ("companion", 0, 0)])

    def test_workflow_run_id_is_zero_without_a_job_url(self):
        self.assertEqual(status.workflow_run_id({}), 0)
        self.assertEqual(status.workflow_run_id({"details_url": "https://example.com"}), 0)

    def test_cli_prints_one_tab_separated_row_per_name(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "checks.json"
            path.write_text(json.dumps({"check_runs": [
                run_check("package", "cancelled", 7, details_url=job_url(4242, 7)),
            ]}), encoding="utf-8")
            completed = subprocess.run(
                ["python3", str(ROOT / "swift_ci_check_status.py"),
                 "--names", "package", "companion", "--json", str(path),
                 "--latest-runs"],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(
                completed.stdout.strip().split("\n"),
                ["package\t7\t4242", "companion\t0\t0"],
            )


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
                run_check(PACKAGE, "success", 1),
                run_check(COMPANION, "success", 2),
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
                run_check(PACKAGE, "success", 1),
            ]}), encoding="utf-8")
            pending = subprocess.run(
                ["bash", str(script)],
                check=False,
                capture_output=True,
                text=True,
                env={"CHECKS_JSON": str(path), "PATH": "/usr/bin:/bin"},
            )
            self.assertEqual(pending.returncode, 2, pending.stderr)

    def test_cancelled_fixture_is_a_failure_without_the_opt_in(self):
        # A cancelled run is a failure when the gate cannot replace it:  the
        # old exit-1 behaviour, so the caller learns at once instead of
        # polling for a run that will never arrive.
        script = ROOT / "await-swift-ci-checks.sh"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "checks.json"
            path.write_text(json.dumps({"check_runs": [
                run_check(PACKAGE, "cancelled", 1),
            ]}), encoding="utf-8")
            failed = subprocess.run(
                ["bash", str(script)],
                check=False,
                capture_output=True,
                text=True,
                env={"CHECKS_JSON": str(path), "PATH": "/usr/bin:/bin"},
            )
            self.assertEqual(failed.returncode, 1, failed.stderr)
            self.assertIn(f"{PACKAGE}=cancelled", failed.stderr)

    def test_cancelled_fixture_is_pending_with_the_opt_in(self):
        script = ROOT / "await-swift-ci-checks.sh"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "checks.json"
            path.write_text(json.dumps({"check_runs": [
                run_check(PACKAGE, "cancelled", 1),
            ]}), encoding="utf-8")
            pending = subprocess.run(
                ["bash", str(script)],
                check=False,
                capture_output=True,
                text=True,
                env={
                    "CHECKS_JSON": str(path),
                    "PATH": "/usr/bin:/bin",
                    "REDISPATCH_ON_CANCEL": "1",
                },
            )
            self.assertEqual(pending.returncode, 2, pending.stderr)


STUB = """#!/usr/bin/env bash
set -u
if [[ "$*" == *"/rerun"* ]]; then
  echo "$*" >> "@LOG@"
@ON_RERUN@
  exit 0
fi
if [[ "$*" == *"check-runs"* ]]; then
  echo "$*" >> "@LOG@"
  cat "@CURRENT@"
  exit 0
fi
exit 0
"""

# A clock that only moves when the gate asks for the time, so the deadline
# is a number of polls instead of a number of seconds.  The gate reads the
# clock once to work out its deadline and once per poll.
CLOCK_STUB = """#!/usr/bin/env bash
set -u
n=0
if [[ -f "@COUNTER@" ]]; then n=$(cat "@COUNTER@"); fi
n=$(( n + 1 ))
echo "$n" > "@COUNTER@"
echo $(( 1700000000 + n ))
"""


class GateStub:
    """A gh and date stub that serve one check-run payload and record calls.

    The stubbed clock makes DEADLINE_SECONDS the number of poll rounds the
    gate gets before it gives up, so the tests neither sleep nor race the
    wall clock.
    """

    def __init__(self, root: Path, on_rerun: str = ""):
        self.root = root
        self.log = root / "calls.log"
        self.current = root / "current.json"
        stub_dir = root / "bin"
        stub_dir.mkdir(parents=True, exist_ok=True)
        gh = stub_dir / "gh"
        gh.write_text(
            STUB.replace("@LOG@", str(self.log))
            .replace("@CURRENT@", str(self.current))
            .replace("@ON_RERUN@", on_rerun),
            encoding="utf-8")
        gh.chmod(0o755)
        clock = stub_dir / "date"
        clock.write_text(CLOCK_STUB.replace("@COUNTER@", str(root / "clock")), encoding="utf-8")
        clock.chmod(0o755)
        self.path = f"{stub_dir}:/usr/bin:/bin"

    def write_payload(self, payload):
        self.current.write_text(json.dumps(payload), encoding="utf-8")

    def calls(self):
        if not self.log.exists():
            return []
        return [line for line in self.log.read_text(encoding="utf-8").split("\n") if line]

    def reruns(self):
        return [call for call in self.calls() if "/rerun" in call]


def cancelled_payload(check_id: int = 1, workflow_run: int = 4242):
    return {"check_runs": [
        run_check(PACKAGE, "cancelled", check_id, details_url=job_url(workflow_run, check_id)),
    ]}


def success_payload():
    return {"check_runs": [
        run_check(PACKAGE, "success", 900, details_url=job_url(4242, 900)),
        run_check(COMPANION, "success", 901, details_url=job_url(4242, 901)),
    ]}


class RedispatchTests(unittest.TestCase):
    """The gate replaces a cancelled compile run instead of waiting forever."""

    def run_gate(self, stub: GateStub, sha: str, extra_env=None):
        env = {
            "PATH": stub.path,
            "REPO": "Simple-With-Us/CodeCaps",
            "SHA": sha,
            "GH_TOKEN": "stub",
            "REDISPATCH_ON_CANCEL": "1",
            "DEADLINE_SECONDS": "4",
            "POLL_SECONDS": "0",
        }
        env.update(extra_env or {})
        return subprocess.run(
            ["bash", str(ROOT / "await-swift-ci-checks.sh")],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_cancelled_run_is_replaced_and_the_gate_waits_for_the_replacement(self):
        sha = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            good = root / "good.json"
            good.write_text(json.dumps(success_payload()), encoding="utf-8")
            stub = GateStub(root, on_rerun=f'cp "{good}" "{root / "current.json"}"')
            stub.write_payload(cancelled_payload())
            completed = self.run_gate(stub, sha)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            reruns = stub.reruns()
            self.assertEqual(len(reruns), 1, f"expected one replacement, got {reruns}")
            self.assertIn("actions/runs/4242/rerun", reruns[0])
            self.assertTrue(
                any(f"commits/{sha}/check-runs" in call for call in stub.calls()),
                "the gate never polled the commit it was asked about",
            )

    def test_without_the_opt_in_the_gate_fails_fast_and_names_the_cancelled_check(self):
        sha = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stub = GateStub(root)
            stub.write_payload(cancelled_payload())
            completed = self.run_gate(
                stub, sha, extra_env={"REDISPATCH_ON_CANCEL": "0", "DEADLINE_SECONDS": "600"})
            self.assertEqual(completed.returncode, 1, completed.stderr)
            self.assertIn(f"{PACKAGE}=cancelled", completed.stdout)
            self.assertNotIn("Timed out", completed.stdout)
            self.assertEqual(stub.reruns(), [], "the gate replaced a run without the opt-in")

    def test_a_replacement_is_not_started_again_until_a_newer_run_appears(self):
        # The replacement may not show up in the API right away.  The gate
        # must not spend its budget on the stale cancelled row it is still
        # looking at.
        sha = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stub = GateStub(root)
            stub.write_payload(cancelled_payload())
            completed = self.run_gate(stub, sha, extra_env={"MAX_REDISPATCH": "3"})
            self.assertEqual(completed.returncode, 1, completed.stderr)
            reruns = stub.reruns()
            self.assertEqual(len(reruns), 1, f"expected one replacement, got {reruns}")

    def test_the_replacement_budget_caps_the_attempts(self):
        sha = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            counter = root / "counter"
            # Every replacement comes back as a newer cancelled row, so the
            # gate is free to try again until the budget runs out.
            on_rerun = (
                f'n=$(cat "{counter}" 2>/dev/null || echo 0)\n'
                'n=$(( n + 1 ))\n'
                f'echo "$n" > "{counter}"\n'
                'id=$(( 100 + n ))\n'
                'printf \'{"check_runs": [{"name": "Mac package build and test", '
                '"id": %s, "status": "completed", "conclusion": "cancelled", '
                '"app": {"slug": "github-actions"}, "details_url": '
                '"https://github.com/Simple-With-Us/CodeCaps/actions/runs/4242/job/%s"}]}\\n\' '
                f'"$id" "$id" > "{root / "current.json"}"\n'
            )
            stub = GateStub(root, on_rerun=on_rerun)
            stub.write_payload(cancelled_payload())
            completed = self.run_gate(stub, sha, extra_env={"MAX_REDISPATCH": "2"})
            self.assertEqual(completed.returncode, 1, completed.stderr)
            reruns = stub.reruns()
            self.assertEqual(len(reruns), 2, f"expected two replacements, got {reruns}")
            self.assertIn("replacement budget (2) is spent", completed.stdout)

    def test_no_replacement_while_the_run_is_only_in_progress(self):
        sha = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stub = GateStub(root)
            stub.write_payload({"check_runs": [
                run_check(PACKAGE, None, 1, state="in_progress"),
            ]})
            completed = self.run_gate(stub, sha)
            self.assertEqual(completed.returncode, 1, completed.stderr)
            self.assertEqual(stub.reruns(), [], "the gate replaced a run that was still running")

    def test_no_replacement_when_no_run_exists_at_all(self):
        sha = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stub = GateStub(root)
            stub.write_payload({"check_runs": []})
            completed = self.run_gate(stub, sha)
            self.assertEqual(completed.returncode, 1, completed.stderr)
            self.assertEqual(stub.reruns(), [], "the gate replaced a run that never existed")

    def test_a_failed_replacement_does_not_spend_the_budget(self):
        sha = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            good = root / "good.json"
            good.write_text(json.dumps(success_payload()), encoding="utf-8")
            counter = root / "counter"
            # The first attempt fails, the second one lands.
            on_rerun = (
                f'n=$(cat "{counter}" 2>/dev/null || echo 0)\n'
                'n=$(( n + 1 ))\n'
                f'echo "$n" > "{counter}"\n'
                'if [ "$n" -lt 2 ]; then exit 1; fi\n'
                f'cp "{good}" "{root / "current.json"}"\n'
            )
            stub = GateStub(root, on_rerun=on_rerun)
            stub.write_payload(cancelled_payload())
            completed = self.run_gate(stub, sha, extra_env={"MAX_REDISPATCH": "2"})
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(len(stub.reruns()), 2, "the gate did not retry the replacement")
            self.assertIn("no budget was spent", completed.stdout)
            self.assertIn("(1 of 2)", completed.stdout)

    def test_a_replacement_that_keeps_failing_stops_the_gate(self):
        sha = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stub = GateStub(root, on_rerun="exit 1")
            stub.write_payload(cancelled_payload())
            completed = self.run_gate(stub, sha, extra_env={"MAX_REDISPATCH": "2"})
            self.assertEqual(completed.returncode, 1, completed.stderr)
            self.assertIn("could not be started after 2 attempts", completed.stdout)
            self.assertEqual(len(stub.reruns()), 2, "the gate retried forever")


class GateSpeedTests(unittest.TestCase):
    def test_the_gate_does_not_wait_out_the_deadline_on_a_cancelled_run(self):
        script = ROOT / "await-swift-ci-checks.sh"
        sha = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "checks.json"
            path.write_text(json.dumps(cancelled_payload()), encoding="utf-8")
            started = time.monotonic()
            completed = subprocess.run(
                ["bash", str(script)],
                check=False,
                capture_output=True,
                text=True,
                env={
                    "CHECKS_JSON": str(path),
                    "PATH": "/usr/bin:/bin",
                    "DEADLINE_SECONDS": "600",
                },
            )
            elapsed = time.monotonic() - started
            self.assertEqual(completed.returncode, 1, completed.stderr)
            self.assertLess(elapsed, 30, "the gate waited out the deadline on a cancelled run")


if __name__ == "__main__":
    unittest.main()

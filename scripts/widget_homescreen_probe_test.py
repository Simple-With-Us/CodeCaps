#!/usr/bin/env python3
"""Unit tests for the home-screen WidgetKit probe.  No simulator and no network."""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from widget_homescreen_probe import (  # noqa: E402
    APP_ENTITLEMENTS,
    COMPANION_YML,
    DEVICE_PREFIX,
    EXIT_UNSUPPORTED,
    HOST_TARGET,
    PROBE_SOURCES,
    ROOT,
    UI_TARGET,
    WIDGET_ENTITLEMENTS,
    Host,
    Outcome,
    argv_disturbs_gui,
    booted_udids,
    build_seed,
    codesign_argv,
    companion_app,
    companion_build_argv,
    companion_bundle_ids,
    deletion_allowed,
    interpret_log,
    main,
    materialize_probe_project,
    outcome_code,
    parse_created_udid,
    parse_data_container,
    parse_group_container,
    prepare_environment,
    probe_bundle_ids,
    probe_test_argv,
    read_app_group,
    screenshot_argv,
    seed_paths,
    select_device_type,
    select_runtime,
    unsupported_failure_line,
    write_seed,
)

NOW = datetime(2026, 11, 12, 1, 0, tzinfo=timezone.utc)
UDID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"


def darwin_host() -> Host:
    return Host("Darwin", frozenset({"xcrun", "xcodebuild", "codesign"}))


class HostAndRuntimeTests(unittest.TestCase):
    def test_linux_is_an_unsupported_path(self):
        prepared = prepare_environment(Host("Linux", frozenset()), [], [], [])
        self.assertIsNotNone(prepared.refusal)
        self.assertIn("unsupported-path:", prepared.refusal or "")
        self.assertIn("Linux", prepared.refusal or "")

    def test_darwin_without_tools_names_each_missing_tool(self):
        prepared = prepare_environment(Host("Darwin", frozenset()), [], [], [])
        self.assertIn("missing xcrun, xcodebuild, codesign", prepared.refusal or "")

    def test_a_booted_simulator_refuses_before_a_gallery_run(self):
        prepared = prepare_environment(
            darwin_host(),
            [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "version": "27.2", "isAvailable": True}],
            [{"name": "iPhone 17", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"}],
            ["USER-SIM"],
        )
        self.assertIn("already booted", prepared.refusal or "")
        self.assertIn("USER-SIM", prepared.refusal or "")
        self.assertIsNone(prepared.runtime_id)

    def test_main_on_linux_exits_78_without_creating_the_work_directory(self):
        work = Path(tempfile.mkdtemp(prefix="codecaps-cc219-")) / "absent"
        previous = os.environ.get("CODECAPS_WIDGET_HOMESCREEN_DIR")
        os.environ["CODECAPS_WIDGET_HOMESCREEN_DIR"] = str(work)
        try:
            code = main(["widget_homescreen_probe.py"], host=Host("Linux", frozenset()))
        finally:
            if previous is None:
                os.environ.pop("CODECAPS_WIDGET_HOMESCREEN_DIR", None)
            else:
                os.environ["CODECAPS_WIDGET_HOMESCREEN_DIR"] = previous
        self.assertEqual(code, EXIT_UNSUPPORTED)
        self.assertFalse(work.exists())

    def test_selects_the_newest_pinned_ios_runtime(self):
        runtime, refusal = select_runtime(
            [
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-16-4", "version": "16.4", "isAvailable": True},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-1", "version": "26.1", "isAvailable": True},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "version": "27.2", "isAvailable": True},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0", "version": "18.0", "isAvailable": False},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-28-0", "version": "28.0", "isAvailable": True},
            ]
        )
        self.assertIsNone(refusal)
        self.assertEqual(runtime["version"], "27.2")

    def test_ios_28_alone_is_outside_the_pinned_contract(self):
        runtime, refusal = select_runtime(
            [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-28-0", "version": "28.0", "isAvailable": True}]
        )
        self.assertIsNone(runtime)
        self.assertIn("unsupported-path:", refusal or "")

    def test_prefers_a_plain_iphone_of_the_highest_generation(self):
        device, refusal = select_device_type(
            [
                {"name": "iPhone 16 Pro", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"},
                {"name": "iPhone 17 Pro Max", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"},
                {"name": "iPhone 17", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
                {"name": "iPad Pro 13-inch", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch"},
            ]
        )
        self.assertIsNone(refusal)
        self.assertEqual(device["name"], "iPhone 17")

    def test_booted_udids_ignore_shutdown_devices(self):
        udids = booted_udids(
            {
                "devices": {
                    "iOS 27.2": [
                        {"udid": "BOOTED", "state": "Booted", "name": "iPhone"},
                        {"udid": "SHUT", "state": "Shutdown", "name": "Other"},
                    ]
                }
            }
        )
        self.assertEqual(udids, ["BOOTED"])


class SeedAndResultTests(unittest.TestCase):
    def test_seed_is_fresh_and_carries_the_sentinel(self):
        payload = build_seed(NOW)
        windows = {item["providerKey"]: item for item in payload["windows"]}
        copilot = windows["github-copilot"]
        self.assertEqual(copilot["remainingPercent"], 37)
        self.assertEqual(copilot["occurredAt"], "2026-11-12T01:00:00Z")
        self.assertEqual(copilot["reportedAt"], copilot["occurredAt"])
        self.assertGreater(copilot["resetAt"], copilot["occurredAt"])
        reset = datetime.strptime(copilot["resetAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        self.assertGreater(reset, NOW + timedelta(days=1))
        self.assertEqual(windows["minimax"]["remainingPercent"], 90)
        self.assertNotEqual(windows["minimax"]["remainingPercent"], 37)

    def test_seed_file_is_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "quota-windows.json"
            write_seed(path, build_seed(NOW))
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["windows"][0]["providerKey"], "github-copilot")

    def test_seed_paths_cover_the_group_and_both_data_containers(self):
        paths = seed_paths("/group", "/app", "/widget")
        self.assertEqual(paths[0], Path("/group/quota-windows.json"))
        self.assertEqual(
            paths[1],
            Path("/app/Library/Application Support/CodeCaps/quota-windows.json"),
        )
        self.assertEqual(
            paths[2],
            Path("/widget/Library/Application Support/CodeCaps/quota-windows.json"),
        )
        self.assertEqual(len(seed_paths("/group", "/app", None)), 2)

    def test_group_container_parser_reads_the_matching_path(self):
        text = "group.example.other: /tmp/other\ngroup.example.codecaps: /tmp/codecaps/group\n"
        self.assertEqual(parse_group_container(text, "group.example.codecaps"), "/tmp/codecaps/group")
        self.assertEqual(
            parse_group_container("group.example.codecaps\n/tmp/codecaps/group\n", "group.example.codecaps"),
            "/tmp/codecaps/group",
        )
        self.assertIsNone(parse_group_container(text, "group.missing"))
        self.assertEqual(parse_data_container("/tmp/app-data\n"), "/tmp/app-data")

    def test_source_dump_of_the_failure_string_is_not_a_refusal(self):
        log = (
            'XCTFail("unsupported-path: Edit control missing after long-press")\n'
            "** TEST SUCCEEDED **\n"
        )
        self.assertIsNone(unsupported_failure_line(log))
        outcome, _ = interpret_log(log, 12000)
        self.assertEqual(outcome, Outcome.VERIFIED)

    def test_a_real_gallery_mismatch_stays_a_refusal(self):
        log = (
            "error: -[WidgetHomeScreenProbeUITests testHomeScreenRendersSeededQuota] : "
            "failed - unsupported-path: Edit control missing after long-press\n"
            "** TEST FAILED **\n"
        )
        outcome, message = interpret_log(log, 12000)
        self.assertEqual(outcome, Outcome.UNSUPPORTED)
        self.assertEqual(outcome_code(outcome), EXIT_UNSUPPORTED)
        self.assertIn("Edit control missing", message)

    def test_success_without_a_screenshot_is_a_failure(self):
        outcome, message = interpret_log("** TEST SUCCEEDED **\n", 0)
        self.assertEqual(outcome, Outcome.FAILED)
        self.assertIn("screenshot", message)

    def test_deletion_only_matches_the_disposable_device_we_named(self):
        devices = {
            "devices": {
                "iOS 27.2": [
                    {"udid": UDID, "name": f"{DEVICE_PREFIX}9", "state": "Shutdown"},
                    {"udid": "USER", "name": "iPhone 17", "state": "Booted"},
                ]
            }
        }
        self.assertTrue(deletion_allowed(devices, UDID, f"{DEVICE_PREFIX}9"))
        self.assertFalse(deletion_allowed(devices, "USER", "iPhone 17"))
        self.assertFalse(deletion_allowed(devices, UDID, "iPhone 17"))
        self.assertFalse(deletion_allowed(devices, UDID, "codecaps-other"))


class CommandPlanTests(unittest.TestCase):
    def test_commands_do_not_open_simulator_app(self):
        derived = Path("/tmp/derived")
        project = Path("/tmp/probe/WidgetHomeScreenProbe.xcodeproj")
        commands = [
            companion_build_argv(UDID, derived),
            codesign_argv(companion_app(derived) / "PlugIns" / "CodeCapsWidgets.appex", WIDGET_ENTITLEMENTS),
            codesign_argv(companion_app(derived), APP_ENTITLEMENTS),
            probe_test_argv(project, UDID, derived, Path("/tmp/result.xcresult")),
            screenshot_argv(UDID, Path("/tmp/home-screen.png")),
            ["xcrun", "simctl", "create", f"{DEVICE_PREFIX}1", "type", "runtime"],
            ["xcrun", "simctl", "boot", UDID],
            ["xcrun", "simctl", "delete", UDID],
        ]
        for argv in commands:
            self.assertFalse(argv_disturbs_gui(argv), argv)
        self.assertTrue(argv_disturbs_gui(["open", "-a", "Simulator"]))
        self.assertTrue(argv_disturbs_gui(["xcrun", "open", "/Applications/Simulator.app"]))

    def test_ui_test_does_not_clone_or_retry(self):
        argv = probe_test_argv(Path("/tmp/p.xcodeproj"), UDID, Path("/tmp/d"), Path("/tmp/r.xcresult"))
        self.assertEqual(argv[argv.index("-parallel-testing-enabled") + 1], "NO")
        self.assertNotIn("-retry-tests-on-failure", argv)
        self.assertIn(f"platform=iOS Simulator,id={UDID}", argv)
        self.assertIn("simctl", screenshot_argv(UDID, Path("/tmp/home-screen.png"))[1])
        self.assertIn("screenshot", screenshot_argv(UDID, Path("/tmp/home-screen.png")))

    def test_created_udid_parser(self):
        self.assertEqual(parse_created_udid(f"  {UDID.lower()}\n"), UDID.lower())


class ProjectAndContractTests(unittest.TestCase):
    def test_companion_ids_and_shared_app_group(self):
        app, widget = companion_bundle_ids(COMPANION_YML.read_text(encoding="utf-8"))
        self.assertTrue(app.endswith(".ios"))
        self.assertFalse(app.endswith(".widgets"))
        self.assertTrue(widget.endswith(".ios.widgets"))
        host, ui = probe_bundle_ids(app)
        self.assertTrue(host.endswith(".probe.host"))
        self.assertTrue(ui.endswith(".probe.uitests"))
        self.assertEqual(read_app_group(APP_ENTITLEMENTS), read_app_group(WIDGET_ENTITLEMENTS))

    def test_materialized_probe_is_a_ui_test_project(self):
        app, _widget = companion_bundle_ids(COMPANION_YML.read_text(encoding="utf-8"))
        host, ui = probe_bundle_ids(app)
        with tempfile.TemporaryDirectory() as directory:
            project = materialize_probe_project(Path(directory) / "probe", host, ui)
            pbx = (project / "project.pbxproj").read_text(encoding="utf-8")
            scheme = (project / "xcshareddata" / "xcschemes" / "WidgetHomeScreenProbe.xcscheme").read_text(
                encoding="utf-8"
            )
        self.assertIn("com.apple.product-type.bundle.ui-testing", pbx)
        self.assertIn("WidgetHomeScreenProbeUITests.swift", pbx)
        self.assertIn(host, pbx)
        self.assertIn(ui, pbx)
        self.assertEqual(pbx.count("{"), pbx.count("}"))
        self.assertIn(UI_TARGET, scheme)
        self.assertIn(HOST_TARGET, scheme)
        self.assertNotIn("Simulator.app", pbx)

    def test_swift_oracle_matches_the_seed_and_the_widget_name(self):
        swift = (PROBE_SOURCES / "UITests" / "WidgetHomeScreenProbeUITests.swift").read_text(encoding="utf-8")
        bundle = (ROOT / "ios/CodeCapsCompanion/Widgets/CodeCapsWidgetBundle.swift").read_text(encoding="utf-8")
        self.assertIn('sentinelTitle = "GitHub Copilot"', swift)
        self.assertIn('sentinelPercent = "37%"', swift)
        self.assertIn("unsupported-path: Edit control missing after long-press", swift)
        self.assertIn("unsupported-path: Done control missing after add", swift)
        self.assertIn("existingResult", swift)
        self.assertIn('configurationDisplayName("AI Subscription Overview")', bundle)
        self.assertIn("AI Subscription Overview", swift)

    def test_off_device_widget_probe_still_compiles_the_real_views(self):
        text = (ROOT / "scripts/test-widget-ui-native.sh").read_text(encoding="utf-8")
        self.assertIn("swiftc -parse-as-library", text)
        self.assertIn("Tests/Fixtures/WidgetUIProbe.swift", text)
        self.assertNotIn("unsupported-path", text)

    def test_shell_entry_and_docs_and_workflow(self):
        shell = (ROOT / "scripts/test-widget-homescreen.sh").read_text(encoding="utf-8")
        self.assertIn("set -euo pipefail", shell)
        self.assertIn("exec python3 scripts/widget_homescreen_probe.py", shell)
        docs = (ROOT / "docs/WIDGETS.md").read_text(encoding="utf-8")
        self.assertIn("scripts/test-widget-homescreen.sh", docs)
        self.assertIn("unsupported-path", docs)
        self.assertIn("37%", docs)
        self.assertIn("\u00a0 ", docs)
        workflow = (ROOT / ".github/workflows/widget-homescreen.yml").read_text(encoding="utf-8")
        self.assertIn("macos-latest", workflow)
        self.assertIn("scripts/test-widget-homescreen.sh", workflow)
        self.assertIn("scripts/widget_homescreen_probe_test.py", workflow)
        self.assertNotIn("force-ship", workflow)
        self.assertNotIn("ios-ship.yml", workflow)
        self.assertNotIn("mac-release.yml", workflow)
        rollout = (ROOT / "docs/rollouts/2026-10-27-iphone-widget-quota-ui.md").read_text(encoding="utf-8")
        self.assertIn("scripts/test-widget-homescreen.sh", rollout)


if __name__ == "__main__":
    unittest.main()

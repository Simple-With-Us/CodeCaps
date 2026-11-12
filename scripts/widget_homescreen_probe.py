#!/usr/bin/env python3
"""Headless iOS Home Screen WidgetKit probe (CC-219).

The off-device renderer never places a widget on SpringBoard.  This driver
creates a disposable simulator, installs the companion, seeds a fresh App
Group snapshot, and runs a scratch XCUITest that adds the widget through the
pinned Edit → Add Widget gallery contract.  simctl takes the screenshot.

Exit 0 means SpringBoard showed the seeded reading and a screenshot was
written.  Exit 78 is a deterministic unsupported-path refusal:  the wrong
OS, a missing tool, a simulator that is already booted, an iOS runtime
outside 18-27, a missing App Group container, or a gallery control the
pinned contract does not recognise.  Anything else exits 1.  A refusal is
never reported as a pass.

The driver does not open Simulator.app and deletes only the simulator it
created.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from enum import Enum
from pathlib import Path

EXIT_VERIFIED = 0
EXIT_FAILED = 1
EXIT_UNSUPPORTED = 78

DEVICE_PREFIX = "codecaps-cc219-"
MIN_IOS_MAJOR = 18
MAX_IOS_MAJOR = 27
SENTINEL_PROVIDER_KEY = "github-copilot"
SENTINEL_TITLE = "GitHub Copilot"
SENTINEL_PERCENT = 37
REQUIRED_TOOLS = ("xcrun", "xcodebuild", "codesign")
UDID_RE = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)
UNSUPPORTED_FAILURE_MARKERS = (
    "failed - unsupported-path:",
    "failed: unsupported-path:",
)

ROOT = Path(__file__).resolve().parent.parent
PROBE_SOURCES = ROOT / "ios" / "WidgetHomeScreenProbe"
COMPANION_YML = ROOT / "ios" / "CodeCapsCompanion" / "project.yml"
COMPANION_PROJECT = ROOT / "ios" / "CodeCapsCompanion" / "CodeCapsCompanion.xcodeproj"
APP_ENTITLEMENTS = ROOT / "ios" / "CodeCapsCompanion" / "App" / "CodeCapsCompanion.entitlements"
WIDGET_ENTITLEMENTS = (
    ROOT / "ios" / "CodeCapsCompanion" / "Widgets" / "CodeCapsWidgets.entitlements"
)

HOST_TARGET = "A10000000000000000000002"
UI_TARGET = "A10000000000000000000003"


class ProbeFailure(Exception):
    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code


class Outcome(Enum):
    VERIFIED = "verified"
    UNSUPPORTED = "unsupported"
    FAILED = "failed"


@dataclass(frozen=True)
class Host:
    system: str
    executables: frozenset[str]


@dataclass(frozen=True)
class PrepareResult:
    runtime_id: str | None
    runtime_version: str | None
    device_type_id: str | None
    refusal: str | None


def inspect_host() -> Host:
    return Host(
        system=os.uname().sysname,
        executables=frozenset(name for name in REQUIRED_TOOLS if shutil.which(name)),
    )


def classify_host(host: Host) -> str | None:
    if host.system != "Darwin":
        return (
            "unsupported-path: home-screen WidgetKit render requires macOS (Darwin); "
            f"this host is {host.system}"
        )
    missing = [name for name in REQUIRED_TOOLS if name not in host.executables]
    if missing:
        return "unsupported-path: missing " + ", ".join(missing)
    return None


def version_key(version: str) -> tuple[int, ...]:
    parts: list[int] = []
    for piece in version.split("."):
        if not piece.isdigit():
            return ()
        parts.append(int(piece))
    return tuple(parts)


def select_runtime(runtimes: list[dict]) -> tuple[dict | None, str | None]:
    chosen: list[tuple[tuple[int, ...], dict]] = []
    for runtime in runtimes:
        if not isinstance(runtime, dict) or runtime.get("isAvailable") is False:
            continue
        identifier = str(runtime.get("identifier", ""))
        name = str(runtime.get("name", ""))
        if "iOS" not in identifier and not name.startswith("iOS"):
            continue
        key = version_key(str(runtime.get("version", "")))
        if not key or key[0] < MIN_IOS_MAJOR or key[0] > MAX_IOS_MAJOR:
            continue
        chosen.append((key, runtime))
    if not chosen:
        return None, (
            f"unsupported-path: no available iOS {MIN_IOS_MAJOR}-{MAX_IOS_MAJOR} "
            "simulator runtime for the pinned Edit, Add Widget gallery contract"
        )
    chosen.sort(key=lambda item: item[0])
    return chosen[-1][1], None


def device_rank(identifier: str) -> tuple[int, int]:
    match = re.search(r"iPhone-(\d+)", identifier)
    number = int(match.group(1)) if match else 0
    if re.search(r"iPhone-\d+$", identifier):
        kind = 3
    elif identifier.endswith("-Pro"):
        kind = 2
    else:
        kind = 1
    return number, kind


def select_device_type(device_types: list[dict]) -> tuple[dict | None, str | None]:
    iphones = []
    for item in device_types:
        if not isinstance(item, dict):
            continue
        identifier = str(item.get("identifier", ""))
        name = str(item.get("name", ""))
        if "iPhone" not in name or "iPhone-" not in identifier:
            continue
        iphones.append(item)
    if not iphones:
        return None, "unsupported-path: no iPhone simulator device type is installed"
    iphones.sort(key=lambda item: device_rank(str(item.get("identifier", ""))))
    return iphones[-1], None


def booted_udids(devices_json: dict) -> list[str]:
    found: list[str] = []
    for group in devices_json.get("devices", {}).values():
        if not isinstance(group, list):
            continue
        for device in group:
            if isinstance(device, dict) and device.get("state") == "Booted" and device.get("udid"):
                found.append(str(device["udid"]))
    return found


def prepare_environment(
    host: Host,
    runtimes: list[dict],
    device_types: list[dict],
    booted: list[str],
) -> PrepareResult:
    refusal = classify_host(host)
    if refusal:
        return PrepareResult(None, None, None, refusal)
    if booted:
        return PrepareResult(
            None,
            None,
            None,
            "unsupported-path: a simulator is already booted; refusing to disturb a GUI session: "
            + ", ".join(booted),
        )
    runtime, runtime_refusal = select_runtime(runtimes)
    if runtime is None:
        return PrepareResult(None, None, None, runtime_refusal)
    device, device_refusal = select_device_type(device_types)
    if device is None:
        return PrepareResult(None, None, None, device_refusal)
    return PrepareResult(
        str(runtime.get("identifier", "")),
        str(runtime.get("version", "")),
        str(device.get("identifier", "")),
        None,
    )


def companion_bundle_ids(yml: str) -> tuple[str, str]:
    ids = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", yml)
    ios = [item for item in ids if ".ios" in item and ".macos" not in item]
    apps = [item for item in ios if not item.endswith(".widgets")]
    widgets = [item for item in ios if item.endswith(".widgets")]
    if len(apps) != 1 or len(widgets) != 1:
        raise ProbeFailure(
            "failed: companion project.yml is missing the iOS app and widget bundle ids",
            EXIT_FAILED,
        )
    return apps[0], widgets[0]


def probe_bundle_ids(app_bundle: str) -> tuple[str, str]:
    base = app_bundle[: -len(".ios")] if app_bundle.endswith(".ios") else app_bundle
    return base + ".probe.host", base + ".probe.uitests"


def read_app_group(path: Path) -> str:
    payload = plistlib.loads(path.read_bytes())
    groups = payload.get("com.apple.security.application-groups")
    if not isinstance(groups, list) or len(groups) != 1 or not isinstance(groups[0], str):
        raise ProbeFailure(f"failed: expected one app group in {path}", EXIT_FAILED)
    return groups[0]


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _window(
    window_id: str,
    provider: str,
    label: str,
    window: str,
    window_key: str,
    percent: int,
    occurred: str,
    reset: str,
) -> dict:
    return {
        "id": window_id,
        "provider": provider,
        "providerKey": provider,
        "label": label,
        "window": window,
        "windowKey": window_key,
        "remainingPercent": percent,
        "isExhausted": False,
        "occurredAt": occurred,
        "reportedAt": occurred,
        "resetAt": reset,
    }


def build_seed(now: datetime) -> dict:
    if now.tzinfo is None:
        raise ValueError("seed timestamp must be timezone-aware")
    occurred = _iso(now)
    # GitHub Copilot at 37% is the oracle.  Gallery placeholders use other
    # providers and other percentages, and a battery readout can say 37%
    # without ever saying GitHub Copilot.  MiniMax stays on the snapshot so
    # a multi-plan widget still has a second row; it is not the oracle.
    return {
        "windows": [
            _window(
                "cc219:github-copilot:monthly",
                SENTINEL_PROVIDER_KEY,
                "Monthly window",
                "1m",
                "monthly",
                SENTINEL_PERCENT,
                occurred,
                _iso(now + timedelta(days=12)),
            ),
            _window(
                "cc219:minimax:7d",
                "minimax",
                "7-day window",
                "7d",
                "7d",
                90,
                occurred,
                _iso(now + timedelta(days=3)),
            ),
        ]
    }


def write_seed(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    path.write_bytes(data)
    os.chmod(path, 0o600)


def seed_paths(group: str, app_data: str, widget_data: str | None) -> list[Path]:
    paths = [
        Path(group) / "quota-windows.json",
        Path(app_data) / "Library" / "Application Support" / "CodeCaps" / "quota-windows.json",
    ]
    if widget_data:
        paths.append(
            Path(widget_data) / "Library" / "Application Support" / "CodeCaps" / "quota-windows.json"
        )
    return paths


def parse_created_udid(output: str) -> str:
    match = UDID_RE.search(output)
    if not match:
        raise ProbeFailure("failed: simctl create did not return a simulator UDID", EXIT_FAILED)
    return match.group(0)


def parse_data_container(text: str) -> str | None:
    for line in text.splitlines():
        candidate = line.strip()
        if candidate.startswith("/"):
            return candidate
    return None


def parse_group_container(text: str, group_id: str) -> str | None:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if group_id not in line:
            continue
        for token in reversed(line.split()):
            if token.startswith("/"):
                return token
        if index + 1 < len(lines):
            following = lines[index + 1].strip()
            if following.startswith("/"):
                return following
    return None


def find_device(devices_json: dict, udid: str) -> dict | None:
    for group in devices_json.get("devices", {}).values():
        if not isinstance(group, list):
            continue
        for device in group:
            if isinstance(device, dict) and device.get("udid") == udid:
                return device
    return None


def deletion_allowed(devices_json: dict, udid: str, expected_name: str) -> bool:
    if not expected_name.startswith(DEVICE_PREFIX):
        return False
    device = find_device(devices_json, udid)
    return device is not None and device.get("name") == expected_name


def argv_disturbs_gui(argv: list[str]) -> bool:
    if not argv:
        return False
    if argv[0] == "open":
        return True
    return any("Simulator.app" in arg for arg in argv)


def companion_app(derived: Path) -> Path:
    return derived / "Build" / "Products" / "Debug-iphonesimulator" / "CodeCapsCompanion.app"


def companion_build_argv(udid: str, derived: Path) -> list[str]:
    return [
        "xcodebuild",
        "-project",
        str(COMPANION_PROJECT),
        "-scheme",
        "CodeCapsCompanion",
        "-destination",
        f"platform=iOS Simulator,id={udid}",
        "-derivedDataPath",
        str(derived),
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGN_IDENTITY=",
        "CODE_SIGNING_REQUIRED=NO",
        "COMPILER_INDEX_STORE_ENABLE=NO",
        "build",
    ]


def codesign_argv(bundle: Path, entitlements: Path) -> list[str]:
    return [
        "codesign",
        "--force",
        "--sign",
        "-",
        "--entitlements",
        str(entitlements),
        str(bundle),
    ]


def probe_test_argv(project: Path, udid: str, derived: Path, result: Path) -> list[str]:
    return [
        "xcodebuild",
        "test",
        "-project",
        str(project),
        "-scheme",
        "WidgetHomeScreenProbe",
        "-destination",
        f"platform=iOS Simulator,id={udid}",
        "-derivedDataPath",
        str(derived),
        "-resultBundlePath",
        str(result),
        "-only-testing:WidgetHomeScreenProbeUITests/WidgetHomeScreenProbeUITests/testHomeScreenRendersSeededQuota",
        "-parallel-testing-enabled",
        "NO",
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGN_IDENTITY=",
        "CODE_SIGNING_REQUIRED=NO",
        "COMPILER_INDEX_STORE_ENABLE=NO",
    ]


def screenshot_argv(udid: str, png: Path) -> list[str]:
    return ["xcrun", "simctl", "io", udid, "screenshot", str(png)]


def unsupported_failure_line(log: str) -> str | None:
    for line in log.splitlines():
        for marker in UNSUPPORTED_FAILURE_MARKERS:
            if marker in line:
                return "unsupported-path:" + line.split(marker, 1)[1].strip()
    return None


def interpret_log(log: str, screenshot_bytes: int) -> tuple[Outcome, str]:
    detail = unsupported_failure_line(log)
    if detail:
        return Outcome.UNSUPPORTED, detail
    if "** TEST SUCCEEDED **" in log and screenshot_bytes > 0:
        return (
            Outcome.VERIFIED,
            "home-screen widget rendered the seeded GitHub Copilot 37% reading",
        )
    if "** TEST SUCCEEDED **" in log:
        return Outcome.FAILED, "failed: UI test succeeded but simctl did not write a screenshot"
    return Outcome.FAILED, "failed: home-screen widget probe did not succeed"


def outcome_code(outcome: Outcome) -> int:
    if outcome is Outcome.VERIFIED:
        return EXIT_VERIFIED
    if outcome is Outcome.UNSUPPORTED:
        return EXIT_UNSUPPORTED
    if outcome is Outcome.FAILED:
        return EXIT_FAILED
    raise AssertionError(f"unknown outcome {outcome}")


def materialize_probe_project(dest: Path, host_bundle: str, ui_bundle: str) -> Path:
    if dest.exists():
        shutil.rmtree(dest)
    for relative in (
        "Host/HostApp.swift",
        "Host/Info.plist",
        "UITests/WidgetHomeScreenProbeUITests.swift",
        "UITests/Info.plist",
    ):
        target = dest / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(PROBE_SOURCES / relative, target)
    project = dest / "WidgetHomeScreenProbe.xcodeproj"
    project.mkdir()
    (project / "project.pbxproj").write_text(
        render_pbxproj(host_bundle, ui_bundle), encoding="utf-8"
    )
    scheme_dir = project / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True)
    (scheme_dir / "WidgetHomeScreenProbe.xcscheme").write_text(render_scheme(), encoding="utf-8")
    return project


def render_pbxproj(host_bundle: str, ui_bundle: str) -> str:
    return f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{
		A10000000000000000000013 /* HostApp.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000006; }};
		A10000000000000000000014 /* WidgetHomeScreenProbeUITests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000008; }};
		A10000000000000000000012 /* XCTest.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000011; }};
		A1000000000000000000001E /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = A10000000000000000000001;
			proxyType = 1;
			remoteGlobalIDString = {HOST_TARGET};
			remoteInfo = WidgetHomeScreenProbe;
		}};
		A10000000000000000000006 /* HostApp.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HostApp.swift; sourceTree = "<group>"; }};
		A10000000000000000000007 /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		A10000000000000000000008 /* WidgetHomeScreenProbeUITests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WidgetHomeScreenProbeUITests.swift; sourceTree = "<group>"; }};
		A10000000000000000000009 /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		A10000000000000000000004 /* WidgetHomeScreenProbe.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = WidgetHomeScreenProbe.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		A10000000000000000000005 /* WidgetHomeScreenProbeUITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = WidgetHomeScreenProbeUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};
		A10000000000000000000011 /* XCTest.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = XCTest.framework; path = System/Library/Frameworks/XCTest.framework; sourceTree = SDKROOT; }};
		A10000000000000000000010 /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A10000000000000000000012 /* XCTest.framework in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		A1000000000000000000000A /* Host */ = {{
			isa = PBXGroup;
			children = (
				A10000000000000000000006 /* HostApp.swift */,
				A10000000000000000000007 /* Info.plist */,
			);
			path = Host;
			sourceTree = "<group>";
		}};
		A1000000000000000000000B /* UITests */ = {{
			isa = PBXGroup;
			children = (
				A10000000000000000000008 /* WidgetHomeScreenProbeUITests.swift */,
				A10000000000000000000009 /* Info.plist */,
			);
			path = UITests;
			sourceTree = "<group>";
		}};
		A1000000000000000000000C /* */ = {{
			isa = PBXGroup;
			children = (
				A1000000000000000000000A /* Host */,
				A1000000000000000000000B /* UITests */,
				A1000000000000000000000D /* Products */,
			);
			sourceTree = "<group>";
		}};
		A1000000000000000000000D /* Products */ = {{
			isa = PBXGroup;
			children = (
				A10000000000000000000004 /* WidgetHomeScreenProbe.app */,
				A10000000000000000000005 /* WidgetHomeScreenProbeUITests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
		{HOST_TARGET} /* WidgetHomeScreenProbe */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = A10000000000000000000016;
			buildPhases = (
				A1000000000000000000000E /* Sources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = WidgetHomeScreenProbe;
			productName = WidgetHomeScreenProbe;
			productReference = A10000000000000000000004;
			productType = "com.apple.product-type.application";
		}};
		{UI_TARGET} /* WidgetHomeScreenProbeUITests */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = A10000000000000000000017;
			buildPhases = (
				A1000000000000000000000F /* Sources */,
				A10000000000000000000010 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
				A1000000000000000000001F /* PBXTargetDependency */,
			);
			name = WidgetHomeScreenProbeUITests;
			productName = WidgetHomeScreenProbeUITests;
			productReference = A10000000000000000000005;
			productType = "com.apple.product-type.bundle.ui-testing";
		}};
		A10000000000000000000001 /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{UI_TARGET} = {{
						TestTargetID = {HOST_TARGET};
					}};
				}};
			}};
			buildConfigurationList = A10000000000000000000015;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = A1000000000000000000000C;
			productRefGroup = A1000000000000000000000D;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{HOST_TARGET} /* WidgetHomeScreenProbe */,
				{UI_TARGET} /* WidgetHomeScreenProbeUITests */,
			);
		}};
		A1000000000000000000000E /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A10000000000000000000013 /* HostApp.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		A1000000000000000000000F /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A10000000000000000000014 /* WidgetHomeScreenProbeUITests.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		A1000000000000000000001F /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {HOST_TARGET};
			targetProxy = A1000000000000000000001E;
		}};
		A10000000000000000000018 /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				CODE_SIGN_IDENTITY = "";
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 1;
			}};
			name = Debug;
		}};
		A10000000000000000000019 /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				CODE_SIGN_IDENTITY = "";
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 1;
			}};
			name = Release;
		}};
		A1000000000000000000001A /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				CODE_SIGN_IDENTITY = "";
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_TESTABILITY = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Host/Info.plist;
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {host_bundle};
				PRODUCT_NAME = WidgetHomeScreenProbe;
				SWIFT_EMIT_LOC_STRINGS = YES;
			}};
			name = Debug;
		}};
		A1000000000000000000001B /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				CODE_SIGN_IDENTITY = "";
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Host/Info.plist;
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {host_bundle};
				PRODUCT_NAME = WidgetHomeScreenProbe;
				SWIFT_EMIT_LOC_STRINGS = YES;
			}};
			name = Release;
		}};
		A1000000000000000000001C /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				CODE_SIGN_IDENTITY = "";
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = UITests/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {ui_bundle};
				PRODUCT_NAME = WidgetHomeScreenProbeUITests;
				TEST_TARGET_NAME = WidgetHomeScreenProbe;
			}};
			name = Debug;
		}};
		A1000000000000000000001D /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				CODE_SIGN_IDENTITY = "";
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = UITests/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {ui_bundle};
				PRODUCT_NAME = WidgetHomeScreenProbeUITests;
				TEST_TARGET_NAME = WidgetHomeScreenProbe;
			}};
			name = Release;
		}};
		A10000000000000000000015 /* Build configuration list for PBXProject */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				A10000000000000000000018 /* Debug */,
				A10000000000000000000019 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		}};
		A10000000000000000000016 /* Build configuration list for PBXNativeTarget "WidgetHomeScreenProbe" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				A1000000000000000000001A /* Debug */,
				A1000000000000000000001B /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		}};
		A10000000000000000000017 /* Build configuration list for PBXNativeTarget "WidgetHomeScreenProbeUITests" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				A1000000000000000000001C /* Debug */,
				A1000000000000000000001D /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		}};
	}};
	rootObject = A10000000000000000000001;
}}
"""


def render_scheme() -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{HOST_TARGET}"
               BuildableName = "WidgetHomeScreenProbe.app"
               BlueprintName = "WidgetHomeScreenProbe"
               ReferencedContainer = "container:WidgetHomeScreenProbe.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{UI_TARGET}"
               BuildableName = "WidgetHomeScreenProbeUITests.xctest"
               BlueprintName = "WidgetHomeScreenProbeUITests"
               ReferencedContainer = "container:WidgetHomeScreenProbe.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{UI_TARGET}"
               BuildableName = "WidgetHomeScreenProbeUITests.xctest"
               BlueprintName = "WidgetHomeScreenProbeUITests"
               ReferencedContainer = "container:WidgetHomeScreenProbe.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{HOST_TARGET}"
            BuildableName = "WidgetHomeScreenProbe.app"
            BlueprintName = "WidgetHomeScreenProbe"
            ReferencedContainer = "container:WidgetHomeScreenProbe.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{HOST_TARGET}"
            BuildableName = "WidgetHomeScreenProbe.app"
            BlueprintName = "WidgetHomeScreenProbe"
            ReferencedContainer = "container:WidgetHomeScreenProbe.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


class ProcessRunner:
    def note(self, argv: list[str]) -> None:
        print("+ " + " ".join(shlex.quote(arg) for arg in argv), flush=True)

    def run(
        self,
        argv: list[str],
        *,
        cwd: Path | None = None,
        check: bool = True,
        timeout: int = 180,
    ) -> tuple[int, str]:
        self.note(argv)
        if argv_disturbs_gui(argv):
            raise ProbeFailure("failed: refusing a command that opens Simulator.app", EXIT_FAILED)
        try:
            completed = subprocess.run(
                argv,
                cwd=cwd,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise ProbeFailure(
                f"failed: {' '.join(argv[:3])} timed out after {timeout}s",
                EXIT_FAILED,
            ) from exc
        output = completed.stdout or ""
        if completed.returncode != 0 and check:
            tail = output[-2000:]
            raise ProbeFailure(
                f"failed: {' '.join(argv[:4])} exited {completed.returncode}\n{tail}",
                EXIT_FAILED,
            )
        return completed.returncode, output

    def stream(self, argv: list[str], *, cwd: Path, timeout: int, log_path: Path) -> tuple[int, str]:
        self.note(argv)
        if argv_disturbs_gui(argv):
            raise ProbeFailure("failed: refusing a command that opens Simulator.app", EXIT_FAILED)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        chunks: list[str] = []
        killed = False

        def kill() -> None:
            nonlocal killed
            if proc.poll() is None:
                killed = True
                try:
                    proc.kill()
                except ProcessLookupError:
                    killed = False

        with log_path.open("w", encoding="utf-8") as handle:
            proc = subprocess.Popen(
                argv,
                cwd=cwd,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            timer = threading.Timer(timeout, kill)
            timer.start()
            assert proc.stdout is not None
            try:
                for line in proc.stdout:
                    sys.stdout.write(line)
                    handle.write(line)
                    chunks.append(line)
            finally:
                timer.cancel()
                code = proc.wait()
        if killed:
            raise ProbeFailure(
                f"failed: {' '.join(argv[:3])} timed out after {timeout}s",
                EXIT_FAILED,
            )
        return code, "".join(chunks)


def _load_json(output: str, what: str) -> dict:
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as exc:
        raise ProbeFailure(f"failed: {what} did not return JSON", EXIT_FAILED) from exc
    if not isinstance(payload, dict):
        raise ProbeFailure(f"failed: {what} JSON was not an object", EXIT_FAILED)
    return payload


def _boot(runner: ProcessRunner, udid: str) -> None:
    runner.run(["xcrun", "simctl", "boot", udid], check=False)
    runner.run(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=240)


LAUNCH_ATTEMPTS = 6
LAUNCH_RETRY_SECONDS = 15
# SpringBoard can refuse a launch for a while after bootstatus returns on a
# slow hosted runner.  Only that refusal is retried;  any other launch error
# fails at once.
SPRINGBOARD_NOT_READY = ("SBMainWorkspace", "FBSOpenApplicationServiceErrorDomain")


def _launch(runner: ProcessRunner, udid: str, app_bundle: str) -> tuple[int, str]:
    code, output = 1, ""
    for attempt in range(1, LAUNCH_ATTEMPTS + 1):
        code, output = runner.run(["xcrun", "simctl", "launch", udid, app_bundle], check=False)
        if code == 0 or not any(marker in output for marker in SPRINGBOARD_NOT_READY):
            return code, output
        if attempt < LAUNCH_ATTEMPTS:
            print(
                f"widget-homescreen: SpringBoard refused launch (attempt {attempt}/{LAUNCH_ATTEMPTS}); retrying",
                flush=True,
            )
            time.sleep(LAUNCH_RETRY_SECONDS)
    return code, output


def _wait_for_container(
    runner: ProcessRunner,
    argv: list[str],
    parse,
    refusal: str,
) -> str:
    last = ""
    for _ in range(20):
        code, output = runner.run(argv, check=False)
        last = output
        if code == 0:
            found = parse(output)
            if found:
                return found
        time.sleep(0.5)
    raise ProbeFailure(refusal + (f"\n{last[-500:]}" if last else ""), EXIT_UNSUPPORTED)


def _best_effort(runner: ProcessRunner, argv: list[str]) -> tuple[int, str]:
    """Run a cleanup command.  A timeout or non-zero exit must not replace the probe result."""
    try:
        return runner.run(argv, check=False)
    except ProbeFailure as exc:
        print(f"widget-homescreen: cleanup: {exc}", flush=True)
        return 1, ""


def _cleanup(runner: ProcessRunner, udid: str | None, expected_name: str | None) -> None:
    if not udid or not expected_name:
        return
    _best_effort(runner, ["xcrun", "simctl", "shutdown", udid])
    _code, listing = _best_effort(runner, ["xcrun", "simctl", "list", "devices", "-j"])
    devices: dict | None
    try:
        parsed = json.loads(listing) if listing else None
    except json.JSONDecodeError:
        parsed = None
    devices = parsed if isinstance(parsed, dict) else None
    if isinstance(devices, dict) and not deletion_allowed(devices, udid, expected_name):
        print(
            "widget-homescreen: failed: refusing to delete a simulator that is not the disposable probe",
            flush=True,
        )
        return
    _best_effort(runner, ["xcrun", "simctl", "delete", udid])


def execute(host: Host, work: Path) -> int:
    refusal = classify_host(host)
    if refusal:
        print(f"widget-homescreen: {refusal}", flush=True)
        return EXIT_UNSUPPORTED

    work.mkdir(parents=True, exist_ok=True)
    print(f"widget-homescreen: artifacts {work}", flush=True)
    runner = ProcessRunner()
    _, runtime_text = runner.run(["xcrun", "simctl", "list", "runtimes", "available", "-j"])
    _, type_text = runner.run(["xcrun", "simctl", "list", "devicetypes", "-j"])
    _, device_text = runner.run(["xcrun", "simctl", "list", "devices", "-j"])
    runtimes = _load_json(runtime_text, "simctl list runtimes").get("runtimes", [])
    device_types = _load_json(type_text, "simctl list devicetypes").get("devicetypes", [])
    devices = _load_json(device_text, "simctl list devices")
    if not isinstance(runtimes, list) or not isinstance(device_types, list):
        raise ProbeFailure("failed: simctl list JSON was missing runtimes or device types", EXIT_FAILED)
    prepared = prepare_environment(host, runtimes, device_types, booted_udids(devices))
    if prepared.refusal:
        print(f"widget-homescreen: {prepared.refusal}", flush=True)
        return EXIT_UNSUPPORTED

    app_bundle, widget_bundle = companion_bundle_ids(COMPANION_YML.read_text(encoding="utf-8"))
    host_bundle, ui_bundle = probe_bundle_ids(app_bundle)
    app_group = read_app_group(APP_ENTITLEMENTS)
    widget_group = read_app_group(WIDGET_ENTITLEMENTS)
    if app_group != widget_group:
        raise ProbeFailure("failed: the iOS app and widget declare different app groups", EXIT_FAILED)

    name = f"{DEVICE_PREFIX}{os.getpid()}-{int(time.time())}"
    udid: str | None = None
    try:
        _, created = runner.run(
            ["xcrun", "simctl", "create", name, prepared.device_type_id or "", prepared.runtime_id or ""]
        )
        udid = parse_created_udid(created)
        derived = work / "companion-derived"
        build_log = work / "xcodebuild-companion.log"
        code, _ = runner.stream(
            companion_build_argv(udid, derived),
            cwd=ROOT,
            timeout=1800,
            log_path=build_log,
        )
        if code != 0:
            raise ProbeFailure("failed: companion simulator build failed", EXIT_FAILED)
        app = companion_app(derived)
        appex = app / "PlugIns" / "CodeCapsWidgets.appex"
        if not app.is_dir() or not appex.is_dir():
            raise ProbeFailure(f"failed: companion build did not produce {app}", EXIT_FAILED)
        runner.run(codesign_argv(appex, WIDGET_ENTITLEMENTS))
        runner.run(codesign_argv(app, APP_ENTITLEMENTS))
        _boot(runner, udid)
        runner.run(["xcrun", "simctl", "install", udid, str(app)])
        runner.run(["xcrun", "simctl", "shutdown", udid], check=False)
        _boot(runner, udid)
        launch_code, launch_out = _launch(runner, udid, app_bundle)
        if launch_code != 0:
            raise ProbeFailure(
                f"failed: companion did not launch\n{launch_out[-1000:]}",
                EXIT_FAILED,
            )
        group = _wait_for_container(
            runner,
            ["xcrun", "simctl", "get_app_container", udid, app_bundle, "groups"],
            lambda text: parse_group_container(text, app_group),
            "unsupported-path: app group container is not available after install; refusing to claim a home-screen render",
        )
        app_data = _wait_for_container(
            runner,
            ["xcrun", "simctl", "get_app_container", udid, app_bundle, "data"],
            parse_data_container,
            "unsupported-path: companion data container is not available after install; refusing to claim a home-screen render",
        )
        runner.run(["xcrun", "simctl", "terminate", udid, app_bundle], check=False)
        widget_code, widget_out = runner.run(
            ["xcrun", "simctl", "get_app_container", udid, widget_bundle, "data"],
            check=False,
        )
        widget_data = parse_data_container(widget_out) if widget_code == 0 else None
        payload = build_seed(datetime.now(timezone.utc))
        for path in seed_paths(group, app_data, widget_data):
            write_seed(path, payload)
        project = materialize_probe_project(work / "probe", host_bundle, ui_bundle)
        test_log = work / "xcodebuild-test.log"
        _, test_output = runner.stream(
            probe_test_argv(
                project,
                udid,
                work / "probe-derived",
                work / "WidgetHomeScreen.xcresult",
            ),
            cwd=ROOT,
            timeout=1800,
            log_path=test_log,
        )
        png = work / "home-screen.png"
        shot_code, _ = runner.run(screenshot_argv(udid, png), check=False)
        size = png.stat().st_size if shot_code == 0 and png.is_file() else 0
        outcome, message = interpret_log(test_output, size)
        print(f"widget-homescreen: {message}", flush=True)
        return outcome_code(outcome)
    finally:
        _cleanup(runner, udid, name)


def main(argv: list[str] | None = None, host: Host | None = None) -> int:
    del argv
    host = host or inspect_host()
    raw_work = os.environ.get("CODECAPS_WIDGET_HOMESCREEN_DIR", "").strip()
    if raw_work:
        work = Path(raw_work).expanduser()
    else:
        work = Path(os.environ.get("TMPDIR", "/tmp")) / f"codecaps-widget-homescreen-{os.getpid()}"
    try:
        return execute(host, work)
    except ProbeFailure as exc:
        print(f"widget-homescreen: {exc}", flush=True)
        return exc.code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

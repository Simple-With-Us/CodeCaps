import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../../", import.meta.url));
const macBuildScript = readFileSync(`${repoRoot}/script/build_and_run.sh`, "utf8");
const macSettingsSource = readFileSync(`${repoRoot}/Sources/CodeCaps/ConsoleViews.swift`, "utf8");
const companionSource = readFileSync(
  `${repoRoot}/ios/CodeCapsCompanion/App/Views/CompanionContentView.swift`,
  "utf8"
);

test("macOS marketing and build metadata use the same full-history commit count", () => {
  assert.match(macBuildScript, /short_version\(\)[\s\S]*?count="\$\(bundle_version\)"/);
  assert.match(macBuildScript, /bundle_version\(\)[\s\S]*?git -C "\$ROOT_DIR" rev-list --count HEAD/);
  assert.match(macBuildScript, /<key>CFBundleShortVersionString<\/key>[\s\S]*?<string>\$\(short_version\)<\/string>/);
  assert.match(macBuildScript, /<key>CFBundleVersion<\/key>[\s\S]*?<string>\$\(bundle_version\)<\/string>/);
});

test("iOS companion About shows the marketing version once", () => {
  const aboutSection = /Section\("About"\) \{([\s\S]*?)\n        \}/.exec(companionSource)?.[1];
  assert.ok(aboutSection, "the About section should remain present");
  assert.match(aboutSection, /CFBundleShortVersionString/);
  assert.match(aboutSection, /Text\(short\)/);
  assert.doesNotMatch(aboutSection, /CFBundleVersion/);
  assert.doesNotMatch(aboutSection, /\(\s*build\s*\)/i);
});

test("macOS app-owned version label omits the duplicate bundle build number", () => {
  const versionDisplay = /enum CodeCapsVersion \{([\s\S]*?)\n\}/.exec(macSettingsSource)?.[1];
  assert.ok(versionDisplay, "the macOS version display helper should remain present");
  assert.match(versionDisplay, /CFBundleShortVersionString/);
  assert.match(versionDisplay, /displayVersion\(shortVersion: short\)/);
  assert.doesNotMatch(versionDisplay, /CFBundleVersion/);
  assert.doesNotMatch(versionDisplay, /\(\\\(build\)\)/);
});

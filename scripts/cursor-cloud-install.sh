#!/usr/bin/env bash
# Cursor cloud agent install for CodeCaps.
#
# CodeCaps is primarily a Swift / macOS / iOS app.  The Linux cloud VM cannot
# build any Apple target, so the install step here is intentionally a no-op
# other than a one-line note: Xcode, swift, xcodebuild, swift test, and the
# iOS / macOS provisioning steps all live on the Mac release pipeline (see
# script/build_and_run.sh and .github/workflows/mac-release.yml).  Adding
# them here would just waste agent time.
#
# There is no Node docs site in this repo, so we do not install Node / pnpm
# / npm either.  This script is therefore safe to re-run on every agent
# start: it changes no state and writes nothing.
#
# BLOCKED on Linux (composer-latest):
#   - xcodebuild, swift build, swift test
#   - codesign, notarytool, productbuild, altool
#   - any ios/CodeCapsCompanion build
# Use the macOS-hosted Mac fleet (see docs/AUTO-UPDATE.md) for those.
set -euo pipefail

echo "CodeCaps: Swift/macOS/iOS project.  Apple toolchain is Mac-only; this Linux cloud VM installs nothing.  See AGENTS.md and docs/AUTO-UPDATE.md for the Mac build pipeline."

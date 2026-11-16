#!/usr/bin/env bash
# Headless iOS Home Screen WidgetKit check (CC-219).
# Exit 78 is an unsupported-path refusal, not a pass.  The driver does not
# open Simulator.app and does not touch a simulator that is already booted.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/widget_homescreen_probe.py "$@"

#!/bin/bash
# Local automated gates only; Studio and published-service tests remain manual.
#
# Every gate that can fail the build belongs here. check-budget was missing, and
# a shadow regression that pushed Speedball 24 casters over budget passed this
# script clean -- the render, surface and character gates are as much a release
# condition as the specs are.
set -eu
cd "$(dirname "$0")"
lune="$HOME/.local/bin/lune"

# Configuration and source.
"$lune" run tools/ship-check
"$lune" run tools/check-source

# Behaviour.
"$lune" run tools/run-tests
"$lune" run tools/run-live-checks
"$lune" run tools/run-profile-checks
"$lune" run tools/check-persistence

# What the player actually sees.
"$lune" run tools/check-budget
"$lune" run tools/check-zfight
"$lune" run tools/check-client-ui
"$lune" run tools/check-inflatables
"$lune" run tools/check-characters
"$lune" run tools/check-gait
"$lune" run tools/check-demo-world

mkdir -p build
"$HOME/.local/bin/rojo" build default.project.json -o build/paintball-release.rbxlx
printf '\nAutomated checks passed. Complete the Studio/private-server gates in docs/PUBLISH_READINESS.md before publishing.\n'
printf 'Diagnostics that do not gate: tools/probe-hitbox, tools/probe-ground, tools/probe-shadows.\n'

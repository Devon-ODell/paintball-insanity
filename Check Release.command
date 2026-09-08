#!/bin/bash
# Local automated gates only; Studio and published-service tests remain manual.
set -eu
cd "$(dirname "$0")"
"$HOME/.local/bin/lune" run tools/ship-check
"$HOME/.local/bin/lune" run tools/check-source
"$HOME/.local/bin/lune" run tools/run-tests
"$HOME/.local/bin/lune" run tools/run-live-checks
"$HOME/.local/bin/lune" run tools/run-profile-checks
mkdir -p build
"$HOME/.local/bin/rojo" build default.project.json -o build/paintball-release.rbxlx
printf '\nAutomated checks passed. Complete the Studio/private-server gates in docs/PUBLISH_READINESS.md before publishing.\n'

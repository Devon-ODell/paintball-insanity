#!/bin/bash
# macOS convenience wrapper. The gate list lives in tools/check-all.luau so that
# Windows and Linux run exactly the same set -- this file must never grow its own
# copy of it, which is how check-budget went missing once and a shadow regression
# shipped through the gap.
set -eu
cd "$(dirname "$0")"
lune="${LUNE:-$HOME/.local/bin/lune}"
command -v lune >/dev/null 2>&1 && lune="$(command -v lune)"

"$lune" run tools/check-all

mkdir -p build
rojo="${ROJO:-$HOME/.local/bin/rojo}"
command -v rojo >/dev/null 2>&1 && rojo="$(command -v rojo)"
"$rojo" build default.project.json -o build/paintball-release.rbxlx

printf '\nPlace built to build/paintball-release.rbxlx\n'
printf 'Complete the Studio/private-server gates in docs/PUBLISH_READINESS.md before publishing.\n'
printf 'Diagnostics that do not gate: tools/probe-hitbox, tools/probe-ground, tools/probe-shadows.\n'

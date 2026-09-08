#!/bin/bash
# Build the current source and open the release candidate in Roblox Studio.
set -eu
cd "$(dirname "$0")"
"$HOME/.local/bin/lune" run tools/ship-check
mkdir -p build
"$HOME/.local/bin/rojo" build default.project.json -o build/paintball-release.rbxlx
open -a RobloxStudio build/paintball-release.rbxlx

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
rojo_bin="${HOME}/.local/bin/rojo"
if command -v rojo >/dev/null 2>&1; then
  rojo_bin="$(command -v rojo)"
fi
if [[ ! -x "$rojo_bin" ]]; then
  echo "Rojo is missing. Install the version specified in rokit.toml."
  exit 1
fi
mkdir -p build
"$rojo_bin" build demo.project.json -o build/LiveRoundDemo.rbxlx
if [[ "${1:-}" == "--build-only" ]]; then
  exit 0
fi
open -a /Applications/RobloxStudio.app "$PWD/build/LiveRoundDemo.rbxlx"
echo "In Studio, choose Test and press Play (F5). Click the viewport to control your player."

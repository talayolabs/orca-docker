#!/usr/bin/env bash
# Orca environment-recipe shim: `./scripts/orca-vm/orca-docker.sh <create|suspend|resume|destroy>`.
# Copy this file and orca.yaml into a repository to give its worktrees a "Run on: orca-docker"
# target. Everything happens in `orca-docker env`; this only finds the wrapper.
set -euo pipefail
mode="${1:-${ORCA_VM_MODE:-}}"
[ -n "$mode" ] || { echo "usage: $0 <create|suspend|resume|destroy>" >&2; exit 64; }
bin="${ORCA_DOCKER_BIN:-}"
if [ -z "$bin" ]; then
  if command -v orca-docker >/dev/null 2>&1; then
    bin=orca-docker
  elif [ -x "$HOME/.orca-docker/bin/orca-docker" ]; then
    bin="$HOME/.orca-docker/bin/orca-docker"
  else
    echo "orca-docker not found on PATH or at ~/.orca-docker/bin; install: git clone https://github.com/talayolabs/orca-docker ~/.orca-docker" >&2
    exit 69
  fi
fi
exec "$bin" env "$mode"

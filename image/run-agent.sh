#!/bin/bash
# Agent launcher, run by the wrapper via `docker exec -u <host uid> ... run-agent.sh <agent> [args]`
# inside the tab's (already running) container. One invocation == one Orca agent launch.
#
# Environment (set by the wrapper; all optional):
#   ORCA_DOCKER_REPO             path of the cloned repository (== host worktree path)
#   ORCA_DOCKER_AUTO_INSTALL=0   skip dependency installation
#   ORCA_DOCKER_MCP=0            do not attach the computer-use MCP server to claude
#   ORCA_DOCKER_INIT             extra shell snippet to run before the agent starts (repo-specific setup)
#   ORCA_DOCKER_PUBLISH          off | local | push | pr — `off` disables the auto-publish on exit
#   ORCA_DOCKER_AUTOCOMMIT=1     commit uncommitted changes as "wip" before the auto-publish
set -uo pipefail

log() { printf '[orca-docker] %s\n' "$*" >&2; }

run_dir=/run/orca-docker
# shellcheck disable=SC1091
[ -f "$run_dir/env" ] && . "$run_dir/env"
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin${PATH:+:$PATH}"

repo="${ORCA_DOCKER_REPO:-$PWD}"
if [ -d "$repo" ]; then cd "$repo" || true; else cd "$HOME" || true; fi

install_dependencies() {
  local marker="$PWD/node_modules/.orca-docker-lockhash"
  local lock="" cmd=""
  if [ -f pnpm-lock.yaml ]; then lock=pnpm-lock.yaml; cmd="pnpm install --frozen-lockfile"
  elif [ -f yarn.lock ]; then lock=yarn.lock; cmd="yarn install --frozen-lockfile"
  elif [ -f package-lock.json ]; then lock=package-lock.json; cmd="npm ci"
  elif [ -f bun.lockb ] || [ -f bun.lock ]; then
    if command -v bun >/dev/null 2>&1; then lock="$(ls bun.lock* | head -1)"; cmd="bun install --frozen-lockfile"; fi
  fi
  if [ -n "$cmd" ]; then
    local hash
    hash="$(sha256sum "$lock" | cut -c1-16)"
    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$hash" ]; then
      log "node_modules up to date with $lock"
    else
      log "installing dependencies: $cmd"
      if $cmd >"$run_dir/install.log" 2>&1; then
        mkdir -p node_modules && printf '%s' "$hash" > "$marker"
      else
        log "dependency install failed (see $run_dir/install.log); continuing"
      fi
    fi
  fi
  if [ -f requirements.txt ] && [ ! -d .venv ]; then
    log "creating .venv from requirements.txt"
    (python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt) >"$run_dir/pip.log" 2>&1 || \
      log "pip install failed (see $run_dir/pip.log); continuing"
  fi
}

if [ "${ORCA_DOCKER_AUTO_INSTALL:-1}" != "0" ] && [ -d "$repo" ]; then
  install_dependencies
fi

if [ -n "${ORCA_DOCKER_INIT:-}" ]; then
  log "running ORCA_DOCKER_INIT"
  bash -c "$ORCA_DOCKER_INIT" || log "ORCA_DOCKER_INIT exited non-zero; continuing"
fi

if [ $# -eq 0 ]; then
  set -- bash
fi

# Agent-specific launch adjustments. Claude is the first supported agent.
case "$(basename -- "$1")" in
  claude)
    if [ "${ORCA_DOCKER_MCP:-1}" != "0" ] && [ -f /opt/orca-docker/mcp.json ]; then
      set -- "$1" --mcp-config /opt/orca-docker/mcp.json "${@:2}"
    fi
    ;;
esac

"$@"
code=$?

# Make the session's work visible outside the container before the wrapper stops it. Not in a
# workspace environment: there Orca's own git UI runs inside the container, nothing to hand over.
[ -f "$run_dir/env-mode" ] && ORCA_DOCKER_PUBLISH=off
if [ "${ORCA_DOCKER_PUBLISH:-local}" != off ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  if [ "${ORCA_DOCKER_AUTOCOMMIT:-0}" = 1 ]; then
    orca-docker publish --auto --commit "wip: uncommitted changes from orca-docker session" || true
  else
    orca-docker publish --auto || true
  fi
fi

exit "$code"

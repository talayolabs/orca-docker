#!/bin/bash
# User-phase session runner: bring up the desktop, install repo dependencies, exec the agent.
#
# Environment (all optional):
#   DISPLAY                      Xvfb display (unique per container under --network host)
#   ORCA_DOCKER_DISPLAY_SIZE     WxHxDepth, default 1440x900x24
#   ORCA_DOCKER_VNC_PORT         x11vnc port (default 5900)
#   ORCA_DOCKER_NOVNC_PORT       noVNC/websockify port (default 6080)
#   ORCA_DOCKER_BIND             bind address for VNC/noVNC (127.0.0.1 with host networking, 0.0.0.0 for bridge)
#   ORCA_DOCKER_DESKTOP=0        skip Xvfb/XFCE/VNC entirely
#   ORCA_DOCKER_AUTO_INSTALL=0   skip dependency installation in $PWD
#   ORCA_DOCKER_MCP=0            do not attach the computer-use MCP server to claude
#   ORCA_DOCKER_INIT             extra shell snippet to run before the agent starts (e.g. repo-specific setup)
set -uo pipefail

log() { printf '[orca-docker] %s\n' "$*" >&2; }

state_dir="${XDG_RUNTIME_DIR:-/tmp}/orca-docker"
mkdir -p "$state_dir"

start_desktop() {
  local size="${ORCA_DOCKER_DISPLAY_SIZE:-1440x900x24}"
  local vnc_port="${ORCA_DOCKER_VNC_PORT:-5900}"
  local novnc_port="${ORCA_DOCKER_NOVNC_PORT:-6080}"
  local bind="${ORCA_DOCKER_BIND:-127.0.0.1}"
  local display="${DISPLAY:-:99}"
  local dnum="${display#:}"

  Xvfb "$display" -screen 0 "$size" -nolisten tcp -ac +extension RANDR \
    >"$state_dir/xvfb.log" 2>&1 &
  for _ in $(seq 1 50); do
    [ -S "/tmp/.X11-unix/X${dnum}" ] && xdpyinfo -display "$display" >/dev/null 2>&1 && break
    sleep 0.1
  done
  if ! xdpyinfo -display "$display" >/dev/null 2>&1; then
    log "Xvfb failed to start on $display (see $state_dir/xvfb.log); continuing without desktop"
    return 1
  fi

  export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    eval "$(dbus-launch --sh-syntax)" >/dev/null 2>&1 || true
    export DBUS_SESSION_BUS_ADDRESS
  fi
  startxfce4 >"$state_dir/xfce.log" 2>&1 &

  x11vnc -display "$display" -rfbport "$vnc_port" -listen "$bind" -forever -shared -nopw \
    -noxdamage -xkb -quiet -bg -o "$state_dir/x11vnc.log" >/dev/null 2>&1 || \
    log "x11vnc failed to start (see $state_dir/x11vnc.log)"

  websockify --web /usr/share/novnc "${bind}:${novnc_port}" "127.0.0.1:${vnc_port}" \
    >"$state_dir/novnc.log" 2>&1 &

  # Wait for the window manager so the first screenshot/click lands on a real desktop.
  for _ in $(seq 1 100); do
    wmctrl -m >/dev/null 2>&1 && break
    sleep 0.1
  done

  log "desktop ready on $display — noVNC: http://${bind}:${novnc_port}/vnc.html?autoconnect=1&resize=scale"
}

install_dependencies() {
  [ -d "$PWD" ] || return 0
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
      if $cmd >"$state_dir/install.log" 2>&1; then
        mkdir -p node_modules && printf '%s' "$hash" > "$marker"
      else
        log "dependency install failed (see $state_dir/install.log); continuing"
      fi
    fi
  fi
  if [ -f requirements.txt ] && [ ! -d .venv ]; then
    log "creating .venv from requirements.txt"
    (python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt) >"$state_dir/pip.log" 2>&1 || \
      log "pip install failed (see $state_dir/pip.log); continuing"
  fi
}

install_orca_cli_shim() {
  # The host Orca CLI is a plain CommonJS bundle launched with Electron-as-Node; plain Node runs it too.
  [ -n "${ORCA_DOCKER_CLI_ENTRY:-}" ] && [ -f "$ORCA_DOCKER_CLI_ENTRY" ] || return 0
  local dir="$state_dir/bin"
  mkdir -p "$dir"
  printf '#!/bin/sh\nexec node %q "$@"\n' "$ORCA_DOCKER_CLI_ENTRY" > "$dir/orca"
  chmod 755 "$dir/orca"
  cp "$dir/orca" "$dir/orca-ide"
  export PATH="$dir:$PATH" ORCA_CLI_COMMAND=orca
  log "orca CLI bridged from host ($ORCA_DOCKER_CLI_ENTRY)"
}

install_orca_cli_shim

if [ "${ORCA_DOCKER_DESKTOP:-1}" != "0" ]; then
  start_desktop || true
fi

if [ "${ORCA_DOCKER_AUTO_INSTALL:-1}" != "0" ]; then
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

exec "$@"

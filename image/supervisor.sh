#!/bin/bash
# Container main process (user phase): bring up the virtual desktop, publish the session
# environment for later `docker exec`s, then idle. The container is a "PC that stays on";
# the wrapper starts agents inside it with run-agent.sh and stops it when the agent exits.
#
# Environment (all optional):
#   DISPLAY                      Xvfb display (unique per container under --network host)
#   ORCA_DOCKER_DISPLAY_SIZE     WxHxDepth, default 1440x900x24
#   ORCA_DOCKER_VNC_PORT         x11vnc port (default 5900)
#   ORCA_DOCKER_NOVNC_PORT       noVNC/websockify port (default 6080)
#   ORCA_DOCKER_BIND             bind address for VNC/noVNC (127.0.0.1 with host networking, 0.0.0.0 for bridge)
#   ORCA_DOCKER_DESKTOP=0        skip Xvfb/XFCE/VNC entirely
set -uo pipefail

log() { printf '[orca-docker] %s\n' "$*" >&2; }

run_dir=/run/orca-docker
mkdir -p "$run_dir/outbox"
rm -f "$run_dir/ready" "$run_dir/env"

start_desktop() {
  local size="${ORCA_DOCKER_DISPLAY_SIZE:-1440x900x24}"
  local vnc_port="${ORCA_DOCKER_VNC_PORT:-5900}"
  local novnc_port="${ORCA_DOCKER_NOVNC_PORT:-6080}"
  local bind="${ORCA_DOCKER_BIND:-127.0.0.1}"
  local display="${DISPLAY:-:99}"
  local dnum="${display#:}"

  rm -f "/tmp/.X11-unix/X${dnum}" 2>/dev/null
  Xvfb "$display" -screen 0 "$size" -nolisten tcp -ac +extension RANDR \
    >"$run_dir/xvfb.log" 2>&1 &
  for _ in $(seq 1 50); do
    [ -S "/tmp/.X11-unix/X${dnum}" ] && xdpyinfo -display "$display" >/dev/null 2>&1 && break
    sleep 0.1
  done
  if ! xdpyinfo -display "$display" >/dev/null 2>&1; then
    log "Xvfb failed to start on $display (see $run_dir/xvfb.log); continuing without desktop"
    return 1
  fi

  export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    eval "$(dbus-launch --sh-syntax)" >/dev/null 2>&1 || true
    export DBUS_SESSION_BUS_ADDRESS
  fi
  # XFCE components are started directly instead of via startxfce4/xfce4-session: the session
  # manager's ICE listener lives in the abstract socket namespace, which host networking shares
  # across containers, so two sessions whose xfce4-session got the same PID collide.
  xfsettingsd --sm-client-disable >"$run_dir/xfce.log" 2>&1 &
  xfwm4 --sm-client-disable >>"$run_dir/xfce.log" 2>&1 &
  xfdesktop --sm-client-disable >>"$run_dir/xfce.log" 2>&1 &
  xfce4-panel --sm-client-disable >>"$run_dir/xfce.log" 2>&1 &

  x11vnc -display "$display" -rfbport "$vnc_port" -listen "$bind" -forever -shared -nopw \
    -noxdamage -xkb -quiet -bg -o "$run_dir/x11vnc.log" >/dev/null 2>&1 || \
    log "x11vnc failed to start (see $run_dir/x11vnc.log)"

  websockify --web /usr/share/novnc "${bind}:${novnc_port}" "127.0.0.1:${vnc_port}" \
    >"$run_dir/novnc.log" 2>&1 &

  # Wait for the window manager so the first screenshot/click lands on a real desktop.
  for _ in $(seq 1 100); do
    wmctrl -m >/dev/null 2>&1 && break
    sleep 0.1
  done

  log "desktop ready on $display — noVNC: http://${bind}:${novnc_port}/vnc.html?autoconnect=1&resize=scale"
}

if [ "${ORCA_DOCKER_DESKTOP:-1}" != "0" ]; then
  start_desktop || true
fi

# Session environment for run-agent.sh (docker exec does not inherit the main process env).
{
  for name in DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_SESSION_TYPE XDG_CURRENT_DESKTOP \
              ORCA_DOCKER_VNC_PORT ORCA_DOCKER_NOVNC_PORT ORCA_DOCKER_BIND; do
    [ -n "${!name:-}" ] && printf 'export %s=%q\n' "$name" "${!name}"
  done
} > "$run_dir/env"
: > "$run_dir/ready"

exec sleep infinity

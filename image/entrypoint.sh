#!/bin/bash
# Root-phase entrypoint: create the session user to match the host identity, then drop privileges.
#
# Inputs (set by the orca-docker wrapper; defaults let the image run standalone):
#   ORCA_DOCKER_UID / ORCA_DOCKER_GID   host uid/gid so bind mounts are writable
#   ORCA_DOCKER_USER                    login name
#   ORCA_DOCKER_HOME                    home directory (== host $HOME so ~/.claude etc. resolve identically)
set -euo pipefail

uid="${ORCA_DOCKER_UID:-1000}"
gid="${ORCA_DOCKER_GID:-1000}"
user="${ORCA_DOCKER_USER:-agent}"
home="${ORCA_DOCKER_HOME:-/home/${user}}"

if [ "$(id -u)" != "0" ]; then
  # Already unprivileged (e.g. `docker run --user`): nothing to set up.
  exec /opt/orca-docker/session.sh "$@"
fi

if ! getent group "$gid" >/dev/null; then
  groupadd -g "$gid" "$user"
fi

if getent passwd "$uid" >/dev/null; then
  existing="$(getent passwd "$uid" | cut -d: -f1)"
  if [ "$existing" != "$user" ]; then
    usermod -l "$user" -d "$home" "$existing"
  else
    usermod -d "$home" "$user"
  fi
else
  useradd -M -u "$uid" -g "$gid" -d "$home" -s /bin/bash "$user"
fi
usermod -aG sudo "$user" 2>/dev/null || true

mkdir -p "$home"
chown "$uid:$gid" "$home" 2>/dev/null || true
chmod 755 "$home"
# Docker creates missing parents of bind-mount targets (e.g. ~/.config for ~/.config/orca/...)
# as root in the container layer; hand those to the session user. Mounted dirs keep host ownership.
find "$home" -xdev -mindepth 1 -maxdepth 3 -type d ! -user "$uid" -print0 2>/dev/null |
  while IFS= read -r -d '' dir; do
    mountpoint -q "$dir" || chown "$uid:$gid" "$dir" 2>/dev/null || true
  done

echo "$user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-orca-docker
chmod 440 /etc/sudoers.d/90-orca-docker

mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

export HOME="$home" USER="$user" LOGNAME="$user"
exec setpriv --reuid="$uid" --regid="$gid" --init-groups /opt/orca-docker/session.sh "$@"

#!/bin/bash
# Root-phase entrypoint: create the session user to match the host identity, then drop
# privileges into the supervisor (desktop + idle). Agents are started later by the wrapper
# with `docker exec ... /opt/orca-docker/run-agent.sh`.
#
# Inputs (set by the orca-docker wrapper; defaults let the image run standalone):
#   ORCA_DOCKER_UID / ORCA_DOCKER_GID   host uid/gid (published commits and files keep host identity)
#   ORCA_DOCKER_USER                    login name
#   ORCA_DOCKER_HOME                    home directory (== host $HOME so ~/.claude etc. resolve identically)
#   ORCA_DOCKER_SSH_PUBKEY              when set, run sshd (key-only login for the session user) so Orca
#                                       can use the container as an execution host; host keys are generated
#                                       on first start and live in the (retained) container
#   ORCA_DOCKER_SSH_PORT / ORCA_DOCKER_SSH_BIND   sshd listen port (22) and address (0.0.0.0)
set -euo pipefail

uid="${ORCA_DOCKER_UID:-1000}"
gid="${ORCA_DOCKER_GID:-1000}"
user="${ORCA_DOCKER_USER:-agent}"
home="${ORCA_DOCKER_HOME:-/home/${user}}"

if [ "$(id -u)" != "0" ]; then
  # Already unprivileged (e.g. `docker run --user`): nothing to set up.
  exec /opt/orca-docker/supervisor.sh "$@"
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
# Parent directories created by `docker cp` (e.g. ~/.config for ~/.config/orca/...) are
# root-owned; hand the shallow ones to the session user.
find "$home" -xdev -mindepth 1 -maxdepth 3 -type d ! -user "$uid" -print0 2>/dev/null |
  while IFS= read -r -d '' dir; do
    chown "$uid:$gid" "$dir" 2>/dev/null || true
  done

echo "$user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-orca-docker
chmod 440 /etc/sudoers.d/90-orca-docker

mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
mkdir -p /run/orca-docker && chown "$uid:$gid" /run/orca-docker

start_sshd() {
  local port="${ORCA_DOCKER_SSH_PORT:-22}" bind="${ORCA_DOCKER_SSH_BIND:-0.0.0.0}"
  [ -x /usr/sbin/sshd ] || { echo "[orca-docker] sshd not installed in this image; skipping" >&2; return; }
  # Unique host keys per container (removed from the image; kept for the container's lifetime).
  ssh-keygen -A >/dev/null 2>&1
  mkdir -p /run/sshd /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/00-orca-docker.conf <<EOF
Port $port
ListenAddress $bind
AllowUsers $user
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding yes
PrintMotd no
AcceptEnv LANG LC_* COLORTERM TERM_PROGRAM
ClientAliveInterval 30
EOF
  install -d -m 700 -o "$uid" -g "$gid" "$home/.ssh"
  printf '%s\n' "$ORCA_DOCKER_SSH_PUBKEY" > "$home/.ssh/authorized_keys"
  chown "$uid:$gid" "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"
  # Non-interactive ssh sessions (Orca's relay) get the same PATH as the desktop session.
  grep -q 'orca-docker' /etc/environment 2>/dev/null || \
    echo 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" # orca-docker' >> /etc/environment
  /usr/sbin/sshd -E /run/orca-docker/sshd.log || echo "[orca-docker] sshd failed to start" >&2
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}' > /run/orca-docker/ssh-host-key-fingerprint || true
  : > /run/orca-docker/env-mode  # tells the in-container `orca-docker` that this is a per-workspace environment
}

if [ -n "${ORCA_DOCKER_SSH_PUBKEY:-}" ]; then
  start_sshd
fi

export HOME="$home" USER="$user" LOGNAME="$user"
exec setpriv --reuid="$uid" --regid="$gid" --init-groups /opt/orca-docker/supervisor.sh "$@"

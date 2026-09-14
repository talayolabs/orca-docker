# shellcheck shell=sh
# Installed as /etc/profile.d/orca-docker.sh and sourced from /etc/bash.bashrc: shells that enter
# the container over ssh (Orca terminals, agents) pick up the desktop session (DISPLAY, D-Bus,
# noVNC port) published by supervisor.sh, which only the supervisor's own children would inherit.
if [ -f /run/orca-docker/env ]; then
  . /run/orca-docker/env
fi
case ":$PATH:" in
  *:/usr/local/bin:*) ;;
  *) PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin${PATH:+:$PATH}" ;;
esac
export PATH

# orca-docker desktop base image.
#
# A disposable "personal computer" for one coding-agent session:
#   - Xvfb virtual display + XFCE desktop + Chromium
#   - x11vnc + noVNC so a human can watch/take over from a browser tab
#   - xdotool/scrot + a small computer-use MCP server (screenshot, mouse, keyboard, windows)
#   - git, Node.js + pnpm/npm/yarn (via corepack), Python, build tools, sudo (passwordless)
#   - Claude Code CLI (first supported agent)
#
# Nothing from the host is mounted. The wrapper seeds a clone of the repository (same
# absolute path as the host worktree) plus copies of the agent login/config, and the
# session's commits leave the container only through `orca-docker publish` (git bundle
# handed to the host). The container user is created at start time with the host's
# UID/GID/HOME so paths and commit identity line up.
# In environment mode (`orca-docker env`, an Orca per-workspace recipe) the container also
# runs sshd so Orca can make it the workspace's execution host (file tree, git, terminals,
# agents all run inside). Host keys are generated per container on first start.
# Repos customize by building `FROM` this image (see examples/repo-dockerfile).

ARG BASE_IMAGE=debian:bookworm-slim
FROM ${BASE_IMAGE}

ARG NODE_MAJOR=22
# Pinned; override with --build-arg CLAUDE_CODE_VERSION=latest (the in-container autoupdater is off).
ARG CLAUDE_CODE_VERSION=2.1.266

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git openssh-client openssh-server sudo jq less procps psmisc \
      python3 python3-pip python3-venv build-essential pkg-config unzip zip xz-utils \
      locales tzdata dbus-x11 util-linux tini \
      xvfb x11vnc novnc websockify xdotool scrot xclip wmctrl x11-utils x11-xserver-utils \
      xfce4 xfce4-terminal mousepad fonts-dejavu fonts-liberation fonts-noto-color-emoji \
      chromium imagemagick \
    && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# Node.js from NodeSource; pnpm/yarn through corepack.
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

# Computer-use MCP server (stdio). Registered via `claude --mcp-config`.
COPY mcp/computer-use /opt/orca-docker/mcp/computer-use
RUN cd /opt/orca-docker/mcp/computer-use && npm install --omit=dev && npm cache clean --force

COPY mcp.json /opt/orca-docker/mcp.json
COPY entrypoint.sh supervisor.sh run-agent.sh bootstrap-repo.sh outbox-wait.sh /opt/orca-docker/
COPY orca-docker-cli.sh /usr/local/bin/orca-docker
COPY chromium-wrapper.sh /usr/local/bin/chromium-wrapper
COPY profile.sh /etc/profile.d/orca-docker.sh
RUN chmod 755 /opt/orca-docker/*.sh /usr/local/bin/orca-docker /usr/local/bin/chromium-wrapper \
    && printf '\n[ -f /etc/profile.d/orca-docker.sh ] && . /etc/profile.d/orca-docker.sh\n' >> /etc/bash.bashrc \
    && ln -sf /usr/local/bin/chromium-wrapper /usr/local/bin/google-chrome \
    && ln -sf /usr/local/bin/chromium-wrapper /usr/local/bin/chrome

ENV DISPLAY=:99 \
    ORCA_DOCKER_DISPLAY_SIZE=1440x900x24 \
    ORCA_DOCKER_VNC_PORT=5900 \
    ORCA_DOCKER_NOVNC_PORT=6080 \
    ORCA_DOCKER_BIND=127.0.0.1 \
    DISABLE_AUTOUPDATER=1 \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    CHROMIUM_FLAGS="--no-sandbox --disable-dev-shm-usage --no-first-run --password-store=basic"

LABEL org.opencontainers.image.title="orca-docker desktop" \
      org.opencontainers.image.description="Disposable Linux desktop for one Orca agent session" \
      org.opencontainers.image.source="https://github.com/talayolabs/orca-docker"

# Runs as root only long enough to create the session user, then drops privileges into the
# supervisor (desktop + idle). Agents run via `docker exec ... /opt/orca-docker/run-agent.sh`.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/orca-docker/entrypoint.sh"]
CMD []

# orca-docker

Run each [Orca](https://github.com/stablyai/orca) agent tab inside its own disposable Linux
desktop container — a fresh "PC" per session with a virtual display, XFCE, Chromium, noVNC
and a computer-use MCP server, while Orca keeps working exactly as before (status hooks,
resume, worktrees).

Claude Code is the first supported agent. The wrapper is agent-agnostic; more agents later.

```
 Orca (host)                                    container: orca-docker-<tab-id>
 ┌───────────────────────────┐                  ┌─────────────────────────────────────┐
 │ agent tab ── orca-docker claude ──────────▶  │ tini ─ entrypoint (uid/gid = host)  │
 │   ▲ hook posts to                            │   └─ session.sh                     │
 │   │ 127.0.0.1:<port>  ◀── --network host ──  │        Xvfb :N ─ XFCE ─ Chromium    │
 │   │                                          │        x11vnc ─ noVNC :26xxx        │
 │   └── ~/.claude, worktree, ~/.orca  ═══════  │        pnpm/npm install (lockfile)   │
 │        bind-mounted at identical paths       │        exec claude --mcp-config ...  │
 └───────────────────────────┘                  └─────────────────────────────────────┘
```

## Requirements

- Linux host with Docker (Docker Desktop on macOS/Windows works with reduced integration, see
  [Caveats](#caveats)).
- Orca ≥ a build with per-agent command overrides (Settings → Agents).
- `bash`, `git`, `node` on the host (node only for the smoke test).

## Install

```sh
git clone https://github.com/talayolabs/orca-docker ~/.orca-docker
ln -s ~/.orca-docker/bin/orca-docker ~/.local/bin/orca-docker   # anything on PATH

# Build the default desktop image (~2.7 GB) — or skip and let the first launch pull/build it.
orca-docker --build
```

### Hook it into Orca

In Orca, set the Claude agent **command override** to:

```
orca-docker claude
```

That's it. Orca still appends its own arguments (`--model`, `--resume <session-id>`,
prompts, …) and the wrapper forwards them verbatim to `claude` inside the container. Each tab
gets its own container named `orca-docker-<tab-id>`; it is removed when the agent exits.

### Try it standalone

```sh
cd ~/some-repo
orca-docker claude            # agent in a fresh desktop container
orca-docker --shell           # just a bash shell in one
orca-docker --print-config claude --model opus   # show the docker run command, don't run it
```

Every launch prints the noVNC URL (`http://127.0.0.1:26xxx/vnc.html?autoconnect=1`) so you
can watch or take over the desktop from a browser.

## What the agent gets

| Inside the container | Notes |
| --- | --- |
| Debian 12, XFCE on Xvfb (1440×900), Chromium | `chromium-wrapper` / `google-chrome` on PATH with container-safe flags |
| noVNC + x11vnc | bound to `127.0.0.1` on the host, unique port per tab |
| `computer` MCP server | `screenshot`, `click`, `drag`, `scroll`, `type`, `key`, `mouse_move`, `cursor_position`, `screen_size`, `list_windows`, `focus_window`, `open`, `launch` — auto-attached via `--mcp-config` |
| Node 22, corepack (pnpm/yarn), Python 3, build-essential, git, jq, curl, sudo (passwordless) | |
| Claude Code CLI (pinned in the Dockerfile, autoupdater off) | |
| Your worktree, at the **same absolute path** | rw; the main repo's `.git` is mounted too when it's a `git worktree` |
| `~/.claude`, `~/.claude.json` (or `$CLAUDE_CONFIG_DIR`) | rw — transcripts, credentials, settings, resume state are shared with the host |
| `~/.orca/agent-hooks` (ro), Orca's `agent-hooks/endpoint.env` dir (rw) | Orca's managed lifecycle hook and the hook endpoint for PTYs surviving an Orca restart |
| `~/.gitconfig`, `~/.config/git` (ro) | git identity |

Dependencies are installed at container start from the repo lockfile (`pnpm-lock.yaml` →
`pnpm install --frozen-lockfile`, `package-lock.json` → `npm ci`, `yarn.lock`, `bun.lock*` if
the image has bun, `requirements.txt` → `.venv`), skipped when the lockfile hash hasn't changed since the last
run. Node modules land in the worktree (host-visible), never in the image.

## Customizing the image

Resolution order, first match wins:

1. `ORCA_DOCKER_IMAGE=<image>` — explicit override.
2. `<worktree>/docker/Dockerfile` or `<worktree>/.orca-docker/Dockerfile` (or
   `ORCA_DOCKER_DOCKERFILE=<path>`) — a **per-repo image**, built automatically on first
   launch and cached by a content hash of its build context as `orca-docker-repo:<hash>`.
3. `ORCA_DOCKER_DEFAULT_IMAGE` (default `ghcr.io/talayolabs/orca-docker:latest`) — pulled, or
   built from this checkout's `image/` if the pull fails.

A per-repo Dockerfile should extend the base image and add only system-level things:

```dockerfile
FROM ghcr.io/talayolabs/orca-docker:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client && rm -rf /var/lib/apt/lists/*
RUN npm install -g some-cli@1.2.3
ENV ORCA_DOCKER_INIT="cp -n .env.example .env || true"   # runs in the worktree before the agent
```

See [`examples/repo-dockerfile/Dockerfile`](examples/repo-dockerfile/Dockerfile).

## Configuration

All optional, set in the environment Orca launches agents with (or your shell):

| Variable | Default | Effect |
| --- | --- | --- |
| `ORCA_DOCKER_IMAGE` | — | use this image, skip repo Dockerfile discovery |
| `ORCA_DOCKER_DOCKERFILE` | auto | per-repo Dockerfile path |
| `ORCA_DOCKER_DEFAULT_IMAGE` | `ghcr.io/talayolabs/orca-docker:latest` | fallback image |
| `ORCA_DOCKER_NETWORK` | `host` on Linux, `bridge` elsewhere | docker network mode |
| `ORCA_DOCKER_MOUNTS` | — | extra `-v src:dst[:opts]` specs, space separated |
| `ORCA_DOCKER_ARGS` | — | extra raw `docker run` args |
| `ORCA_DOCKER_MOUNT_SSH=1` | off | mount `~/.ssh` read-only (git over ssh) |
| `ORCA_DOCKER_ORCA_CLI=1` | off | bridge the host `orca` CLI into the container (mounts Orca userData + app bundle) |
| `ORCA_DOCKER_KEEP=1` | off | don't `--rm` the container (debugging) |
| `ORCA_DOCKER_DESKTOP=0` | on | skip Xvfb/XFCE/noVNC |
| `ORCA_DOCKER_AUTO_INSTALL=0` | on | skip lockfile dependency install |
| `ORCA_DOCKER_MCP=0` | on | don't attach the computer-use MCP |
| `ORCA_DOCKER_DISPLAY_SIZE` | `1440x900x24` | Xvfb geometry |
| `ORCA_DOCKER_INIT` | — | shell snippet run in the worktree before the agent starts |

`orca-docker --gc` removes exited containers left behind by crashes.

## How Orca integration works

Verified against Orca's source (`tui-agent-launch-command.ts`, `hook-script.ts`,
`hook-post-command.ts`, `spawn-env-keys.ts`):

- **Identity & hooks.** `ORCA_PANE_KEY`, `ORCA_TAB_ID`, `ORCA_WORKTREE_ID`,
  `ORCA_AGENT_LAUNCH_TOKEN`, `ORCA_AGENT_HOOK_*`, `ORCA_CLAUDE_AGENT_STATUS_SETTINGS`,
  `CLAUDE_*`, `ANTHROPIC_*` are passed through unchanged (`-e NAME`, values never touch a
  command line). Claude's `settings.json` points at `~/.orca/agent-hooks/*.sh`, which is
  mounted, and that script posts to `http://127.0.0.1:$ORCA_AGENT_HOOK_PORT` — reachable
  because the container uses `--network host`. Statuses, permission prompts and resume proofs
  behave exactly as on the host.
- **Resume.** Orca appends `--resume <id>` (it fails open for wrapper commands and appends
  after the base). Transcripts live in `~/.claude/projects/<encoded-cwd>/`, so the identical
  worktree path + shared `~/.claude` make cold restores work.
- **Exit & signals.** `exec docker run` with tini as PID 1 — Ctrl-C and exit codes reach the
  agent and come back to Orca.
- **Ports.** Under host networking every tab shares the host's port space, so the display
  number, VNC and noVNC ports are derived from the tab id (`:1xx`, `25xxx`, `26xxx`) and
  probed for collisions.

## Caveats

- **macOS / Windows (Docker Desktop):** the container's loopback is not the host's, so Orca's
  hook posts don't arrive → agent status stays grey (everything else works; noVNC is
  published on `127.0.0.1:<port>`). Also, Claude's macOS Keychain credentials are not visible
  in the container — run `claude login` once inside (`orca-docker --shell`, then `claude`) so
  a `~/.claude/.credentials.json` exists. A loopback relay is on the roadmap.
- **Isolation is Docker-grade, not a VM.** `--network host` and a passwordless `sudo` inside
  the container are deliberate trade-offs for hook reachability and apt installs. Nothing
  from `$HOME` is mounted except the paths listed above.
- **Orca process recognition** watches the PTY's foreground process; inside the container
  that is `docker` from Orca's point of view. Status hooks still drive readiness, but any
  feature that inspects the agent process tree directly won't see Claude.
- Chromium runs with `--no-sandbox` (the container has no user namespaces for its own
  sandbox).

## Development

```sh
./test/smoke.sh                # builds the image if missing; ~2 min; exercises everything below
SMOKE_BUILD=1 ./test/smoke.sh  # rebuild first
```

The smoke test spins up a fake Orca hook listener + a faithful copy of Orca's managed hook
script and asserts, from inside a container: uid/HOME/cwd identity, `claude --version`, git
in a worktree, lockfile install, Xvfb, scrot, noVNC 200, XFCE panel, headless Chromium, the
MCP server over stdio (screenshot/mouse/windows), a hook POST reaching the host with the
token + payload, exit-status and argument pass-through, and `--print-config` mounts.

Layout:

```
bin/orca-docker            the wrapper (bash)
image/Dockerfile           desktop base image
image/entrypoint.sh        root phase: create host-matching user, drop privileges
image/session.sh           user phase: desktop, deps, MCP attach, exec agent
image/mcp/computer-use/    MCP server (node, xdotool/scrot/wmctrl)
examples/repo-dockerfile/  per-repo image example
test/                      smoke test + fixtures
```

## Roadmap

- Loopback relay for macOS/Windows hook delivery.
- Dependency learning loop: detect apt/npm installs the agent performs and propose them as a
  `docker/Dockerfile` change (never mutate the shared image silently).
- More agents (`orca-docker codex`, …) once the Claude path is solid.
- Native Orca runtime instead of a wrapper, if upstream grows per-tab environment recipes.

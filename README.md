# orca-docker

Run [Orca](https://github.com/stablyai/orca) coding sessions inside their own Linux desktop
containers — a persistent "PC" per session with a virtual display, XFCE, Chromium, noVNC and
a computer-use MCP server — **without mounting anything from the host**. The container gets
its own clone of the repository; the host checkout is never touched.

Two ways to use it:

| | **Per-worktree environment** (recommended) | **Per-tab wrapper** (legacy) |
| --- | --- | --- |
| Unit of isolation | one container per Orca worktree, selected as *Run on: orca-docker* | one container per agent tab |
| Where Orca's tools run | inside the container over SSH: file tree, editor, search, git status/diff, watchers, terminals, agents | on the host (they show the host checkout, not the container's) |
| Agents per container | one (`orca-docker claude` refuses a second) | one per tab |
| Getting work out | Orca's own commit / push / PR UI, inside the container | `orca-docker publish` → `orca/<tab>` branch on the host, pushed / PR'd |
| Setup | `orca.yaml` recipe in the repo | Orca agent command override |
| See | [Per-worktree environments](#per-worktree-environments-orca-recipe) | [Per-tab wrapper](#per-tab-wrapper-orca-command-override) |

Claude Code is the first supported agent. The wrapper is agent-agnostic; more agents later.

```
 Orca (host)                                    container: orca-docker-env-<workspace>-<id>   (kept, no --rm)
 ┌───────────────────────────────────┐          ┌────────────────────────────────────────────────┐
 │ worktree "Run on: orca-docker"    │          │ sshd (key-only, per-container host key)        │
 │   orca.yaml recipe ─ env create ──┼─ docker ▶│  clone at the same path @ the pinned commit    │
 │   file tree · editor · search     │   ssh    │  Orca relay: fs, git, watchers, terminals      │
 │   git · terminals · agent tab  ◀──┼──────────┼▶ orca-docker claude (one agent per container)  │
 │ commit / push / PR from Orca ─────┼──────────┼▶ git push origin                               │
 │                                   │          │  supervisor: Xvfb ─ XFCE ─ x11vnc ─ noVNC       │
 └───────────────────────────────────┘          └────────────────────────────────────────────────┘
```

## Per-worktree environments (Orca recipe)

Orca's [per-workspace environments](https://github.com/stablyai/orca) let a worktree run on a
remote host over SSH; orca-docker provides that host as a local Docker container. Everything
Orca does for that worktree — file tree, editor, search, git status and diff, file watching,
terminals and agent tabs — happens **inside the container**, so what the agent edits is what
you see, and you commit / push / open PRs with Orca's normal git UI. Nothing is mounted.

### Set up

1. Install orca-docker (below) and make sure `orca-docker` is on `PATH` (or set
   `ORCA_DOCKER_BIN`; `~/.orca-docker/bin/orca-docker` is also found automatically).
2. Copy [`orca.yaml`](orca.yaml) (or just its `environmentRecipes` block) and
   [`scripts/orca-vm/orca-docker.sh`](scripts/orca-vm/orca-docker.sh) into the repository's
   primary branch and commit them:

   ```yaml
   environmentRecipes:
     - id: orca-docker
       name: orca-docker (local desktop container)
       checkoutMode: provisioned-root
       create: ./scripts/orca-vm/orca-docker.sh create
       suspend: ./scripts/orca-vm/orca-docker.sh suspend
       resume: ./scripts/orca-vm/orca-docker.sh resume
       destroy: ./scripts/orca-vm/orca-docker.sh destroy
   ```

3. In Orca, create a new worktree for the repo and pick **orca-docker** under **Run on**.

Orca runs `create` (a container comes up in ~15 s, plus the clone and dependency install),
connects over SSH and opens the worktree with the container as its execution host. The
recipe's stderr shows up in Orca's provisioning log, including the noVNC URL of the desktop.

### What happens

- **Container.** One retained container per worktree, named
  `orca-docker-env-<workspace>-<instance>`, from the same image resolution as the per-tab
  wrapper (explicit `ORCA_DOCKER_IMAGE`, repo `docker/Dockerfile`, default image). Bridge
  networking; `sshd` and noVNC are published on `127.0.0.1` only (ports `27xxx` / `26xxx`).
- **SSH.** The recipe generates an Ed25519 client key per environment (kept under
  `~/.local/state/orca-docker/`, mode 600, never in the image) and passes only the public
  half into the container. `sshd` accepts that key alone: no passwords, no root. Each
  container generates its own host keys at first start (the image ships none) and keeps them
  across restarts. The recipe reads the container's host key over `docker exec` — a trusted
  local channel — and records it for `[127.0.0.1]:<port>` in your `~/.ssh/known_hosts`, so
  Orca connects with strict host-key verification instead of trusting first contact. The line
  is removed again on `destroy`.
- **Repository.** With `checkoutMode: provisioned-root` Orca tells the recipe which commit it
  pinned (`ORCA_REPO_REF_HEAD`), from which ref/URL, and which branch the worktree should be on.
  The container gets a fresh clone at the **same absolute path** as the host checkout, checked
  out to exactly that commit on that branch, with `origin` set so `git fetch`/`push` work. If
  the pinned commit is not in the host checkout yet (someone pushed), the recipe fetches the
  objects from `ORCA_REPO_URL` — it never moves a host branch or touches the host working tree.
  Without `checkoutMode` (schema 1) the container holds the primary checkout on the base
  branch and Orca adds its own linked worktree inside the container.
- **Lifecycle.** Containers are created without `--rm`. *Suspend* (Orca's sleep) stops the
  container; *resume* starts it and re-checks the SSH port and host key — clone, deps, browser
  profile and agent transcripts survive. Only *destroy* (removing the worktree/environment in
  Orca, or `orca-docker env destroy <container>`) deletes the container and its client key.
  `orca-docker --gc` never touches environment containers.
- **One agent per worktree.** Inside the container, `orca-docker claude` is the agent
  launcher (Orca applies the command override on the execution host too). It takes a
  container-local lock: the first agent tab runs, a second one exits immediately with
  *"this workspace already has a running agent … create another workspace"* (exit 75).
  Terminal tabs are unaffected. The lock is released when the agent exits and recovers on its
  own after a crash. Orca's *+ agent* button still exists — the limit is enforced at launch.
- **No publish protocol.** In environment mode the legacy `orca/<tab>` branch and
  `orca-docker publish` are disabled; Orca's git UI inside the container is the way out.

### Commands

```sh
orca-docker env ls                        # environment containers, their workspace, state, SSH port
orca-docker env status <container>        # re-print one environment's recipe result
orca-docker env destroy <container>       # remove one by hand (container, client key, known_hosts line)
```

`create` / `suspend` / `resume` / `destroy` without a name speak Orca's recipe protocol
(`ORCA_VM_*` / `ORCA_REPO_*` environment in, exactly one JSON result on stdout, lifecycle
payload on stdin) and are meant to be called by Orca through the shim.

### Limits

- Orca offers recipes for **git repositories only**; folder workspaces use the per-tab
  wrapper. (`orca-docker env create` itself accepts a plain directory — it is copied as a
  tarball — for manual use.)
- Recipes run on the local Docker daemon; on macOS/Windows Docker Desktop the published
  `127.0.0.1` ports work as on Linux (the loopback caveat of the per-tab wrapper does not apply,
  since Orca's relay talks to the container over SSH).
- The container user's home is the same path as yours (`/home/<you>`), and the clone lives at
  the same absolute path, so anything Orca stores by path lines up. Repositories must therefore
  live under your home directory (or somewhere the container user may create siblings) for
  Orca's linked worktrees in schema-1 mode.

## Per-tab wrapper (Orca command override)

The original mode: each Orca agent tab gets its own container while Orca's own tools stay on
the host. The session's work comes back as a git branch (and pull request) that the wrapper
announces in the Orca pane. Orca keeps working as before (status hooks, resume).

```
 Orca (host)                                       container: orca-docker-<tab-id>   (kept, no --rm)
 ┌──────────────────────────────────┐              ┌──────────────────────────────────────────────┐
 │ agent tab ── orca-docker claude ─┼─ docker exec ▶  run-agent.sh: deps install, claude --mcp… │
 │   ▲ hook posts to                │              │  supervisor: Xvfb :N ─ XFCE ─ x11vnc ─ noVNC │
 │   │ 127.0.0.1:<port> ◀ --network host ──────────┼─ managed hook script (copied, not mounted)   │
 │   │                              │              │                                              │
 │ repo ── git bundle ── docker cp ─┼──────────────▶  clone at the same path, branch orca/<tab>  │
 │ branch orca/<tab> ◀── fetch ─────┼── docker cp ◀┼─ `orca-docker publish` → outbox bundle       │
 │   └─ push origin / gh pr create  │              │                                              │
 └──────────────────────────────────┘              └──────────────────────────────────────────────┘
```

## Requirements

- Linux host with Docker (Docker Desktop on macOS/Windows works; the per-tab wrapper has
  reduced integration there, see [Caveats](#caveats)).
- Orca ≥ a build with per-agent command overrides (Settings → Agents); environment recipes
  need a build with `environmentRecipes` in `orca.yaml` ("Run on" in the new-worktree dialog).
- `bash`, `git`, `ssh`/`ssh-keygen` on the host; `gh` for automatic pull requests (per-tab
  mode); `node` only for the smoke test.

## Install

```sh
git clone https://github.com/talayolabs/orca-docker ~/.orca-docker
ln -s ~/.orca-docker/bin/orca-docker ~/.local/bin/orca-docker   # anything on PATH

# Build the default desktop image (~2.7 GB) — or skip and let the first launch pull/build it.
orca-docker --build
```

### Hook it into Orca (per-tab wrapper)

For per-worktree environments see [above](#per-worktree-environments-orca-recipe). For the
per-tab wrapper, set the Claude agent **command override** in Orca to:

```
orca-docker claude
```

That's it. Orca still appends its own arguments (`--model`, `--resume <session-id>`,
prompts, …) and the wrapper forwards them verbatim to `claude` inside the container.

### Try it standalone

```sh
cd ~/some-repo
orca-docker claude            # agent in its own desktop container (one per directory outside Orca)
orca-docker --shell           # a bash shell in the same container
orca-docker --sessions        # list session containers, their branch and state
orca-docker --rm-session <tab-id|container>   # remove a session (the only way a container is deleted)
orca-docker --gc              # remove sessions stopped for > 14 days (--gc --all: every stopped one)
orca-docker --fresh claude    # throw the tab's container away and start over
orca-docker --print-config claude --model opus   # show the docker create/exec commands, don't run them
```

Every launch prints the noVNC URL (`http://127.0.0.1:26xxx/vnc.html?autoconnect=1`) so you
can watch or take over the desktop from a browser.

## Session model: nothing is mounted

**Code in.** On first launch the wrapper bundles the repository (`git bundle` of `HEAD`, its
branch, and — by default — a throwaway commit with your uncommitted changes) and copies it into
the container, where it is cloned at the **same absolute path** as on the host and checked out
on a new branch `orca/<tab-id>` at the commit you launched from. `origin` is preserved so the
agent can `git fetch`. Your host worktree is never touched, and the throwaway ref is deleted
from the host right after bundling. Non-git directories are copied as a tarball (publishing is
then disabled).

**Code out.** Only commits leave the container, and only through publishing:

- `orca-docker publish [--commit MESSAGE]` inside the container (also exposed to the agent as
  the `publish` MCP tool, and run automatically when the agent exits). It writes a bundle of
  the branch's new commits to an outbox; the wrapper on the host fetches it into the host
  repository as the local branch `orca/<tab-id>` and then, depending on `ORCA_DOCKER_PUBLISH`:
  - `local` — stop there (default when the repo has no `origin`);
  - `push` — also push the branch to `origin` (default when it has one) and print the branch
    URL (`https://github.com/<owner>/<repo>/tree/orca/<tab>` for GitHub) plus a compare link;
  - `pr` — push and open/update a pull request with `gh` (needs `gh auth login` on the host);
  - `off` — never publish.
- Each publish is announced in the pane the agent runs in:
  `[orca-docker] published orca/<tab> (3 commit(s)) → https://github.com/…/tree/orca/<tab>`.
- Uncommitted changes are **not** published unless `--commit` is used or
  `ORCA_DOCKER_AUTOCOMMIT=1` (then the exit-time publish commits them as a `wip:` commit).

**Persistent, per tab.** Containers are created without `--rm`. When the agent exits the
container is stopped and kept; relaunching the same Orca tab (e.g. `--resume`) starts the same
container, so the clone, its branch, installed `node_modules`, Claude's transcripts and login
inside it all survive. A container is deleted only by `orca-docker --rm-session`, `--gc`, or
`--fresh`.

**Config copied, not mounted.** At first launch the wrapper copies into the container's `$HOME`:
`~/.claude.json`, `~/.claude` (or `$CLAUDE_CONFIG_DIR`) minus per-session state
(`projects`, `todos`, caches, …) — so settings, credentials, hooks, skills, commands, agents
and plugins come along — plus `~/.gitconfig`, `~/.config/git`, and anything listed in
`ORCA_DOCKER_SEED`. Symlinks are followed (copied as files). On every launch it refreshes Orca's managed hook script directory
(`~/.orca/agent-hooks`) and hook endpoint file, and `.credentials.json` / `settings.json` when
the host copy is newer. Nothing in the container can write back to the host except through
`publish`.

## What the agent gets

| Inside the container | Notes |
| --- | --- |
| Debian 12, XFCE on Xvfb (1440×900), Chromium | `chromium-wrapper` / `google-chrome` on PATH with container-safe flags |
| noVNC + x11vnc | bound to `127.0.0.1` on the host, unique port per tab |
| `computer` MCP server | `screenshot`, `click`, `drag`, `scroll`, `type`, `key`, `mouse_move`, `cursor_position`, `screen_size`, `list_windows`, `focus_window`, `open`, `launch`, `publish` — auto-attached via `--mcp-config` |
| Node 22, corepack (pnpm/yarn), Python 3, build-essential, git, jq, curl, sudo (passwordless) | |
| Claude Code CLI (pinned in the Dockerfile, autoupdater off) | |
| A clone of your repository at the **same absolute path**, on branch `orca/<tab-id>` | with your uncommitted changes carried over (`ORCA_DOCKER_CARRY_CHANGES=0` to skip) |
| `orca-docker publish` / `orca-docker status` | the only way out |

Dependencies are installed at launch from the repo lockfile (`pnpm-lock.yaml` →
`pnpm install --frozen-lockfile`, `package-lock.json` → `npm ci`, `yarn.lock`, `bun.lock*` if
the image has bun, `requirements.txt` → `.venv`), skipped when the lockfile hash hasn't changed
since the last run. They live in the container, never on the host.

## Customizing the image

Resolution order, first match wins:

1. `ORCA_DOCKER_IMAGE=<image>` — explicit override.
2. `<worktree>/docker/Dockerfile` or `<worktree>/.orca-docker/Dockerfile` (or
   `ORCA_DOCKER_DOCKERFILE=<path>`) — a **per-repo image**, built automatically on first
   launch and cached by a content hash of its build context as `orca-docker-repo:<hash>`.
3. `ORCA_DOCKER_DEFAULT_IMAGE` (default `ghcr.io/talayolabs/orca-docker:latest`) — pulled, or
   built from this checkout's `image/` if the pull fails.

The image is chosen when the session container is created; an existing session keeps its
image until you `--fresh` it.

A per-repo Dockerfile should extend the base image and add only system-level things:

```dockerfile
FROM ghcr.io/talayolabs/orca-docker:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client && rm -rf /var/lib/apt/lists/*
RUN npm install -g some-cli@1.2.3
ENV ORCA_DOCKER_INIT="cp -n .env.example .env || true"   # runs in the repo before the agent
```

See [`examples/repo-dockerfile/Dockerfile`](examples/repo-dockerfile/Dockerfile).

## Configuration

All optional, set in the environment Orca launches agents with (or your shell):

| Variable | Default | Effect |
| --- | --- | --- |
| `ORCA_DOCKER_IMAGE` | — | use this image, skip repo Dockerfile discovery |
| `ORCA_DOCKER_DOCKERFILE` | auto | per-repo Dockerfile path |
| `ORCA_DOCKER_DEFAULT_IMAGE` | `ghcr.io/talayolabs/orca-docker:latest` | fallback image |
| `ORCA_DOCKER_NETWORK` | `host` on Linux, `bridge` elsewhere; environments: `bridge` | docker network mode |
| `ORCA_DOCKER_STATE_DIR` | `~/.local/state/orca-docker` | environment SSH client keys and recorded host keys |
| `ORCA_DOCKER_BRANCH` | `orca/<tab-id>` | branch the session works on and publishes |
| `ORCA_DOCKER_PUBLISH` | `push` with an origin, else `local` | `local` / `push` / `pr` / `off` (see above) |
| `ORCA_DOCKER_AUTOCOMMIT=1` | off | commit leftover changes as `wip:` when publishing on exit |
| `ORCA_DOCKER_CARRY_CHANGES=0` | on | don't carry the host's uncommitted changes into the clone |
| `ORCA_DOCKER_SEED` | — | extra host files/dirs to copy into the container at creation (space separated; `~/` or relative = under `$HOME`) |
| `ORCA_DOCKER_FRESH=1` | off | same as `--fresh` |
| `ORCA_DOCKER_KEEP_RUNNING=1` | off | leave the container running after the agent exits (default: stop it, keep it) |
| `ORCA_DOCKER_GC_DAYS` | `14` | age threshold for `--gc` |
| `ORCA_DOCKER_ARGS` | — | extra raw `docker create` args |
| `ORCA_DOCKER_DESKTOP=0` | on | skip Xvfb/XFCE/noVNC |
| `ORCA_DOCKER_AUTO_INSTALL=0` | on | skip lockfile dependency install |
| `ORCA_DOCKER_MCP=0` | on | don't attach the computer-use MCP |
| `ORCA_DOCKER_DISPLAY_SIZE` | `1440x900x24` | Xvfb geometry |
| `ORCA_DOCKER_INIT` | — | shell snippet run in the repo before the agent starts |

## How Orca integration works

Verified against Orca's source (`tui-agent-launch-command.ts`, `hook-script.ts`,
`hook-post-command.ts`, `spawn-env-keys.ts`, `server-runtime-env.ts`):

- **Identity & hooks.** `ORCA_PANE_KEY`, `ORCA_TAB_ID`, `ORCA_WORKTREE_ID`,
  `ORCA_AGENT_LAUNCH_TOKEN`, `ORCA_AGENT_HOOK_*`, `CLAUDE_*`, `ANTHROPIC_*` are passed through
  unchanged (`-e NAME`, values never touch a command line). Claude's `settings.json` (copied)
  points at `~/.orca/agent-hooks/*.sh` (copied each launch, since Orca rotates port/token per
  run), and that script posts to `http://127.0.0.1:$ORCA_AGENT_HOOK_PORT` — reachable because
  the container uses `--network host`. Statuses and permission prompts behave as on the host.
- **Resume.** Orca appends `--resume <id>`. Transcripts live in
  `~/.claude/projects/<encoded-cwd>/` *inside the tab's container*; the identical repo path and
  the retained container make resumes work. Claude state does not exist on the host.
- **Exit & signals.** The agent runs via `docker exec`; its exit code is returned to Orca.
  When the pane goes away (SIGHUP/TERM/INT) the wrapper stops the container — it stays on disk.
- **Ports.** Under host networking every tab shares the host's port space, so the display
  number, VNC and noVNC ports are derived from the tab id (`:1xx`, `25xxx`, `26xxx`) and
  probed for collisions; they are fixed for the container's lifetime.

## Caveats

- **macOS / Windows (Docker Desktop):** the container's loopback is not the host's, so Orca's
  hook posts don't arrive → agent status stays grey (everything else works; noVNC is
  published on `127.0.0.1:<port>`). Claude's macOS Keychain credentials are not visible in the
  container — run `claude login` once inside (`orca-docker --shell`, then `claude`); the login
  persists in the container. A loopback relay is on the roadmap.
- **Credentials are copied into the container.** `.credentials.json` (and anything in
  `ORCA_DOCKER_SEED`) lives in the container's filesystem for as long as the session exists.
  Remove sessions you no longer need. Git push and `gh` run on the **host**, so no GitHub
  credentials need to enter the container.
- **Isolation is Docker-grade, not a VM.** `--network host` and a passwordless `sudo` inside
  the container are deliberate trade-offs for hook reachability and apt installs.
- **Orca process recognition** watches the PTY's foreground process; inside the container
  that is `docker` from Orca's point of view. Status hooks still drive readiness, but any
  feature that inspects the agent process tree directly won't see Claude.
- Chromium runs with `--no-sandbox` (the container has no user namespaces for its own
  sandbox).
- Stopped containers keep their disk (clone + deps + browser profile) until removed.

## Development

```sh
./test/smoke.sh                # builds the image if missing; ~3 min; exercises everything below
SMOKE_BUILD=1 ./test/smoke.sh  # rebuild first
```

The smoke test spins up a fake Orca hook listener, a faithful copy of Orca's managed hook
script and a project with a local bare `origin`, then asserts: uid/HOME/cwd identity inside the
container, the clone is on `orca/<tab>` at the host's HEAD with the host's uncommitted changes
carried over, lockfile install, `claude --version`, Xvfb, scrot, noVNC 200, XFCE panel,
headless Chromium, the MCP server over stdio (including the `publish` tool), a hook POST
reaching the host with token + payload, explicit / MCP / exit-time publishing landing as 3
commits on the host branch and on `origin`, the host worktree unchanged and free of session
files, the container kept (no `--rm`, no mounts) and resumed with its state on relaunch,
`--rm-session`, local-only repos, two concurrent desktops, exit-status and argument
pass-through, and `--print-config`.

For environments it drives the recipe protocol the way Orca does (`ORCA_VM_*` / `ORCA_REPO_*`
environment, lifecycle payload on stdin) and asserts: one JSON result on stdout with diagnostics
on stderr, the provisioned-root clone at the exact pinned commit (also when it only exists on
`origin`) on the target branch with a clean tree, folder workspaces, no host-side changes, strict
host-key SSH with the key the wrapper recorded in `known_hosts`, distinct ports / host keys /
client keys for two environments, the one-agent lock (second launch exits 75, shells still work,
lock recovers after a crash), suspend / resume keeping state, `env ls`, `--gc --all` leaving
environments alone, and destroy removing the container, key and only its own `known_hosts` line.

Layout:

```
bin/orca-docker            the wrapper (bash): session + environment lifecycle, seeding, publish handling
orca.yaml                  example Orca environment recipe (copy into your repo)
scripts/orca-vm/           recipe shim the orca.yaml points at (finds orca-docker, runs `env <mode>`)
image/Dockerfile           desktop base image (+ openssh-server, no baked host keys)
image/entrypoint.sh        root phase: create host-matching user, start sshd in environment mode, drop privileges
image/supervisor.sh        PID-1 child: desktop (Xvfb/XFCE/noVNC), then idles
image/profile.sh           lets ssh logins (Orca terminals/agents) inherit the desktop session env
image/run-agent.sh         per launch (docker exec / ssh): deps, MCP attach, agent, publish on exit
image/bootstrap-repo.sh    clone the seeded bundle at the pinned commit, create the branch, replay uncommitted changes
image/orca-docker-cli.sh   in-container `orca-docker claude|publish|status` (agent gate lives here)
image/outbox-wait.sh       announces publish requests to the host wrapper
image/mcp/computer-use/    MCP server (node, xdotool/scrot/wmctrl) + publish tool
examples/repo-dockerfile/  per-repo image example
test/                      smoke test + fixtures
```

## Roadmap

- Loopback relay for macOS/Windows hook delivery.
- Dependency learning loop: detect apt/npm installs the agent performs and propose them as a
  `docker/Dockerfile` change (never mutate the shared image silently).
- More agents (`orca-docker codex`, …) once the Claude path is solid.
- Upstream Orca setting for "max agents per worktree" so the *+ agent* button reflects the
  one-agent limit instead of the launcher refusing.

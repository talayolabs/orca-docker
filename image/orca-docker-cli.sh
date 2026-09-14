#!/bin/bash
# In-container `orca-docker` command. The container has no access to the host, so publishing
# means dropping a git bundle into /run/orca-docker/outbox and waiting for the host-side
# wrapper to pick it up, fetch it into the host repository, push it and answer with a result file.
#
#   orca-docker publish [--commit MESSAGE] [--auto]   publish the current branch's new commits
#   orca-docker status                                 show base, branch, published state
#   orca-docker desktop [--print]                      open this container's desktop (noVNC) in Orca's
#                                                      browser pane for the worktree; --print only prints the URL
#   orca-docker claude [args...]                       launch an agent here (Orca's command override,
#                                                      used when this container is a workspace environment)
#
# In a per-workspace environment (`orca-docker env`, sshd on) the container is Orca's execution
# host for one worktree, and one worktree runs one agent: launching a second agent while one is
# alive is refused (create another workspace instead). Plain terminals are never limited.
set -uo pipefail

log() { printf '[orca-docker] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

outbox=/run/orca-docker/outbox
cmd="${1:-}"; shift || true

repo_root() { git rev-parse --show-toplevel 2>/dev/null; }

case "$cmd" in
  publish)
    commit_msg=""; auto=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --commit) commit_msg="${2:?--commit needs a message}"; shift 2 ;;
        --auto) auto=1; shift ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    root="$(repo_root)" || die "not inside a git repository"
    cd "$root" || exit 1
    branch="$(git symbolic-ref -q --short HEAD)" || die "detached HEAD: check out a branch first"
    base="$(cat .git/orca-docker/base 2>/dev/null || true)"
    if [ -n "$(git status --porcelain)" ]; then
      if [ -n "$commit_msg" ]; then
        git add -A && git commit -q -m "$commit_msg" || die "commit failed"
      else
        log "warning: uncommitted changes are not published (commit them, or use --commit MESSAGE)"
      fi
    fi
    head="$(git rev-parse HEAD)"
    last="$(cat .git/orca-docker/published 2>/dev/null || true)"
    if [ "$head" = "$last" ]; then
      [ "$auto" = 1 ] || log "nothing new to publish ($branch is at $(git rev-parse --short HEAD), already published)"
      exit 0
    fi
    if [ -n "$base" ] && [ "$head" = "$base" ]; then
      [ "$auto" = 1 ] || log "nothing to publish: $branch has no commits beyond the base"
      exit 0
    fi
    mkdir -p "$outbox"
    seq="$(date +%s%N)"
    bundle="$outbox/$seq.bundle"
    if [ -n "$base" ] && git merge-base --is-ancestor "$base" "$head" 2>/dev/null; then
      git bundle create -q "$bundle" "$base..refs/heads/$branch" || die "bundle failed"
    else
      git bundle create -q "$bundle" "refs/heads/$branch" || die "bundle failed"
    fi
    subject="$(git log -1 --format=%s "$head")"
    {
      printf 'seq=%s\nbranch=%s\nhead=%s\nbase=%s\nbase_branch=%s\n' "$seq" "$branch" "$head" "$base" "$(cat .git/orca-docker/base-branch 2>/dev/null || true)"
      printf 'subject=%s\ncommits=%s\n' "$subject" "$(git rev-list --count "${base:+$base..}$head" 2>/dev/null || echo '?')"
    } > "$outbox/$seq.meta.tmp"
    mv "$outbox/$seq.meta.tmp" "$outbox/$seq.meta"
    log "publishing $branch ($(git rev-parse --short "$head")) — waiting for the host..."
    result="$outbox/$seq.result"
    for _ in $(seq 1 $(( ${ORCA_DOCKER_PUBLISH_TIMEOUT:-90} * 2 ))); do
      [ -f "$result" ] && break
      sleep 0.5
    done
    if [ ! -f "$result" ]; then
      log "no answer from the host wrapper (is the tab still attached? ORCA_DOCKER_PUBLISH=off?); bundle left at $bundle"
      exit 2
    fi
    status="$(sed -n 's/^status=//p' "$result")"
    if [ "$status" = ok ]; then
      printf '%s\n' "$head" > .git/orca-docker/published
      log "published $branch → $(sed -n 's/^url=//p' "$result")"
      sed -n 's/^note=/[orca-docker]   /p' "$result" >&2
    else
      log "publish failed: $(sed -n 's/^error=//p' "$result")"
    fi
    rm -f "$bundle" "$outbox/$seq.meta" "$result"
    [ "$status" = ok ]
    ;;
  status)
    root="$(repo_root)" || die "not inside a git repository"
    cd "$root" || exit 1
    printf 'repo:      %s\nbranch:    %s\nbase:      %s (%s)\npublished: %s\nunpublished commits: %s\n' \
      "$root" "$(git symbolic-ref -q --short HEAD || echo detached)" \
      "$(cat .git/orca-docker/base 2>/dev/null || echo -)" "$(cat .git/orca-docker/base-branch 2>/dev/null || echo -)" \
      "$(cat .git/orca-docker/published 2>/dev/null || echo never)" \
      "$(git rev-list --count "$(cat .git/orca-docker/published 2>/dev/null || cat .git/orca-docker/base 2>/dev/null || echo HEAD)..HEAD" 2>/dev/null || echo '?')"
    ;;
  desktop)
    print_only=0
    [ "${1:-}" != --print ] || print_only=1
    # shellcheck source=/dev/null
    [ ! -f /run/orca-docker/env ] || . /run/orca-docker/env
    [ -n "${ORCA_DOCKER_NOVNC_PORT:-}" ] || die "no desktop in this container (ORCA_DOCKER_DESKTOP=0?)"
    # The wrapper publishes noVNC on the same port on the host's loopback, so the URL is valid from
    # both sides: Orca's browser pane browsing through the SSH host, or directly on the host.
    url="http://127.0.0.1:${ORCA_DOCKER_NOVNC_PORT}/vnc.html?autoconnect=1&resize=scale"
    echo "$url"
    [ "$print_only" = 0 ] || exit 0
    orca_cli="$(command -v orca 2>/dev/null || true)"
    for cand in "${ORCA_REMOTE_CLI_BIN_DIR:-}/orca" "$HOME/.orca-relay/bin/orca"; do
      [ -n "$orca_cli" ] || [ ! -x "$cand" ] || orca_cli="$cand"
    done
    [ -n "$orca_cli" ] || { log "orca CLI not found in this container: open the URL above (Orca links open in the worktree browser)"; exit 0; }
    if "$orca_cli" tab create --url "$url" --worktree active >/dev/null 2>&1; then
      log "desktop opened in Orca's browser pane for this worktree"
    else
      log "could not open a browser tab through the orca CLI: open the URL above"
    fi
    ;;
  ""|-h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  -*) die "unknown option: $cmd" ;;
  *)
    command -v "$cmd" >/dev/null 2>&1 || die "unknown command: $cmd (not a subcommand, and no such agent binary)"
    lock=/run/orca-docker/agent.lock
    mkdir -p /run/orca-docker 2>/dev/null
    # The lock is the open descriptor: held for as long as the agent process tree lives, released
    # by the kernel on any kind of exit, so it can never go stale.
    exec 9>>"$lock"
    if ! flock -n 9; then
      holder="$(tr '\n' ' ' < "$lock")"
      log "refusing to start $cmd: this workspace already has a running agent${holder:+ [$holder]}"
      log "an orca-docker environment is one container per workspace and one agent per container."
      log "Create another workspace (same recipe) for a second agent; terminal tabs here are fine."
      exit 75
    fi
    truncate -s 0 "$lock"
    printf 'agent=%s pid=%s tab=%s since=%s' "$cmd" "$$" "${ORCA_TAB_ID:-none}" "$(date -u +%FT%TZ)" >&9
    export ORCA_DOCKER_PUBLISH=off
    if [ -z "${ORCA_DOCKER_REPO:-}" ]; then
      ORCA_DOCKER_REPO="$(repo_root)" || ORCA_DOCKER_REPO="$PWD"
      export ORCA_DOCKER_REPO
    fi
    exec /opt/orca-docker/run-agent.sh "$cmd" "$@"
    ;;
esac

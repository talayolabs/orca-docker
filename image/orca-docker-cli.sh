#!/bin/bash
# In-container `orca-docker` command. The container has no access to the host, so publishing
# means dropping a git bundle into /run/orca-docker/outbox and waiting for the host-side
# wrapper to pick it up, fetch it into the host repository, push it and answer with a result file.
#
#   orca-docker publish [--commit MESSAGE] [--auto]   publish the current branch's new commits
#   orca-docker status                                 show base, branch, published state
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
  ""|-h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $cmd" ;;
esac

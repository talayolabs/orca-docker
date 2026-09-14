#!/bin/bash
# One-time repository seeding, run as root via `docker exec` right after the container is
# created. The wrapper has already `docker cp`'d a seed into /run/orca-docker/seed/:
#   repo.bundle   git bundle with HEAD, the host's current branch and (optionally) a commit
#                 holding the host's uncommitted changes under refs/heads/$ORCA_DOCKER_DIRTY_REF
#   repo.tar      plain tarball (non-git directories; publishing is unavailable)
#
# Environment:
#   ORCA_DOCKER_UID / ORCA_DOCKER_GID   owner of the clone
#   ORCA_DOCKER_REPO                    absolute path of the clone (== host worktree path)
#   ORCA_DOCKER_BASE                    host HEAD sha (the base every publish is measured against)
#   ORCA_DOCKER_BASE_BRANCH             host branch name (empty when detached)
#   ORCA_DOCKER_BRANCH                  branch the agent works on (created at BASE)
#   ORCA_DOCKER_ORIGIN                  host repo's origin URL (recorded as `origin`; may be empty)
#   ORCA_DOCKER_DIRTY_REF               name of the throwaway ref carrying uncommitted changes
#   ORCA_DOCKER_SEED_REF                environment mode: the bundle holds only this throwaway branch at BASE
#                                       (no HEAD), so the clone starts from it instead of the bundle's HEAD
set -euo pipefail

uid="${ORCA_DOCKER_UID:-1000}"; gid="${ORCA_DOCKER_GID:-1000}"
repo="${ORCA_DOCKER_REPO:?}"
export HOME="${ORCA_DOCKER_HOME:-$HOME}"
seed=/run/orca-docker/seed

log() { printf '[orca-docker] %s\n' "$*" >&2; }
as_user() { setpriv --reuid="$uid" --regid="$gid" --init-groups "$@"; }

# Create the clone path; every directory created here belongs to the session user.
missing=()
p="$repo"
while [ "$p" != / ] && [ ! -e "$p" ]; do missing+=("$p"); p="$(dirname "$p")"; done
mkdir -p "$repo"
for d in "${missing[@]}"; do chown "$uid:$gid" "$d"; done
chown -R "$uid:$gid" "$seed"

if [ -f "$seed/repo.bundle" ]; then
  base="${ORCA_DOCKER_BASE:?}"
  branch="${ORCA_DOCKER_BRANCH:?}"
  seed_ref="${ORCA_DOCKER_SEED_REF:-}"
  if [ -n "$seed_ref" ]; then
    as_user git clone -q --no-checkout -b "$seed_ref" "$seed/repo.bundle" "$repo"
  else
    as_user git clone -q "$seed/repo.bundle" "$repo"
  fi
  cd "$repo"
  if [ -n "${ORCA_DOCKER_ORIGIN:-}" ]; then
    as_user git remote set-url origin "$ORCA_DOCKER_ORIGIN"
  else
    as_user git remote remove origin
  fi
  if [ -n "${ORCA_DOCKER_BASE_BRANCH:-}" ] && ! as_user git show-ref -q --verify "refs/heads/$ORCA_DOCKER_BASE_BRANCH"; then
    as_user git branch -q "$ORCA_DOCKER_BASE_BRANCH" "$base" 2>/dev/null || true
  fi
  as_user git checkout -q -B "$branch" "$base"
  if [ -n "$seed_ref" ]; then
    as_user git branch -q -D "$seed_ref" 2>/dev/null || true
    as_user git branch -q -rd "origin/$seed_ref" 2>/dev/null || true
    if [ -n "${ORCA_DOCKER_ORIGIN:-}" ] && [ -n "${ORCA_DOCKER_BASE_BRANCH:-}" ]; then
      as_user git update-ref "refs/remotes/origin/$ORCA_DOCKER_BASE_BRANCH" "$base"
      as_user git branch -q --set-upstream-to="origin/$ORCA_DOCKER_BASE_BRANCH" "$ORCA_DOCKER_BASE_BRANCH" 2>/dev/null || true
    fi
  fi
  dirty="${ORCA_DOCKER_DIRTY_REF:-orca-docker-seed-dirty}"
  if as_user git show-ref -q --verify "refs/remotes/origin/$dirty"; then
    # Replay the host's uncommitted changes as uncommitted changes (tracked + untracked, no ignored files).
    as_user git read-tree --reset -u "refs/remotes/origin/$dirty"
    as_user git reset -q "$base"
    as_user git branch -q -rd "origin/$dirty"
    log "carried over the host's uncommitted changes"
  fi
  as_user mkdir -p .git/orca-docker
  printf '%s\n' "$base" | as_user tee .git/orca-docker/base >/dev/null
  printf '%s\n' "${ORCA_DOCKER_BASE_BRANCH:-}" | as_user tee .git/orca-docker/base-branch >/dev/null
  log "repository ready at $repo on branch $branch (base $(as_user git rev-parse --short "$base"))"
elif [ -f "$seed/repo.tar" ]; then
  as_user tar -xf "$seed/repo.tar" -C "$repo"
  log "directory copied to $repo (not a git repository: publishing disabled)"
else
  log "no seed found in $seed; $repo left empty"
fi
rm -rf "$seed"

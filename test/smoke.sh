#!/usr/bin/env bash
# End-to-end smoke test for orca-docker. Requires docker + node + git on the host; ~3 min.
#   ./test/smoke.sh                 # uses the image tagged ghcr.io/talayolabs/orca-docker:latest (built if missing)
#   SMOKE_BUILD=1 ./test/smoke.sh   # force a rebuild first
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/bin/orca-docker"
IMAGE="${ORCA_DOCKER_DEFAULT_IMAGE:-ghcr.io/talayolabs/orca-docker:latest}"
export ORCA_DOCKER_DEFAULT_IMAGE="$IMAGE"
export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@localhost GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@localhost

pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; FAILED=1; }
FAILED=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/orca-docker-smoke.XXXXXX")"
RUN_ID="$$"
TAB="smoke-${RUN_ID}"
cleanup() {
  [ -n "${HOOK_PID:-}" ] && kill "$HOOK_PID" 2>/dev/null || true
  docker ps -aq --filter "label=orca-docker.session=${TAB}" --filter "label=orca-docker.session=${TAB}-a" \
    --filter "label=orca-docker.session=${TAB}-b" --filter "label=orca-docker.session=${TAB}-local" \
    --filter "label=orca-docker.session=${TAB}-exit" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== syntax"
bash -n "$WRAPPER" "$ROOT"/image/*.sh && pass "bash -n"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$WRAPPER" "$ROOT"/image/*.sh "$ROOT/test/smoke.sh" "$ROOT"/test/fixtures/*.sh && pass shellcheck || fail shellcheck
fi
node --check "$ROOT/image/mcp/computer-use/server.mjs" && pass "node --check mcp"

echo "== image"
if [ "${SMOKE_BUILD:-0}" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -q -t "$IMAGE" "$ROOT/image" >/dev/null && pass "built $IMAGE"
else
  pass "using existing $IMAGE"
fi

echo "== fixtures"
# Fake host: isolated HOME with Orca-style hook script + endpoint file, a Claude login file, and
# a fake Orca hook listener on the host loopback.
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.orca/agent-hooks" "$FAKE_HOME/.config/orca/agent-hooks" "$FAKE_HOME/.claude"
cp "$ROOT/test/fixtures/orca-hook.sh" "$FAKE_HOME/.orca/agent-hooks/orca-claude-hook.sh"
chmod 755 "$FAKE_HOME/.orca/agent-hooks/orca-claude-hook.sh"
echo '{"smoke":true}' > "$FAKE_HOME/.claude.json"
echo '{"claudeAiOauth":{"accessToken":"smoke-not-a-real-token"}}' > "$FAKE_HOME/.claude/.credentials.json"
chmod 600 "$FAKE_HOME/.claude/.credentials.json"
printf '[user]\n\tname = smoke\n\temail = smoke@localhost\n' > "$FAKE_HOME/.gitconfig"

HOOK_PORT="$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
HOOK_LOG="$TMP/hooks.jsonl"; : > "$HOOK_LOG"
node "$ROOT/test/fixtures/hook-server.mjs" "$HOOK_PORT" "$HOOK_LOG" >/dev/null &
HOOK_PID=$!
ENDPOINT="$FAKE_HOME/.config/orca/agent-hooks/endpoint.env"
cat > "$ENDPOINT" <<EOF
ORCA_AGENT_HOOK_PORT=$HOOK_PORT
ORCA_AGENT_HOOK_TOKEN=smoke-token
ORCA_AGENT_HOOK_ENV=smoke
ORCA_AGENT_HOOK_VERSION=1
ORCA_AGENT_HOOK_TRANSPORT=raw-json-v1
EOF

# Fake project: a repo with a local bare "origin" (stands in for GitHub), an npm lockfile,
# one committed file plus an uncommitted tracked change and an untracked file.
ORIGIN="$TMP/origin.git"
git init -q --bare -b main "$ORIGIN"
WORKTREE="$TMP/project"
git init -q -b main "$WORKTREE"
cat > "$WORKTREE/package.json" <<'EOF'
{ "name": "smoke", "version": "1.0.0", "private": true }
EOF
(cd "$WORKTREE" && npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null 2>&1)
printf 'node_modules/\n' > "$WORKTREE/.gitignore"
echo "hello" > "$WORKTREE/README.md"
git -C "$WORKTREE" add -A && git -C "$WORKTREE" commit -qm init
git -C "$WORKTREE" remote add origin "$ORIGIN"
git -C "$WORKTREE" push -q origin main
BASE="$(git -C "$WORKTREE" rev-parse HEAD)"
echo "uncommitted edit" >> "$WORKTREE/README.md"
echo "untracked" > "$WORKTREE/notes.txt"
HOST_STATUS_BEFORE="$(git -C "$WORKTREE" status --porcelain)"
pass "fixture project ready (base ${BASE:0:7})"

echo "== first launch: clone-in, desktop, MCP, hook, publish"
cp "$ROOT/test/fixtures/mcp-check.mjs" "$TMP/mcp-check.mjs"
cat > "$TMP/in-container.sh" <<EOF
set -u
r=0
check() { if "\$@" >/dev/null 2>&1; then echo "  ok   \$1 \${2:-}"; else echo "  FAIL \$*"; r=1; fi; }
check test "\$(id -u)" = "$(id -u)"
check test "\$HOME" = "$FAKE_HOME"
check test "\$PWD" = "$WORKTREE"
check test "\$ORCA_TAB_ID" = "$TAB"
check test "\$ORCA_PANE_KEY" = "pane-1"
check test "\$(git symbolic-ref --short HEAD)" = "orca/$TAB"
check test "\$(git rev-parse HEAD)" = "$BASE"
check test "\$(git remote get-url origin)" = "$ORIGIN"
check grep -q "uncommitted edit" README.md
check test -f notes.txt
check test -f node_modules/.orca-docker-lockhash
check test -f "\$HOME/.claude.json"
check test -f "\$HOME/.claude/.credentials.json"
check test "\$(git config user.email)" = smoke@localhost
check claude --version
check xdpyinfo
check sh -c 'scrot /tmp/shot.png && test -s /tmp/shot.png'
check curl -fsS "http://127.0.0.1:\${ORCA_DOCKER_NOVNC_PORT}/vnc.html"
check sh -c 'wmctrl -l | grep -q xfce4-panel'
timeout 60 chromium-wrapper --headless=new --disable-gpu --screenshot=/tmp/chromium.png --window-size=800,600 about:blank >/tmp/chromium.log 2>&1
check test -s /tmp/chromium.png; [ -s /tmp/chromium.png ] || tail -5 /tmp/chromium.log
printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"smoke-session","cwd":"%s"}' "\$PWD" \\
  | sh "\$HOME/.orca/agent-hooks/orca-claude-hook.sh" >/dev/null && echo "  ok   hook script ran"
check test -r "\$ORCA_AGENT_HOOK_ENDPOINT"
check sudo -n true
# publish flow: explicit publish, then the MCP tool, then one more commit left for auto-publish on exit
echo "from the session" > feature.txt && git add feature.txt && git commit -qm "add feature from session"
check orca-docker publish
echo "mcp" > mcp.txt
check node "$TMP/mcp-check.mjs" --publish
echo "more" >> feature.txt && git commit -qam "second commit (auto-published on exit)"
touch "\$HOME/.persisted-marker"
exit \$r
EOF

set +e
HOME="$FAKE_HOME" \
ORCA_TAB_ID="$TAB" ORCA_PANE_KEY=pane-1 ORCA_WORKTREE_ID=wt-1 ORCA_AGENT_LAUNCH_TOKEN=launch-1 \
ORCA_AGENT_HOOK_PORT="$HOOK_PORT" ORCA_AGENT_HOOK_TOKEN=smoke-token ORCA_AGENT_HOOK_ENV=smoke \
ORCA_AGENT_HOOK_VERSION=1 ORCA_AGENT_HOOK_TRANSPORT=raw-json-v1 ORCA_AGENT_HOOK_ENDPOINT="$ENDPOINT" \
ORCA_DOCKER_SEED="$TMP/in-container.sh $TMP/mcp-check.mjs" \
  bash -c "cd '$WORKTREE' && timeout 300 '$WRAPPER' bash '$TMP/in-container.sh' </dev/null" 2>&1 | tee "$TMP/first.log"
INNER=${PIPESTATUS[0]}
set -e
[ "$INNER" = 0 ] && pass "in-container checks" || fail "in-container checks (exit $INNER)"

echo "== host-side assertions"
CONTAINER="orca-docker-${TAB}"
if grep -q '"url":"/hook/claude"' "$HOOK_LOG" && grep -q 'smoke-session' "$HOOK_LOG" \
   && grep -q '"x-orca-agent-hook-token":"smoke-token"' "$HOOK_LOG"; then
  pass "hook POST reached host listener with token + payload"
else
  fail "hook POST not received: $(cat "$HOOK_LOG")"
fi
[ "$(git -C "$WORKTREE" status --porcelain)" = "$HOST_STATUS_BEFORE" ] && pass "host worktree untouched (same uncommitted changes)" \
  || fail "host worktree changed: $(git -C "$WORKTREE" status --porcelain)"
[ ! -e "$WORKTREE/feature.txt" ] && [ ! -d "$WORKTREE/node_modules" ] && pass "session files and node_modules did not leak to the host" \
  || fail "session files leaked into the host worktree"
[ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$BASE" ] && pass "host HEAD unchanged" || fail "host HEAD moved"
[ -z "$(git -C "$WORKTREE" for-each-ref 'refs/heads/orca-docker-seed-dirty*')" ] && pass "temporary seed ref cleaned up" || fail "temporary seed ref left on host"
n="$(git -C "$WORKTREE" rev-list --count "$BASE..orca/$TAB" 2>/dev/null || echo 0)"
[ "$n" = 3 ] && pass "local branch orca/$TAB has the 3 session commits (publish, MCP publish, auto-publish on exit)" || fail "local branch has $n commits, expected 3"
git -C "$WORKTREE" show "orca/$TAB:mcp.txt" >/dev/null 2>&1 && pass "MCP publish tool committed + published mcp.txt" || fail "mcp.txt missing from published branch"
n="$(git -C "$ORIGIN" rev-list --count "$BASE..orca/$TAB" 2>/dev/null || echo 0)"
[ "$n" = 3 ] && pass "branch pushed to origin (3 commits)" || fail "origin has $n commits, expected 3"
grep -q "published orca/$TAB" "$TMP/first.log" && pass "wrapper announced the published branch in the pane" || fail "no publish announcement in wrapper output"
state="$(docker container inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo absent)"
[ "$state" = exited ] && pass "container kept after exit (state: $state)" || fail "container state after exit: $state"
docker container inspect -f '{{.HostConfig.AutoRemove}} {{len .Mounts}}' "$CONTAINER" | grep -q '^false 0$' && pass "no --rm, no mounts" || fail "AutoRemove/mounts: $(docker container inspect -f '{{.HostConfig.AutoRemove}} {{.Mounts}}' "$CONTAINER")"
"$WRAPPER" --sessions | grep -q "$CONTAINER" && pass "--sessions lists it" || fail "--sessions does not list $CONTAINER"

echo "== relaunch (resume) reuses the same container"
set +e
out="$(cd "$WORKTREE" && HOME="$FAKE_HOME" ORCA_TAB_ID="$TAB" timeout 120 "$WRAPPER" bash -c '
  set -e; test -f "$HOME/.persisted-marker"; test -f feature.txt; test -f node_modules/.orca-docker-lockhash
  test "$(git symbolic-ref --short HEAD)" = "orca/'"$TAB"'"; test "$(git rev-list --count '"$BASE"'..HEAD)" = 3
  orca-docker status | grep -q "unpublished commits: 0"; wmctrl -l | grep -q xfce4-panel; echo RESUMED' </dev/null 2>&1)"
code=$?
set -e
case "$out" in *"resuming session"*RESUMED*) pass "resume: same container, repo/deps/home state intact" ;; *) fail "resume (exit $code): $out" ;; esac

echo "== --rm-session"
"$WRAPPER" --rm-session "$TAB" >/dev/null 2>&1 && ! docker container inspect "$CONTAINER" >/dev/null 2>&1 && pass "removed on request" || fail "--rm-session"

echo "== local-only repository (no origin): publish lands as a host branch"
LOCAL="$TMP/local-project"
git init -q -b main "$LOCAL" && echo a > "$LOCAL/a" && git -C "$LOCAL" add a && git -C "$LOCAL" commit -qm init
set +e
out="$(cd "$LOCAL" && HOME="$FAKE_HOME" ORCA_TAB_ID="${TAB}-local" ORCA_DOCKER_DESKTOP=0 timeout 120 "$WRAPPER" bash -c '
  set -e; ! git remote get-url origin >/dev/null 2>&1; echo b > b; orca-docker publish --commit "add b"' </dev/null 2>&1)"
code=$?
set -e
[ "$code" = 0 ] && git -C "$LOCAL" show "orca/${TAB}-local:b" >/dev/null 2>&1 && pass "branch orca/${TAB}-local fetched into the local repo" \
  || fail "local publish (exit $code): $out"
case "$out" in *"published orca/${TAB}-local"*) pass "publish announced" ;; *) fail "no announcement: $out" ;; esac
"$WRAPPER" --rm-session "${TAB}-local" >/dev/null 2>&1 || true

echo "== concurrent tabs"
# Two sessions started the same way get the same in-container PIDs; with host networking they
# share the abstract socket namespace, so anything listening there by PID collides.
set +e
TAB_PIDS=""
for t in a b; do
  (cd "$WORKTREE" && HOME="$FAKE_HOME" ORCA_TAB_ID="${TAB}-$t" ORCA_DOCKER_AUTO_INSTALL=0 \
    timeout 120 "$WRAPPER" bash -c 'for _ in $(seq 1 100); do wmctrl -l 2>/dev/null | grep -q xfce4-panel && exit 0; sleep 0.2; done; exit 1' \
    </dev/null >"$TMP/tab-$t.log" 2>&1; echo $? >"$TMP/tab-$t.code") &
  TAB_PIDS="$TAB_PIDS $!"
done
# shellcheck disable=SC2086
wait $TAB_PIDS
set -e
for t in a b; do
  [ "$(cat "$TMP/tab-$t.code")" = 0 ] && pass "concurrent tab $t has a desktop" || fail "concurrent tab $t: no window manager ($(tail -3 "$TMP/tab-$t.log" | tr '\n' ' '))"
  "$WRAPPER" --rm-session "${TAB}-$t" >/dev/null 2>&1 || true
done

echo "== exit status + args pass-through"
set +e
out="$(cd "$WORKTREE" && HOME="$FAKE_HOME" ORCA_TAB_ID="${TAB}-exit" ORCA_DOCKER_DESKTOP=0 ORCA_DOCKER_AUTO_INSTALL=0 ORCA_DOCKER_PUBLISH=off \
  "$WRAPPER" bash -c 'printf "%s|" "$@"; exit 7' -- --resume abc-123 "two words" </dev/null 2>/dev/null)"
code=$?
set -e
[ "$code" = 7 ] && pass "exit status forwarded (7)" || fail "exit status: got $code"
[ "$out" = "--resume|abc-123|two words|" ] && pass "args forwarded verbatim" || fail "args: got '$out'"
"$WRAPPER" --rm-session "${TAB}-exit" >/dev/null 2>&1 || true

echo "== --print-config"
cfg="$(cd "$WORKTREE" && HOME="$FAKE_HOME" ORCA_TAB_ID=cfg "$WRAPPER" --print-config claude --model opus)"
for want in "docker create" "--network host" "--name orca-docker-cfg" "orca-docker.branch=orca/cfg" "docker exec" "-w $WORKTREE" "claude --model opus"; do
  case "$cfg" in *"$want"*) pass "config has '$want'" ;; *) fail "config missing '$want'" ;; esac
done
case "$cfg" in *" -v "*|*"--mount"*|*"--rm "*) fail "config mounts host paths or uses --rm" ;; *) pass "config has no -v/--mount/--rm" ;; esac

echo "== --gc"
"$WRAPPER" --gc >/dev/null 2>&1 && pass "gc runs"

if [ "$FAILED" = 0 ]; then echo "ALL PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi

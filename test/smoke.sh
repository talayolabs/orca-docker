#!/usr/bin/env bash
# End-to-end smoke test for orca-docker. Requires docker + node on the host; ~2 min.
#   ./test/smoke.sh            # uses the image tagged ghcr.io/talayolabs/orca-docker:latest (built if missing)
#   SMOKE_BUILD=1 ./test/smoke.sh   # force a rebuild first
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/bin/orca-docker"
IMAGE="${ORCA_DOCKER_DEFAULT_IMAGE:-ghcr.io/talayolabs/orca-docker:latest}"
export ORCA_DOCKER_DEFAULT_IMAGE="$IMAGE"

pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; FAILED=1; }
FAILED=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/orca-docker-smoke.XXXXXX")"
cleanup() {
  [ -n "${HOOK_PID:-}" ] && kill "$HOOK_PID" 2>/dev/null || true
  docker rm -f "orca-docker-smoke-${RUN_ID}" "orca-docker-smoke-${RUN_ID}-a" "orca-docker-smoke-${RUN_ID}-b" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
RUN_ID="$$"

echo "== syntax"
bash -n "$WRAPPER" "$ROOT/image/session.sh" "$ROOT/image/entrypoint.sh" && pass "bash -n"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$WRAPPER" "$ROOT"/image/*.sh && pass shellcheck || fail shellcheck
fi
node --check "$ROOT/image/mcp/computer-use/server.mjs" && pass "node --check mcp"

echo "== image"
if [ "${SMOKE_BUILD:-0}" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -q -t "$IMAGE" "$ROOT/image" >/dev/null && pass "built $IMAGE"
else
  pass "using existing $IMAGE"
fi

echo "== fixtures"
# Fake host: isolated HOME with Orca-style hook script + endpoint file, fake Orca hook listener.
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.orca/agent-hooks" "$FAKE_HOME/.config/orca/agent-hooks"
cp "$ROOT/test/fixtures/orca-hook.sh" "$FAKE_HOME/.orca/agent-hooks/orca-claude-hook.sh"
chmod 755 "$FAKE_HOME/.orca/agent-hooks/orca-claude-hook.sh"

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

# Fake worktree: a git worktree (so the common .git dir lives elsewhere) with an npm lockfile.
MAIN_REPO="$TMP/main-repo"
git init -q "$MAIN_REPO"
git -C "$MAIN_REPO" -c user.email=s@s -c user.name=s commit -q --allow-empty -m init
WORKTREE="$TMP/worktrees/feature"
git -C "$MAIN_REPO" worktree add -q "$WORKTREE"
cat > "$WORKTREE/package.json" <<'EOF'
{ "name": "smoke", "version": "1.0.0", "private": true }
EOF
(cd "$WORKTREE" && npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null 2>&1)
[ -f "$WORKTREE/package-lock.json" ] && pass "fixture worktree ready"

echo "== container run"
cp "$ROOT/test/fixtures/mcp-check.mjs" "$WORKTREE/.mcp-check.mjs"
cat > "$WORKTREE/.in-container.sh" <<EOF
set -u
r=0
check() { if "\$@" >/dev/null 2>&1; then echo "  ok   \$1 \${2:-}"; else echo "  FAIL \$*"; r=1; fi; }
check test "\$(id -u)" = "$(id -u)"
check test "\$HOME" = "$FAKE_HOME"
check test "\$PWD" = "$WORKTREE"
check test "\$ORCA_TAB_ID" = "smoke-${RUN_ID}"
check test "\$ORCA_PANE_KEY" = "pane-1"
check claude --version
check git status
check git log --oneline -1
check test -f node_modules/.orca-docker-lockhash
check xdpyinfo
check sh -c 'scrot /tmp/shot.png && test -s /tmp/shot.png'
check curl -fsS "http://127.0.0.1:\${ORCA_DOCKER_NOVNC_PORT}/vnc.html"
check sh -c 'wmctrl -l | grep -q xfce4-panel'
timeout 60 chromium-wrapper --headless=new --disable-gpu --screenshot=/tmp/chromium.png --window-size=800,600 about:blank >/tmp/chromium.log 2>&1
check test -s /tmp/chromium.png; [ -s /tmp/chromium.png ] || tail -5 /tmp/chromium.log
check node .mcp-check.mjs
printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"smoke-session","cwd":"%s"}' "\$PWD" \\
  | sh "\$HOME/.orca/agent-hooks/orca-claude-hook.sh" >/dev/null && echo "  ok   hook script ran"
check test -w "\$(dirname "\$ORCA_AGENT_HOOK_ENDPOINT")"
check sudo -n true
exit \$r
EOF

set +e
HOME="$FAKE_HOME" \
ORCA_TAB_ID="smoke-${RUN_ID}" ORCA_PANE_KEY=pane-1 ORCA_WORKTREE_ID=wt-1 ORCA_AGENT_LAUNCH_TOKEN=launch-1 \
ORCA_AGENT_HOOK_PORT="$HOOK_PORT" ORCA_AGENT_HOOK_TOKEN=smoke-token ORCA_AGENT_HOOK_ENV=smoke \
ORCA_AGENT_HOOK_VERSION=1 ORCA_AGENT_HOOK_TRANSPORT=raw-json-v1 ORCA_AGENT_HOOK_ENDPOINT="$ENDPOINT" \
  bash -c "cd '$WORKTREE' && timeout 240 '$WRAPPER' bash .in-container.sh </dev/null"
INNER=$?
set -e
[ "$INNER" = 0 ] && pass "in-container checks" || fail "in-container checks (exit $INNER)"

echo "== host-side assertions"
if grep -q '"url":"/hook/claude"' "$HOOK_LOG" && grep -q 'smoke-session' "$HOOK_LOG" \
   && grep -q '"x-orca-agent-hook-token":"smoke-token"' "$HOOK_LOG"; then
  pass "hook POST reached host listener with token + payload"
else
  fail "hook POST not received: $(cat "$HOOK_LOG")"
fi
[ -f "$WORKTREE/node_modules/.orca-docker-lockhash" ] && pass "node_modules installed into worktree (host-visible)"
[ -d "$FAKE_HOME/.claude" ] && [ -f "$FAKE_HOME/.claude.json" ] && pass "claude state dirs created on host"

echo "== concurrent tabs"
# Two sessions started the same way get the same in-container PIDs; with host networking they
# share the abstract socket namespace, so anything listening there by PID collides.
set +e
TAB_PIDS=""
for t in a b; do
  (cd "$WORKTREE" && HOME="$FAKE_HOME" ORCA_TAB_ID="smoke-${RUN_ID}-$t" ORCA_DOCKER_AUTO_INSTALL=0 \
    timeout 120 "$WRAPPER" bash -c 'for _ in $(seq 1 100); do wmctrl -l 2>/dev/null | grep -q xfce4-panel && exit 0; sleep 0.2; done; exit 1' \
    </dev/null >"$TMP/tab-$t.log" 2>&1; echo $? >"$TMP/tab-$t.code") &
  TAB_PIDS="$TAB_PIDS $!"
done
# shellcheck disable=SC2086
wait $TAB_PIDS
set -e
for t in a b; do
  [ "$(cat "$TMP/tab-$t.code")" = 0 ] && pass "concurrent tab $t has a desktop" || fail "concurrent tab $t: no window manager ($(tail -3 "$TMP/tab-$t.log" | tr '\n' ' '))"
done

echo "== exit status + args pass-through"
set +e
out="$(cd "$WORKTREE" && HOME="$FAKE_HOME" ORCA_DOCKER_DESKTOP=0 ORCA_DOCKER_AUTO_INSTALL=0 \
  "$WRAPPER" bash -c 'printf "%s|" "$@"; exit 7' -- --resume abc-123 "two words" </dev/null 2>/dev/null)"
code=$?
set -e
[ "$code" = 7 ] && pass "exit status forwarded (7)" || fail "exit status: got $code"
[ "$out" = "--resume|abc-123|two words|" ] && pass "args forwarded verbatim" || fail "args: got '$out'"

echo "== --print-config"
cfg="$(cd "$WORKTREE" && HOME="$FAKE_HOME" ORCA_TAB_ID=cfg "$WRAPPER" --print-config claude --model opus)"
for want in "--network host" "-v $WORKTREE:$WORKTREE" "-v $MAIN_REPO/.git:$MAIN_REPO/.git" "--name orca-docker-cfg" "claude --model opus"; do
  case "$cfg" in *"$want"*) pass "config has '$want'" ;; *) fail "config missing '$want'" ;; esac
done

echo "== --gc"
"$WRAPPER" --gc >/dev/null 2>&1 && pass "gc runs"

if [ "$FAILED" = 0 ]; then echo "ALL PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi

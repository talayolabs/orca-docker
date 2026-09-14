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
  docker ps -aq --filter "label=orca-docker.instance=orca-smoke-${RUN_ID}-1" --filter "label=orca-docker.instance=orca-smoke-${RUN_ID}-2" \
    | xargs -r docker rm -f >/dev/null 2>&1 || true
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
# skills dir with a symlink escaping the tree (docker cp rejects these) + a dangling one
mkdir -p "$FAKE_HOME/.agents/skills/ext" "$FAKE_HOME/.claude/skills"
echo 'ext skill' > "$FAKE_HOME/.agents/skills/ext/SKILL.md"
ln -s ../../.agents/skills/ext "$FAKE_HOME/.claude/skills/ext"
ln -s ../../nowhere "$FAKE_HOME/.claude/skills/dangling"
# hooks referenced from settings.json must come along; per-session state must not
mkdir -p "$FAKE_HOME/.claude/hooks" "$FAKE_HOME/.claude/projects/-tmp-x"
echo 'console.log("hook")' > "$FAKE_HOME/.claude/hooks/on-stop.js"
echo '{}' > "$FAKE_HOME/.claude/projects/-tmp-x/transcript.jsonl"
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
check test "\$(cat \$HOME/.claude/skills/ext/SKILL.md)" = 'ext skill'
check test ! -L "\$HOME/.claude/skills/ext"
check test -f "\$HOME/.claude/hooks/on-stop.js"
check test ! -e "\$HOME/.claude/projects/-tmp-x"
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

echo "== shell / desktop into the worktree's container (from a plain terminal, no ORCA_TAB_ID)"
set +e
out="$(cd "$WORKTREE" && HOME="$FAKE_HOME" timeout 120 "$WRAPPER" shell -c 'echo "SHELL_OK $(pwd) ${DISPLAY:-nodisplay} $(git symbolic-ref --short HEAD)"' </dev/null 2>"$TMP/shell.err")"
code=$?
set -e
[ "$code" = 0 ] && [ "$out" = "SHELL_OK $WORKTREE $(docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" | sed -n 's/^DISPLAY=//p') orca/$TAB" ] \
  && pass "shell: found the stopped container by worktree, started it, login shell at the clone with DISPLAY" \
  || fail "shell (exit $code): '$out' $(cat "$TMP/shell.err")"
[ "$(docker container inspect -f '{{.State.Status}}' "$CONTAINER")" = exited ] && pass "shell: container stopped again after the shell it woke up" || fail "shell left the container running"
NOVNC_PORT="$(docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" | sed -n 's/^ORCA_DOCKER_NOVNC_PORT=//p')"
URL="http://127.0.0.1:${NOVNC_PORT}/vnc.html?autoconnect=1&resize=scale"
set +e
out="$(cd "$WORKTREE" && HOME="$FAKE_HOME" PATH="/usr/bin:/bin" timeout 120 "$WRAPPER" desktop </dev/null 2>"$TMP/desktop.err")"
code=$?
set -e
[ "$code" = 0 ] && [ "$out" = "$URL" ] && grep -q "orca CLI not on PATH" "$TMP/desktop.err" && pass "desktop: prints the noVNC URL, explains the missing orca CLI" \
  || fail "desktop (exit $code): '$out' $(cat "$TMP/desktop.err")"
[ "$(docker container inspect -f '{{.State.Status}}' "$CONTAINER")" = running ] && pass "desktop: container left running for the desktop" || fail "desktop: container not running"
curl -fsS -m 10 "http://127.0.0.1:${NOVNC_PORT}/vnc.html" | grep -qi novnc && pass "desktop: noVNC answers on the printed port" || fail "noVNC not reachable on $NOVNC_PORT"
mkdir -p "$TMP/fake-orca"
cat > "$TMP/fake-orca/orca" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_ORCA_LOG"; exit "${FAKE_ORCA_EXIT:-0}"
EOF
chmod +x "$TMP/fake-orca/orca"
rm -f "$TMP/fake-orca.log"
out="$(cd "$WORKTREE" && HOME="$FAKE_HOME" PATH="$TMP/fake-orca:$PATH" FAKE_ORCA_LOG="$TMP/fake-orca.log" "$WRAPPER" desktop "$TAB" </dev/null 2>"$TMP/desktop.err")"
[ "$out" = "$URL" ] && [ "$(cat "$TMP/fake-orca.log")" = "tab create --url $URL --worktree active" ] && grep -q "opened in Orca's browser pane" "$TMP/desktop.err" \
  && pass "desktop <tab>: opens the URL in Orca's worktree browser through the orca CLI" || fail "desktop via orca CLI: '$out' log='$(cat "$TMP/fake-orca.log" 2>/dev/null)' $(cat "$TMP/desktop.err")"
out="$(cd "$WORKTREE" && HOME="$FAKE_HOME" PATH="$TMP/fake-orca:$PATH" FAKE_ORCA_LOG="$TMP/fake-orca.log" FAKE_ORCA_EXIT=3 "$WRAPPER" desktop "$CONTAINER" </dev/null 2>"$TMP/desktop.err")"
[ "$out" = "$URL" ] && grep -q "could not open a browser tab" "$TMP/desktop.err" && pass "desktop <container>: falls back to the URL when the orca CLI fails" || fail "desktop fallback: '$out' $(cat "$TMP/desktop.err")"
out="$(docker exec -u "$(id -un)" -e HOME="$FAKE_HOME" "$CONTAINER" bash -lc 'orca-docker desktop --print' 2>"$TMP/desktop.err")"
[ "$out" = "$URL" ] && pass "in-container 'orca-docker desktop --print' gives the same URL" || fail "in-container desktop --print: '$out' $(cat "$TMP/desktop.err")"
out="$(docker exec -i -u "$(id -un)" -e HOME="$FAKE_HOME" "$CONTAINER" bash -lc '
  d=$(mktemp -d); cat > "$d/orca"; chmod +x "$d/orca"
  ORCA_REMOTE_CLI_BIN_DIR=$d orca-docker desktop >/dev/null 2>&1; cat "$d/log"' 2>&1 <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$(dirname "$0")/log"
EOF
)"
[ "$out" = "tab create --url $URL --worktree active" ] && pass "in-container desktop uses Orca's remote CLI (ORCA_REMOTE_CLI_BIN_DIR) to open the worktree browser" || fail "in-container desktop via remote CLI: '$out'"
docker stop -t 5 "$CONTAINER" >/dev/null

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
done
set +e
out="$(cd "$WORKTREE" && HOME="$FAKE_HOME" "$WRAPPER" shell -c 'echo picked' </dev/null 2>&1)"
code=$?
set -e
[ "$code" != 0 ] && case "$out" in *"several session containers"*"${TAB}-a"*"${TAB}-b"*) pass "shell: two stopped containers for the worktree -> refuses to guess, lists both" ;; *) false ;; esac \
  || fail "shell ambiguity (exit $code): $out"
out="$(cd "$WORKTREE" && HOME="$FAKE_HOME" timeout 120 "$WRAPPER" shell "${TAB}-b" -c 'hostname' </dev/null 2>/dev/null)"
[ -n "$out" ] && [ "$out" = "$(docker container inspect -f '{{.Config.Hostname}}' "orca-docker-${TAB}-b")" ] \
  && pass "shell <tab>: explicit tab id enters that container" || fail "shell <tab>: got '$out'"
for t in a b; do "$WRAPPER" --rm-session "${TAB}-$t" >/dev/null 2>&1 || true; done
set +e
out="$(cd "$WORKTREE" && HOME="$FAKE_HOME" "$WRAPPER" shell </dev/null 2>&1)"
code=$?
set -e
[ "$code" != 0 ] && case "$out" in *"no session container for this worktree"*) pass "shell: clear error when the worktree has no container" ;; *) false ;; esac \
  || fail "shell without container (exit $code): $out"

echo "== exit status + args pass-through"
set +e
out="$(cd "$WORKTREE" && HOME="$FAKE_HOME" ORCA_TAB_ID="${TAB}-exit" ORCA_DOCKER_DESKTOP=0 ORCA_DOCKER_AUTO_INSTALL=0 ORCA_DOCKER_PUBLISH=off \
  "$WRAPPER" bash -c 'printf "%s|" "$@"; exit 7' -- --resume abc-123 "two words" </dev/null 2>/dev/null)"
code=$?
set -e
[ "$code" = 7 ] && pass "exit status forwarded (7)" || fail "exit status: got $code"
[ "$out" = "--resume|abc-123|two words|" ] && pass "args forwarded verbatim" || fail "args: got '$out'"
"$WRAPPER" --rm-session "${TAB}-exit" >/dev/null 2>&1 || true

echo "== environment mode (Orca per-workspace recipe): create"
export ORCA_DOCKER_STATE_DIR="$TMP/state"
ENV_INST="orca-smoke-${RUN_ID}-1"
KH="$FAKE_HOME/.ssh/known_hosts"   # strict: the wrapper must have recorded the container's key here, like Orca expects
ssh_env() {  # ssh_env <result.json> <command...>
  local res="$1"; shift
  local port key user
  port="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).connection.target.port' "$res")"
  key="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).connection.target.identityFile' "$res")"
  user="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).connection.target.username' "$res")"
  ssh -q -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KH" -o IdentitiesOnly=yes \
      -i "$key" -p "$port" "$user@127.0.0.1" "$@"
}
# The pinned commit exists only on the remote (someone pushed to main): the recipe must fetch it
# from the ORCA_REPO_URL/ORCA_REPO_REF pair, not fail or fall back to the local HEAD.
git clone -q "$ORIGIN" "$TMP/pusher" && echo upstream > "$TMP/pusher/upstream.txt" && git -C "$TMP/pusher" add upstream.txt \
  && git -C "$TMP/pusher" commit -qm "upstream change" && git -C "$TMP/pusher" push -q origin main
PIN="$(git -C "$TMP/pusher" rev-parse HEAD)"
! git -C "$WORKTREE" cat-file -e "$PIN" 2>/dev/null && pass "fixture: pinned commit ${PIN:0:7} is not in the host checkout yet"
set +e
# Run from an unrelated cwd: the recipe must use ORCA_REPO_PATH, and Orca's pinned commit/branch.
(cd "$TMP" && HOME="$FAKE_HOME" ORCA_VM_MODE=create ORCA_VM_INSTANCE_ID="$ENV_INST" ORCA_RECIPE_ID=orca-docker \
  ORCA_PROJECT_ID=proj-1 ORCA_WORKSPACE_ID=ws-1 ORCA_WORKSPACE_NAME="Feature X" ORCA_REPO_PATH="$WORKTREE" \
  ORCA_REPO_URL="$ORIGIN" ORCA_REPO_BRANCH="feat/x" ORCA_REPO_REF=main ORCA_REPO_REF_HEAD="$PIN" \
  ORCA_RECIPE_RESULT_SCHEMA_VERSION=2 ORCA_VERSION=smoke ORCA_DOCKER_AUTO_INSTALL=0 \
  timeout 300 "$WRAPPER" env create >"$TMP/env1.json" 2>"$TMP/env1.log")
code=$?
set -e
[ "$code" = 0 ] && pass "env create exited 0" || { fail "env create exit $code: $(tail -5 "$TMP/env1.log")"; }
[ "$(wc -l <"$TMP/env1.json")" = 1 ] && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$TMP/env1.json" 2>/dev/null \
  && pass "stdout is exactly one JSON result (all chatter on stderr)" || fail "stdout not a single JSON line: $(head -c 300 "$TMP/env1.json")"
ENV_CONTAINER="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).userData.container' "$TMP/env1.json")"
node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const [root, user] = [process.argv[2], process.argv[3]]; const t = r.connection.target;
const ok = r.schemaVersion === 2 && r.checkoutMode === "provisioned-root" && r.connection.type === "ssh"
  && r.connection.projectRoot === root && t.host === "127.0.0.1" && Number.isInteger(t.port) && t.username === user
  && t.identitiesOnly === true && require("fs").existsSync(t.identityFile) && t.label.includes("Feature X")
  && Object.keys(t).sort().join() === "host,identitiesOnly,identityFile,label,port,username";
process.exit(ok ? 0 : 1)' "$TMP/env1.json" "$WORKTREE" "$(id -un)" \
  && pass "result: schemaVersion 2, provisioned-root, ssh target on 127.0.0.1 with identity file" || fail "result shape: $(cat "$TMP/env1.json")"
docker container inspect -f '{{.HostConfig.AutoRemove}} {{len .Mounts}} {{.HostConfig.NetworkMode}} {{index .Config.Labels "orca-docker.kind"}}' "$ENV_CONTAINER" 2>/dev/null | grep -q '^false 0 bridge env$' \
  && pass "env container: no --rm, no mounts, bridge network, kind=env" || fail "env container config: $(docker container inspect -f '{{.HostConfig.AutoRemove}} {{len .Mounts}} {{.HostConfig.NetworkMode}}' "$ENV_CONTAINER" 2>&1)"
set +e
out="$(ssh_env "$TMP/env1.json" "cd '$WORKTREE' && printf '%s|%s|%s|%s|%s|' \"\$(git rev-parse HEAD)\" \"\$(git symbolic-ref --short HEAD)\" \"\$(git remote get-url origin)\" \"\$(git rev-parse origin/main)\" \"\$(git status --porcelain | wc -l)\"; test -f notes.txt && printf 'notes|'; bash -lc 'printf %s \"\${DISPLAY:+display}\"'; echo '|'; echo marker > env-marker.txt; command -v claude >/dev/null && echo claude-ok" 2>&1)"
code=$?
set -e
[ "$code" = 0 ] && case "$out" in "$PIN|feat/x|$ORIGIN|$PIN|0|display|"*claude-ok*) pass "ssh in: exact pinned commit on feat/x, origin/main set, clean tree, login shell sees the desktop" ;; *) fail "ssh checks: $out" ;; esac
[ "$code" = 0 ] || fail "ssh into environment failed ($code): $out"
[ "$(git -C "$WORKTREE" status --porcelain)" = "$HOST_STATUS_BEFORE" ] && [ ! -e "$WORKTREE/env-marker.txt" ] && [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$BASE" ] \
  && [ "$(git -C "$WORKTREE" rev-parse main)" = "$BASE" ] && pass "host worktree untouched by the environment (HEAD and main still at ${BASE:0:7})" || fail "host worktree changed"
fp_line="$(ssh-keygen -F "[127.0.0.1]:$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).connection.target.port' "$TMP/env1.json")" -f "$FAKE_HOME/.ssh/known_hosts" 2>/dev/null | grep -v '^#')"
[ -n "$fp_line" ] && pass "container host key recorded in the user's known_hosts for its endpoint" || fail "known_hosts entry missing"
[ -z "$(git -C "$WORKTREE" for-each-ref 'refs/heads/orca-docker-seed*')" ] && pass "temporary seed refs cleaned up" || fail "seed refs left on host: $(git -C "$WORKTREE" for-each-ref 'refs/heads/orca-docker-seed*')"

echo "== environment mode: one agent per workspace"
set +e
ssh_env "$TMP/env1.json" "cd '$WORKTREE' && ORCA_DOCKER_AUTO_INSTALL=0 ORCA_DOCKER_MCP=0 ORCA_TAB_ID=tab-one orca-docker bash -c 'echo AGENT_STARTED; sleep 60'" >"$TMP/agent1.log" 2>&1 &
AGENT1=$!
for _ in $(seq 1 100); do grep -q AGENT_STARTED "$TMP/agent1.log" 2>/dev/null && break; sleep 0.2; done
grep -q AGENT_STARTED "$TMP/agent1.log" && pass "first agent launched" || fail "first agent did not start: $(cat "$TMP/agent1.log")"
out="$(ssh_env "$TMP/env1.json" "cd '$WORKTREE' && ORCA_DOCKER_AUTO_INSTALL=0 ORCA_TAB_ID=tab-two orca-docker bash -c 'echo SECOND_RAN'" 2>&1)"; code=$?
[ "$code" = 75 ] && case "$out" in *"already has a running agent"*"tab=tab-one"*"another workspace"*) pass "second agent refused (exit 75) with a clear message naming the holder" ;; *) fail "second agent message: $out" ;; esac
[ "$code" = 75 ] || fail "second agent exit $code (want 75): $out"
case "$out" in *SECOND_RAN*) fail "second agent actually ran" ;; esac
ssh_env "$TMP/env1.json" "cd '$WORKTREE' && echo SHELL_OK" 2>/dev/null | grep -q SHELL_OK && pass "plain shell still allowed while an agent runs" || fail "plain shell blocked"
kill "$AGENT1" 2>/dev/null; wait "$AGENT1" 2>/dev/null
docker exec "$ENV_CONTAINER" pkill -f 'sleep 60' 2>/dev/null || true
sleep 1
out="$(ssh_env "$TMP/env1.json" "cd '$WORKTREE' && ORCA_DOCKER_AUTO_INSTALL=0 ORCA_DOCKER_MCP=0 orca-docker bash -c 'echo THIRD_RAN'" 2>&1)"; code=$?
set -e
[ "$code" = 0 ] && case "$out" in *THIRD_RAN*) pass "lock released after the agent died: next agent starts" ;; *) fail "third agent: $out" ;; esac
[ "$code" = 0 ] || fail "third agent exit $code: $out"

echo "== environment mode: second environment (folder workspace) gets its own host key"
ENV_INST2="orca-smoke-${RUN_ID}-2"
FOLDER="$TMP/plain-folder"; mkdir -p "$FOLDER" && echo data > "$FOLDER/data.txt"
set +e
(cd "$FOLDER" && HOME="$FAKE_HOME" ORCA_VM_MODE=create ORCA_VM_INSTANCE_ID="$ENV_INST2" ORCA_RECIPE_ID=orca-docker \
  ORCA_WORKSPACE_ID=ws-2 ORCA_WORKSPACE_NAME="folder" ORCA_REPO_PATH="$FOLDER" ORCA_RECIPE_RESULT_SCHEMA_VERSION=1 \
  ORCA_DOCKER_DESKTOP=0 ORCA_DOCKER_AUTO_INSTALL=0 timeout 300 "$WRAPPER" env create >"$TMP/env2.json" 2>"$TMP/env2.log")
code=$?
set -e
[ "$code" = 0 ] && node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.exit(r.schemaVersion===1 && !("checkoutMode" in r) && r.connection.projectRoot===process.argv[2] ? 0 : 1)' "$TMP/env2.json" "$FOLDER" \
  && pass "folder workspace env created (schemaVersion 1, no checkoutMode)" || fail "folder env (exit $code): $(cat "$TMP/env2.json"; tail -3 "$TMP/env2.log")"
ENV_CONTAINER2="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).userData.container' "$TMP/env2.json" 2>/dev/null || true)"
ssh_env "$TMP/env2.json" "cat '$FOLDER/data.txt'" 2>/dev/null | grep -q '^data$' && pass "folder contents present over ssh" || fail "folder contents missing"
fp1="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).userData.hostKeyFingerprint' "$TMP/env1.json")"
fp2="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).userData.hostKeyFingerprint' "$TMP/env2.json")"
[ -n "$fp1" ] && [ "$fp1" != "$fp2" ] && pass "distinct per-container ssh host keys ($fp1 / $fp2)" || fail "host key fingerprints: '$fp1' '$fp2'"
p1="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).connection.target.port' "$TMP/env1.json")"
p2="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).connection.target.port' "$TMP/env2.json")"
[ "$p1" != "$p2" ] && pass "distinct published ssh ports ($p1, $p2)" || fail "ssh port collision: $p1"
k1="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).connection.target.identityFile' "$TMP/env1.json")"
k2="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).connection.target.identityFile' "$TMP/env2.json")"
[ "$k1" != "$k2" ] && [ "$(stat -c %a "$k1")" = 600 ] && pass "distinct client keys, private key mode 600" || fail "client keys: $k1 $k2"
"$WRAPPER" env ls 2>/dev/null | grep -q "$ENV_CONTAINER" && pass "env ls lists the environment" || fail "env ls"
"$WRAPPER" --gc --all >/dev/null 2>&1; docker container inspect "$ENV_CONTAINER2" >/dev/null 2>&1 && pass "--gc --all leaves environments alone" || fail "--gc removed an environment"

echo "== environment mode: suspend / resume / destroy (lifecycle payload on stdin)"
payload() { printf '{"schemaVersion":1,"mode":"%s","recipeId":"orca-docker","instanceId":"%s","projectId":"proj-1","workspaceId":"ws-1","workspaceName":"Feature X","recipeResult":%s}\n' "$1" "$2" "$(cat "$3")"; }
set +e
payload suspend "$ENV_INST" "$TMP/env1.json" | (cd "$TMP" && HOME="$FAKE_HOME" ORCA_VM_MODE=suspend "$WRAPPER" env suspend >"$TMP/suspend.out" 2>"$TMP/suspend.log")
code=$?
set -e
[ "$code" = 0 ] && [ "$(docker container inspect -f '{{.State.Status}}' "$ENV_CONTAINER")" = exited ] && [ ! -s "$TMP/suspend.out" ] \
  && pass "suspend (container found via stdin payload): stopped, kept, silent stdout" || fail "suspend exit $code state $(docker container inspect -f '{{.State.Status}}' "$ENV_CONTAINER" 2>&1): $(cat "$TMP/suspend.log")"
set +e
payload resume "$ENV_INST" "$TMP/env1.json" | (cd "$TMP" && HOME="$FAKE_HOME" ORCA_VM_MODE=resume ORCA_VM_INSTANCE_ID="$ENV_INST" timeout 120 "$WRAPPER" env resume >"$TMP/resume.json" 2>"$TMP/resume.log")
code=$?
set -e
[ "$code" = 0 ] && [ "$(cat "$TMP/resume.json")" = "$(cat "$TMP/env1.json")" ] && pass "resume re-emits the identical connection result" \
  || fail "resume exit $code: $(cat "$TMP/resume.json"; tail -3 "$TMP/resume.log")"
out="$(ssh_env "$TMP/resume.json" "cd '$WORKTREE' && cat env-marker.txt && git symbolic-ref --short HEAD" 2>&1)" \
  && [ "$out" = "$(printf 'marker\nfeat/x')" ] && pass "after resume: same host key accepted, files and branch intact" || fail "after resume: $out"
set +e
payload destroy "$ENV_INST" "$TMP/env1.json" | (cd "$TMP" && HOME="$FAKE_HOME" ORCA_VM_MODE=destroy ORCA_VM_INSTANCE_ID="$ENV_INST" "$WRAPPER" env destroy >/dev/null 2>"$TMP/destroy.log")
code=$?
set -e
[ "$code" = 0 ] && ! docker container inspect "$ENV_CONTAINER" >/dev/null 2>&1 && [ ! -e "$k1" ] && pass "destroy removes the container and its client key" \
  || fail "destroy exit $code: $(tail -3 "$TMP/destroy.log")"
! ssh-keygen -F "[127.0.0.1]:$p1" -f "$FAKE_HOME/.ssh/known_hosts" 2>/dev/null | grep -q '^\[' && ssh-keygen -F "[127.0.0.1]:$p2" -f "$FAKE_HOME/.ssh/known_hosts" 2>/dev/null | grep -q '^\[' \
  && pass "destroy dropped only that endpoint's known_hosts line (other environment's kept)" || fail "known_hosts after destroy: $(cat "$FAKE_HOME/.ssh/known_hosts")"
(cd "$TMP" && HOME="$FAKE_HOME" "$WRAPPER" env destroy "$ENV_CONTAINER2" >/dev/null 2>&1) && ! docker container inspect "$ENV_CONTAINER2" >/dev/null 2>&1 \
  && pass "env destroy <container> by hand" || fail "manual destroy"
(cd "$TMP" && HOME="$FAKE_HOME" ORCA_VM_INSTANCE_ID="$ENV_INST" "$WRAPPER" env destroy </dev/null >/dev/null 2>&1) && pass "destroy of a gone instance is a no-op success" || fail "destroy of gone instance failed"

echo "== --print-config"
cfg="$(cd "$WORKTREE" && HOME="$FAKE_HOME" ORCA_TAB_ID=cfg "$WRAPPER" --print-config claude --model opus)"
for want in "docker create" "--network host" "--name orca-docker-cfg" "orca-docker.branch=orca/cfg" "docker exec" "-w $WORKTREE" "claude --model opus"; do
  case "$cfg" in *"$want"*) pass "config has '$want'" ;; *) fail "config missing '$want'" ;; esac
done
case "$cfg" in *" -v "*|*"--mount"*|*"--rm "*) fail "config mounts host paths or uses --rm" ;; *) pass "config has no -v/--mount/--rm" ;; esac

echo "== --gc"
"$WRAPPER" --gc >/dev/null 2>&1 && pass "gc runs"

if [ "$FAILED" = 0 ]; then echo "ALL PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi

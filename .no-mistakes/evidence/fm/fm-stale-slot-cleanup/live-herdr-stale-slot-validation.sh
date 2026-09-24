#!/usr/bin/env bash
set -euo pipefail

ROOT=/Users/dajijix/.no-mistakes/worktrees/1d0ac733deef/01M3AA72HRK6AC7HY8QAE4S3SQ
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
ORIGINAL_PATH=$PATH
EVIDENCE_DIR=/Users/dajijix/.no-mistakes/evidence/01M3AA72HRK6AC7HY8QAE4S3SQ
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-stale-slot-live.XXXXXX")
SESSION=$($LAB_HELPER name stale-slot-live)
SESSION_OWNED=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status=$?
  if [ "$SESSION_OWNED" = 1 ]; then
    env PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || status=1
  fi
  rm -rf "$SCRATCH"
  exit "$status"
}
trap cleanup EXIT

unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
mkdir -p "$SCRATCH/home/state" "$SCRATCH/home/data" "$SCRATCH/home/config" \
  "$SCRATCH/project" "$SCRATCH/pool/1" "$SCRATCH/fakebin" "$SCRATCH/pi-agent"
HOME_DIR="$SCRATCH/home"
PROJECT="$SCRATCH/project"
WORKTREE="$SCRATCH/worktree"
STALE_ID=stale-mirasim
OWNER_ID=pi-fast-owner

# A private Treehouse-shaped pool slot. No shared or fleet slot is referenced.
git init -q "$PROJECT"
git -C "$PROJECT" -c user.name=test -c user.email=test@example.invalid \
  commit --allow-empty -qm pool-fixture
git -C "$PROJECT" worktree add -q --detach "$SCRATCH/pool/1/project"
ln -s pool/1/project "$WORKTREE"
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
  "$SCRATCH/pool/1/project" > "$SCRATCH/pool/treehouse-state.json"
printf 'owner payload must survive\n' > "$WORKTREE/no-harm-sentinel"
printf 'task=%s\nhome=%s\n' "$OWNER_ID" "$HOME_DIR" > "$SCRATCH/pool/1/.fm-slot-owner"

"$LAB_HELPER" provision "$SESSION"
SESSION_OWNED=1

lab() {
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"
}

# Route every Herdr call made by the product through the guarded named-lab helper.
cat > "$SCRATCH/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$SCRATCH/fakebin/herdr"
export HERDR_LAB_SESSION="$SESSION" HERDR_ORIGINAL_PATH="$ORIGINAL_PATH" HERDR_LAB_HELPER="$LAB_HELPER"

cat > "$SCRATCH/trust.ts" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
}
TS

CREATE=$(lab workspace create --cwd "$PROJECT" --label stale-slot-proof --no-focus)
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id')
STALE_TAB=$(printf '%s' "$CREATE" | jq -er '.result.tab.tab_id')
STALE_PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id')
OWNER_CREATE=$(lab tab create --workspace "$WS" --cwd "$PROJECT" --label owner-endpoint --no-focus)
OWNER_TAB=$(printf '%s' "$OWNER_CREATE" | jq -er '.result.tab.tab_id')
OWNER_PANE=$(printf '%s' "$OWNER_CREATE" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id')

# Build the real crew shape: nested shell, then a real Pi registration.
lab pane run "$STALE_PANE" zsh >/dev/null
sleep 1
PI_CMD=$(printf 'env PI_CODING_AGENT_DIR=%q pi -e %q --no-context-files --no-session' \
  "$SCRATCH/pi-agent" "$SCRATCH/trust.ts")
lab pane run "$STALE_PANE" "$PI_CMD" >/dev/null

STATUS=
for _ in $(seq 1 200); do
  STATUS=$(lab agent get "$STALE_PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' || true)
  case "$STATUS" in working|idle|done|blocked) break ;; esac
  sleep 0.2
done
case "$STATUS" in working|idle|done|blocked) ;; *) fail "Pi never registered in the isolated endpoint" ;; esac

PI_PID=
for _ in $(seq 1 100); do
  PI_PID=$(lab pane process-info --pane "$STALE_PANE" | jq -r '
    .result.process_info.foreground_processes[]?
    | select((.argv0 // "") == "pi" or (.name // "") == "pi")
    | .pid' | head -1)
  [ -n "$PI_PID" ] && break
  sleep 0.2
done
[ -n "$PI_PID" ] || fail "could not resolve the real Pi pid"
kill -TSTP "$PI_PID"

# Wait until the nested shell regains the foreground while Pi remains a suspended descendant.
SHELL_FOREGROUND=0
for _ in $(seq 1 100); do
  INFO=$(lab pane process-info --pane "$STALE_PANE")
  if printf '%s' "$INFO" | jq -e '
      (.result.process_info.foreground_processes | length) > 0 and
      ([.result.process_info.foreground_processes[] | (.argv0 // .name // "")]
       | all(. == "zsh" or . == "bash" or . == "sh" or . == "fish"))' >/dev/null; then
    SHELL_FOREGROUND=1
    break
  fi
  sleep 0.2
done
[ "$SHELL_FOREGROUND" = 1 ] || fail "nested shell did not regain the foreground"
kill -0 "$PI_PID" || fail "suspended Pi process disappeared"
STATUS=$(lab agent get "$STALE_PANE" | jq -er '.result.agent.agent_status')

cat > "$HOME_DIR/state/$STALE_ID.meta" <<EOF
backend=herdr
window=$SESSION:$STALE_PANE
endpoint_task_id=$STALE_ID
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$STALE_TAB
herdr_pane_id=$STALE_PANE
worktree=$WORKTREE
project=$PROJECT
kind=scout
EOF
cat > "$HOME_DIR/state/$OWNER_ID.meta" <<EOF
backend=herdr
window=$SESSION:$OWNER_PANE
endpoint_task_id=$OWNER_ID
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$OWNER_TAB
herdr_pane_id=$OWNER_PANE
worktree=$WORKTREE
project=$PROJECT
kind=scout
EOF

snapshot() {
  shasum -a 256 \
    "$HOME_DIR/state/$STALE_ID.meta" \
    "$HOME_DIR/state/$OWNER_ID.meta" \
    "$SCRATCH/pool/1/.fm-slot-owner" \
    "$WORKTREE/no-harm-sentinel"
}
snapshot > "$SCRATCH/before.sha"
GIT_BEFORE=$(git -C "$WORKTREE" status --porcelain=v1)

# Confirm the product's liveness contract sees this real endpoint as unknown when
# the host process-table capability is unavailable.
UNKNOWN=$(PATH="$SCRATCH/fakebin:$ORIGINAL_PATH" FM_HERDR_PS_BIN="fm-no-such-ps-$$" \
  bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_alive herdr "$2"' \
  _ "$ROOT" "$SESSION:$STALE_PANE")
[ "$UNKNOWN" = unknown ] || fail "staged liveness was '$UNKNOWN', not unknown"

set +e
PATH="$SCRATCH/fakebin:$ORIGINAL_PATH" \
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_GATE_REFUSE_BYPASS=1 \
FM_HERDR_PS_BIN="fm-no-such-ps-$$" \
  "$ROOT/bin/fm-teardown.sh" "$STALE_ID" --force \
  > "$SCRATCH/unknown.stdout" 2> "$SCRATCH/unknown.stderr"
UNKNOWN_RC=$?
set -e
[ "$UNKNOWN_RC" -ne 0 ] || fail "unknown-liveness teardown unexpectedly succeeded"
grep -F "endpoint is active or its liveness is unknown" "$SCRATCH/unknown.stderr" >/dev/null \
  || fail "unknown-liveness refusal was not explicit"
snapshot > "$SCRATCH/after-unknown.sha"
cmp -s "$SCRATCH/before.sha" "$SCRATCH/after-unknown.sha" || fail "unknown-liveness refusal changed protected files"
[ "$(git -C "$WORKTREE" status --porcelain=v1)" = "$GIT_BEFORE" ] || fail "unknown-liveness refusal changed worktree state"
lab pane get "$STALE_PANE" >/dev/null || fail "unknown-liveness refusal removed stale endpoint"
lab pane get "$OWNER_PANE" >/dev/null || fail "unknown-liveness refusal removed owner endpoint"
kill -0 "$PI_PID" || fail "unknown-liveness refusal harmed the suspended Pi process"

printf 'SCENARIO unknown liveness: PASS\n'
printf '  live session: %s (herdr %s)\n' "$SESSION" "$(herdr --version | head -1)"
printf '  real stale endpoint: %s:%s; registered status=%s; suspended pid=%s\n' "$SESSION" "$STALE_PANE" "$STATUS" "$PI_PID"
printf '  product liveness verdict with unavailable process table: %s\n' "$UNKNOWN"
printf '  teardown exit: %s\n' "$UNKNOWN_RC"
printf '  refusal: %s\n' "$(tr '\n' ' ' < "$SCRATCH/unknown.stderr")"
printf '  no harm: both panes and Pi pid present; task records, owner claim, sentinel, and git status byte-identical\n'

# The current claimant must remain blocked while the duplicate stale record exists.
set +e
PATH="$SCRATCH/fakebin:$ORIGINAL_PATH" \
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_GATE_REFUSE_BYPASS=1 \
  "$ROOT/bin/fm-teardown.sh" "$OWNER_ID" --force \
  > "$SCRATCH/owner.stdout" 2> "$SCRATCH/owner.stderr"
OWNER_RC=$?
set -e
[ "$OWNER_RC" -ne 0 ] || fail "current-owner teardown unexpectedly succeeded before reconciliation"
grep -F "also task $STALE_ID's recorded worktree" "$SCRATCH/owner.stderr" >/dev/null \
  || fail "owner refusal did not name the stale duplicate"
grep -F "nothing was changed - not even with --force" "$SCRATCH/owner.stderr" >/dev/null \
  || fail "owner refusal did not state the no-mutation boundary"
snapshot > "$SCRATCH/after-owner.sha"
cmp -s "$SCRATCH/before.sha" "$SCRATCH/after-owner.sha" || fail "owner refusal changed protected files"
[ "$(git -C "$WORKTREE" status --porcelain=v1)" = "$GIT_BEFORE" ] || fail "owner refusal changed worktree state"
lab pane get "$STALE_PANE" >/dev/null || fail "owner refusal removed stale endpoint"
lab pane get "$OWNER_PANE" >/dev/null || fail "owner refusal removed current owner endpoint"
kill -0 "$PI_PID" || fail "owner refusal harmed the suspended Pi process"

printf 'SCENARIO current owner blocked: PASS\n'
printf '  real owner endpoint: %s:%s\n' "$SESSION" "$OWNER_PANE"
printf '  teardown exit: %s\n' "$OWNER_RC"
printf '  refusal: %s\n' "$(tr '\n' ' ' < "$SCRATCH/owner.stderr")"
printf '  no harm: both panes and Pi pid present; task records, owner claim, sentinel, and git status byte-identical\n'

# Tear down through the guarded helper in this same evidence turn. Success also
# verifies the default-session fleet-state tripwire stayed byte-identical.
env PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"
SESSION_OWNED=0
printf 'LAB teardown: PASS; guarded helper verified the default-session tripwire unchanged\n'

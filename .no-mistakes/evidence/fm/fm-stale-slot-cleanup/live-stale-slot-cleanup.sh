#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:?set ROOT to the Firstmate worktree}
EVIDENCE=${EVIDENCE:?set EVIDENCE to the evidence directory}
HELPER="$ROOT/bin/fm-herdr-lab.sh"
ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-stale-slot.XXXXXX")
LAB=$($HELPER name stale-slot-cleanup)
VIEWER_STARTED=0
PI_PID=

cleanup() {
  local status=$?
  if [ -n "${PI_PID:-}" ]; then
    kill "$PI_PID" 2>/dev/null || true
  fi
  env PATH="$ORIGINAL_PATH" "$HELPER" teardown "$LAB" >/dev/null 2>&1 || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

env PATH="$ORIGINAL_PATH" "$HELPER" provision "$LAB"

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset 'args[$last]' 'args[$flag]'
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 98 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
WRAPPER
chmod +x "$FAKEBIN/herdr"
export HERDR_LAB_SESSION="$LAB" HERDR_ORIGINAL_PATH="$ORIGINAL_PATH" HERDR_LAB_HELPER="$HELPER"

lab() {
  env PATH="$ORIGINAL_PATH" "$HELPER" run "$LAB" "$@"
}

make_pool() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/project" "$dir/pool/1"
  git init -q "$dir/project"
  printf 'tracked\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  ln -s pool/1/project "$dir/worktree"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"
  printf 'owner-work-must-survive\n' > "$dir/worktree/owner-uncommitted.txt"
  printf '%s\n' "$dir"
}

pane_fields() {
  local pane=$1 json
  json=$(lab pane get "$pane")
  PANE_WS=$(printf '%s' "$json" | jq -er '.result.pane.workspace_id')
  PANE_TAB=$(printf '%s' "$json" | jq -er '.result.pane.tab_id')
}

write_herdr_meta() {
  local file=$1 id=$2 worktree=$3 project=$4 pane=$5 ws=$6 tab=$7
  cat > "$file" <<META
backend=herdr
window=$LAB:$pane
endpoint_task_id=$id
herdr_session=$LAB
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
worktree=$worktree
project=$project
kind=scout
mode=no-mistakes
META
}

claim_slot() {
  local dir=$1 id=$2 home=$3
  printf 'task=%s\nhome=%s\n' "$id" "$home" > "$dir/pool/1/.fm-slot-owner"
}

run_teardown() {
  local home=$1 id=$2
  env PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$LAB" \
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force
}

printf 'LAB %s\n' "$LAB"
printf 'SCENARIO active stale endpoint refuses without mutation\n'
ACTIVE_DIR=$(make_pool active)
ACTIVE_CREATE=$(lab workspace create --cwd "$ACTIVE_DIR/worktree" --label active-owner --no-focus)
ACTIVE_OWNER_PANE=$(printf '%s' "$ACTIVE_CREATE" | jq -er '.result.root_pane.pane_id')
pane_fields "$ACTIVE_OWNER_PANE"
ACTIVE_OWNER_WS=$PANE_WS
ACTIVE_OWNER_TAB=$PANE_TAB
ACTIVE_TAB_CREATE=$(lab tab create --workspace "$ACTIVE_OWNER_WS" --cwd "$ACTIVE_DIR/worktree" --label stale-live --no-focus)
ACTIVE_STALE_PANE=$(printf '%s' "$ACTIVE_TAB_CREATE" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id')
pane_fields "$ACTIVE_STALE_PANE"
ACTIVE_STALE_WS=$PANE_WS
ACTIVE_STALE_TAB=$PANE_TAB
mkdir -p "$TMP_ROOT/pi-agent"
cat > "$TMP_ROOT/trust.ts" <<'TRUST'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
}
TRUST
PI_CMD=$(printf 'env PI_CODING_AGENT_DIR=%q pi -e %q --no-context-files --no-session' "$TMP_ROOT/pi-agent" "$TMP_ROOT/trust.ts")
lab pane run "$ACTIVE_STALE_PANE" "$PI_CMD" >/dev/null
ACTIVE_STATUS=
for _ in $(seq 1 120); do
  ACTIVE_STATUS=$(lab agent get "$ACTIVE_STALE_PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  case "$ACTIVE_STATUS" in idle|done|blocked) break ;; esac
  sleep 0.5
done
case "$ACTIVE_STATUS" in idle|done|blocked) ;; *) echo "live Pi did not become ready: $ACTIVE_STATUS" >&2; exit 1 ;; esac
write_herdr_meta "$ACTIVE_DIR/home/state/stale-active.meta" stale-active "$ACTIVE_DIR/worktree" "$ACTIVE_DIR/project" "$ACTIVE_STALE_PANE" "$ACTIVE_STALE_WS" "$ACTIVE_STALE_TAB"
write_herdr_meta "$ACTIVE_DIR/home/state/current-owner.meta" current-owner "$ACTIVE_DIR/worktree" "$ACTIVE_DIR/project" "$ACTIVE_OWNER_PANE" "$ACTIVE_OWNER_WS" "$ACTIVE_OWNER_TAB"
claim_slot "$ACTIVE_DIR" current-owner "$ACTIVE_DIR/home"
cp "$ACTIVE_DIR/pool/1/.fm-slot-owner" "$ACTIVE_DIR/claim.before"
set +e
ACTIVE_OUTPUT=$(run_teardown "$ACTIVE_DIR/home" stale-active 2>&1)
ACTIVE_RC=$?
set -e
printf 'command: fm-teardown.sh stale-active --force\nexit: %s\n%s\n' "$ACTIVE_RC" "$ACTIVE_OUTPUT"
[ "$ACTIVE_RC" -ne 0 ]
printf '%s' "$ACTIVE_OUTPUT" | grep -Fq 'endpoint is active or its liveness is unknown'
[ -f "$ACTIVE_DIR/home/state/stale-active.meta" ]
[ -f "$ACTIVE_DIR/home/state/current-owner.meta" ]
cmp "$ACTIVE_DIR/claim.before" "$ACTIVE_DIR/pool/1/.fm-slot-owner"
[ "$(cat "$ACTIVE_DIR/worktree/owner-uncommitted.txt")" = owner-work-must-survive ]
lab pane get "$ACTIVE_OWNER_PANE" >/dev/null
lab pane get "$ACTIVE_STALE_PANE" >/dev/null
printf 'observable: both records, the owner claim, owner dirty file, owner pane, and live stale Pi pane remain\n'

printf 'SCENARIO confirmed-dead stale record retires without touching current owner\n'
DEAD_DIR=$(make_pool dead)
DEAD_CREATE=$(lab workspace create --cwd "$DEAD_DIR/worktree" --label dead-owner --no-focus)
DEAD_OWNER_PANE=$(printf '%s' "$DEAD_CREATE" | jq -er '.result.root_pane.pane_id')
pane_fields "$DEAD_OWNER_PANE"
DEAD_OWNER_WS=$PANE_WS
DEAD_OWNER_TAB=$PANE_TAB
DEAD_TAB_CREATE=$(lab tab create --workspace "$DEAD_OWNER_WS" --cwd "$DEAD_DIR/worktree" --label exited-stale --no-focus)
DEAD_STALE_PANE=$(printf '%s' "$DEAD_TAB_CREATE" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id')
pane_fields "$DEAD_STALE_PANE"
DEAD_STALE_WS=$PANE_WS
DEAD_STALE_TAB=$PANE_TAB
lab pane close "$DEAD_STALE_PANE" >/dev/null
if lab pane get "$DEAD_STALE_PANE" >/dev/null 2>&1; then
  echo 'failed to stage a confirmed-missing stale endpoint' >&2
  exit 1
fi
write_herdr_meta "$DEAD_DIR/home/state/stale-mirasim.meta" stale-mirasim "$DEAD_DIR/worktree" "$DEAD_DIR/project" "$DEAD_STALE_PANE" "$DEAD_STALE_WS" "$DEAD_STALE_TAB"
write_herdr_meta "$DEAD_DIR/home/state/pi-fast-owner.meta" pi-fast-owner "$DEAD_DIR/worktree" "$DEAD_DIR/project" "$DEAD_OWNER_PANE" "$DEAD_OWNER_WS" "$DEAD_OWNER_TAB"
claim_slot "$DEAD_DIR" pi-fast-owner "$DEAD_DIR/home"
cp "$DEAD_DIR/pool/1/.fm-slot-owner" "$DEAD_DIR/claim.before"
DEAD_OUTPUT=$(run_teardown "$DEAD_DIR/home" stale-mirasim 2>&1)
printf 'command: fm-teardown.sh stale-mirasim --force\nexit: 0\n%s\n' "$DEAD_OUTPUT"
[ ! -e "$DEAD_DIR/home/state/stale-mirasim.meta" ]
[ -f "$DEAD_DIR/home/state/pi-fast-owner.meta" ]
cmp "$DEAD_DIR/claim.before" "$DEAD_DIR/pool/1/.fm-slot-owner"
[ "$(cat "$DEAD_DIR/worktree/owner-uncommitted.txt")" = owner-work-must-survive ]
lab pane get "$DEAD_OWNER_PANE" >/dev/null
printf 'observable: stale metadata removed; owner metadata, claim, dirty file, and exact owner pane remain\n'

printf 'SCENARIO same task id in another registered home remains a collision\n'
CROSS_DIR=$(make_pool cross-home)
CROSS_CREATE=$(lab workspace create --cwd "$CROSS_DIR/worktree" --label cross-owner --no-focus)
CROSS_PANE=$(printf '%s' "$CROSS_CREATE" | jq -er '.result.root_pane.pane_id')
pane_fields "$CROSS_PANE"
CROSS_WS=$PANE_WS
CROSS_TAB=$PANE_TAB
mkdir -p "$CROSS_DIR/child/state" "$CROSS_DIR/child/data"
printf '%s\n' "- same-id - fixture (home: $CROSS_DIR/child; scope: test; projects: project; added 2026-01-01)" > "$CROSS_DIR/home/data/secondmates.md"
write_herdr_meta "$CROSS_DIR/home/state/same-id.meta" same-id "$CROSS_DIR/worktree" "$CROSS_DIR/project" "$CROSS_PANE" "$CROSS_WS" "$CROSS_TAB"
write_herdr_meta "$CROSS_DIR/child/state/same-id.meta" same-id "$CROSS_DIR/worktree" "$CROSS_DIR/project" "$CROSS_PANE" "$CROSS_WS" "$CROSS_TAB"
claim_slot "$CROSS_DIR" same-id "$CROSS_DIR/child"
cp "$CROSS_DIR/pool/1/.fm-slot-owner" "$CROSS_DIR/claim.before"
set +e
CROSS_OUTPUT=$(run_teardown "$CROSS_DIR/home" same-id 2>&1)
CROSS_RC=$?
set -e
printf 'command: fm-teardown.sh same-id --force\nexit: %s\n%s\n' "$CROSS_RC" "$CROSS_OUTPUT"
[ "$CROSS_RC" -ne 0 ]
printf '%s' "$CROSS_OUTPUT" | grep -Fq "also task same-id's recorded worktree"
[ -f "$CROSS_DIR/home/state/same-id.meta" ]
[ -f "$CROSS_DIR/child/state/same-id.meta" ]
cmp "$CROSS_DIR/claim.before" "$CROSS_DIR/pool/1/.fm-slot-owner"
[ "$(cat "$CROSS_DIR/worktree/owner-uncommitted.txt")" = owner-work-must-survive ]
lab pane get "$CROSS_PANE" >/dev/null
printf 'observable: root and child same-id records, child claim, dirty file, and pane all remain\n'

printf 'RESULT all live stale-slot scenarios passed; lab teardown follows via trap\n'

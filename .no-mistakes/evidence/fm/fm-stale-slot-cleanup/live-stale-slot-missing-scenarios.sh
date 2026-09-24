#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:?set ROOT to the Firstmate worktree}
EVIDENCE=${EVIDENCE:?set EVIDENCE to the evidence directory}
HELPER="$ROOT/bin/fm-herdr-lab.sh"
ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-stale-slot-missing.XXXXXX")
LAB=$($HELPER name stale-slot-missing)

cleanup() {
  local status=$?
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
if [ "${FM_TEST_HERDR_PROCESS_INFO_UNREADABLE:-}" = 1 ] \
  && [ "${1:-}" = pane ] \
  && [ "${2:-}" = process-info ]; then
  printf '%s\n' '{"error":{"code":"transport_unavailable","message":"isolated liveness read failure"}}'
  exit 1
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
WRAPPER
chmod +x "$FAKEBIN/herdr"
export HERDR_LAB_SESSION="$LAB" HERDR_ORIGINAL_PATH="$ORIGINAL_PATH" HERDR_LAB_HELPER="$HELPER"

lab() {
  env PATH="$ORIGINAL_PATH" "$HELPER" run "$LAB" "$@"
}

make_pool() {
  local name=$1 dir="$TMP_ROOT/$1" slot
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/project"
  git init -q "$dir/project"
  printf 'tracked\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  slot=$(cd "$dir/project" && treehouse --root "$dir/treehouse-root" get --lease \
    --lease-holder "fixture-$name" --no-fetch)
  printf '%s\n' "$slot" > "$dir/worktree.path"
  ln -s "$slot" "$dir/worktree"
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

pool_worktree() {
  cat "$1/worktree.path"
}

slot_owner_file() {
  local dir=$1 slot
  slot=$(pool_worktree "$dir")
  printf '%s/.fm-slot-owner\n' "$(dirname "$slot")"
}

claim_slot() {
  local dir=$1 id=$2 home=$3 marker
  marker=$(slot_owner_file "$dir")
  printf 'task=%s\nhome=%s\n' "$id" "$home" > "$marker"
}

run_teardown() {
  local home=$1 id=$2 treehouse_root
  treehouse_root=$(dirname "$home")/treehouse-root
  env PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$LAB" TREEHOUSE_ROOT="$treehouse_root" \
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force
}

run_teardown_unknown() {
  local home=$1 id=$2 treehouse_root
  treehouse_root=$(dirname "$home")/treehouse-root
  env PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$LAB" TREEHOUSE_ROOT="$treehouse_root" \
    FM_TEST_HERDR_PROCESS_INFO_UNREADABLE=1 \
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force
}

agent_liveness() {
  local pane=$1 unreadable=${2:-0}
  env PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$LAB" \
    FM_TEST_HERDR_PROCESS_INFO_UNREADABLE="$unreadable" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_alive herdr "$2"' \
    _ "$ROOT" "$LAB:$pane"
}

start_pi() {
  local pane=$1 status=
  lab pane run "$pane" "$PI_CMD" >/dev/null
  for _ in $(seq 1 120); do
    status=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$status" in idle|done|blocked) return 0 ;; esac
    sleep 0.5
  done
  echo "live Pi did not become ready: $status" >&2
  return 1
}

mkdir -p "$TMP_ROOT/pi-agent"
cat > "$TMP_ROOT/trust.ts" <<'TRUST'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
}
TRUST
PI_CMD=$(printf 'env PI_CODING_AGENT_DIR=%q pi -e %q --no-context-files --no-session' "$TMP_ROOT/pi-agent" "$TMP_ROOT/trust.ts")

printf 'LAB %s\n' "$LAB"
printf 'SCENARIO unknown endpoint liveness refuses without mutation\n'
UNKNOWN_DIR=$(make_pool unknown)
UNKNOWN_CLAIM=$(slot_owner_file "$UNKNOWN_DIR")
UNKNOWN_CREATE=$(lab workspace create --cwd "$UNKNOWN_DIR/worktree" --label unknown-owner --no-focus)
UNKNOWN_OWNER_PANE=$(printf '%s' "$UNKNOWN_CREATE" | jq -er '.result.root_pane.pane_id')
pane_fields "$UNKNOWN_OWNER_PANE"
UNKNOWN_OWNER_WS=$PANE_WS
UNKNOWN_OWNER_TAB=$PANE_TAB
UNKNOWN_TAB_CREATE=$(lab tab create --workspace "$UNKNOWN_OWNER_WS" --cwd "$UNKNOWN_DIR/worktree" --label unknown-stale --no-focus)
UNKNOWN_STALE_PANE=$(printf '%s' "$UNKNOWN_TAB_CREATE" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id')
pane_fields "$UNKNOWN_STALE_PANE"
UNKNOWN_STALE_WS=$PANE_WS
UNKNOWN_STALE_TAB=$PANE_TAB
start_pi "$UNKNOWN_STALE_PANE"
NORMAL_LIVENESS=$(agent_liveness "$UNKNOWN_STALE_PANE")
UNKNOWN_LIVENESS=$(agent_liveness "$UNKNOWN_STALE_PANE" 1)
printf 'precondition: exact real endpoint normal-liveness=%s unreadable-process-info-liveness=%s\n' "$NORMAL_LIVENESS" "$UNKNOWN_LIVENESS"
[ "$NORMAL_LIVENESS" = alive ]
[ "$UNKNOWN_LIVENESS" = unknown ]
UNKNOWN_WORKTREE=$(pool_worktree "$UNKNOWN_DIR")
write_herdr_meta "$UNKNOWN_DIR/home/state/stale-unknown.meta" stale-unknown "$UNKNOWN_WORKTREE" "$UNKNOWN_DIR/project" "$UNKNOWN_STALE_PANE" "$UNKNOWN_STALE_WS" "$UNKNOWN_STALE_TAB"
write_herdr_meta "$UNKNOWN_DIR/home/state/current-owner.meta" current-owner "$UNKNOWN_WORKTREE" "$UNKNOWN_DIR/project" "$UNKNOWN_OWNER_PANE" "$UNKNOWN_OWNER_WS" "$UNKNOWN_OWNER_TAB"
claim_slot "$UNKNOWN_DIR" current-owner "$UNKNOWN_DIR/home"
cp "$UNKNOWN_CLAIM" "$UNKNOWN_DIR/claim.before"
set +e
UNKNOWN_OUTPUT=$(run_teardown_unknown "$UNKNOWN_DIR/home" stale-unknown 2>&1)
UNKNOWN_RC=$?
set -e
printf 'command: FM_TEST_HERDR_PROCESS_INFO_UNREADABLE=1 fm-teardown.sh stale-unknown --force\nexit: %s\n%s\n' "$UNKNOWN_RC" "$UNKNOWN_OUTPUT"
[ "$UNKNOWN_RC" -ne 0 ]
printf '%s' "$UNKNOWN_OUTPUT" | grep -Fq 'endpoint is active or its liveness is unknown'
[ -f "$UNKNOWN_DIR/home/state/stale-unknown.meta" ]
[ -f "$UNKNOWN_DIR/home/state/current-owner.meta" ]
cmp "$UNKNOWN_DIR/claim.before" "$UNKNOWN_CLAIM"
[ "$(cat "$UNKNOWN_DIR/worktree/owner-uncommitted.txt")" = owner-work-must-survive ]
lab pane get "$UNKNOWN_OWNER_PANE" >/dev/null
lab pane get "$UNKNOWN_STALE_PANE" >/dev/null
printf 'observable: refusal preserved both records, owner claim, dirty file, owner pane, and exact live stale endpoint\n'

printf 'SCENARIO current owner blocks until stale duplicate is reconciled\n'
RECON_DIR=$(make_pool reconcile)
RECON_CLAIM=$(slot_owner_file "$RECON_DIR")
RECON_CREATE=$(lab workspace create --cwd "$RECON_DIR/worktree" --label reconcile-owner --no-focus)
RECON_OWNER_PANE=$(printf '%s' "$RECON_CREATE" | jq -er '.result.root_pane.pane_id')
pane_fields "$RECON_OWNER_PANE"
RECON_OWNER_WS=$PANE_WS
RECON_OWNER_TAB=$PANE_TAB
RECON_TAB_CREATE=$(lab tab create --workspace "$RECON_OWNER_WS" --cwd "$RECON_DIR/worktree" --label reconcile-stale --no-focus)
RECON_STALE_PANE=$(printf '%s' "$RECON_TAB_CREATE" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id')
pane_fields "$RECON_STALE_PANE"
RECON_STALE_WS=$PANE_WS
RECON_STALE_TAB=$PANE_TAB
start_pi "$RECON_OWNER_PANE"
lab pane close "$RECON_STALE_PANE" >/dev/null
if lab pane get "$RECON_STALE_PANE" >/dev/null 2>&1; then
  echo 'failed to stage a confirmed-missing stale endpoint' >&2
  exit 1
fi
RECON_WORKTREE=$(pool_worktree "$RECON_DIR")
write_herdr_meta "$RECON_DIR/home/state/stale-mirasim.meta" stale-mirasim "$RECON_WORKTREE" "$RECON_DIR/project" "$RECON_STALE_PANE" "$RECON_STALE_WS" "$RECON_STALE_TAB"
write_herdr_meta "$RECON_DIR/home/state/pi-fast-owner.meta" pi-fast-owner "$RECON_WORKTREE" "$RECON_DIR/project" "$RECON_OWNER_PANE" "$RECON_OWNER_WS" "$RECON_OWNER_TAB"
claim_slot "$RECON_DIR" pi-fast-owner "$RECON_DIR/home"
cp "$RECON_CLAIM" "$RECON_DIR/claim.before"
set +e
OWNER_BLOCK_OUTPUT=$(run_teardown "$RECON_DIR/home" pi-fast-owner 2>&1)
OWNER_BLOCK_RC=$?
set -e
printf 'command: fm-teardown.sh pi-fast-owner --force (before reconciliation)\nexit: %s\n%s\n' "$OWNER_BLOCK_RC" "$OWNER_BLOCK_OUTPUT"
[ "$OWNER_BLOCK_RC" -ne 0 ]
printf '%s' "$OWNER_BLOCK_OUTPUT" | grep -Fq "also task stale-mirasim's recorded worktree"
[ -f "$RECON_DIR/home/state/stale-mirasim.meta" ]
[ -f "$RECON_DIR/home/state/pi-fast-owner.meta" ]
cmp "$RECON_DIR/claim.before" "$RECON_CLAIM"
[ "$(cat "$RECON_DIR/worktree/owner-uncommitted.txt")" = owner-work-must-survive ]
lab pane get "$RECON_OWNER_PANE" >/dev/null
printf 'observable: blocked owner retained both records, claim, dirty file, and exact live owner endpoint\n'

STALE_OUTPUT=$(run_teardown "$RECON_DIR/home" stale-mirasim 2>&1)
printf 'command: fm-teardown.sh stale-mirasim --force (reconcile stale record)\nexit: 0\n%s\n' "$STALE_OUTPUT"
[ ! -e "$RECON_DIR/home/state/stale-mirasim.meta" ]
[ -f "$RECON_DIR/home/state/pi-fast-owner.meta" ]
cmp "$RECON_DIR/claim.before" "$RECON_CLAIM"
[ "$(cat "$RECON_DIR/worktree/owner-uncommitted.txt")" = owner-work-must-survive ]
lab pane get "$RECON_OWNER_PANE" >/dev/null
printf 'observable: stale retirement removed only stale metadata; owner record, claim, dirty file, and exact endpoint remain\n'

set +e
OWNER_OUTPUT=$(run_teardown "$RECON_DIR/home" pi-fast-owner 2>&1)
OWNER_RC=$?
set -e
printf 'command: fm-teardown.sh pi-fast-owner --force (after reconciliation)\nexit: %s\n%s\n' "$OWNER_RC" "$OWNER_OUTPUT"
[ "$OWNER_RC" -eq 0 ]
[ ! -e "$RECON_DIR/home/state/pi-fast-owner.meta" ]
[ ! -e "$RECON_CLAIM" ]
if lab pane get "$RECON_OWNER_PANE" >/dev/null 2>&1; then
  echo 'owner endpoint survived successful owner cleanup' >&2
  exit 1
fi
printf 'observable: reconciled owner cleanup removed its metadata, exact endpoint, and spent slot claim\n'

printf 'RESULT both previously missing live scenarios passed; lab teardown follows via trap\n'

#!/usr/bin/env bash
# Behavioral and unit tests for Claude launcher selection (config/claude-launcher)
# and Mirasim process classification.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-launcher)

# 1. Process classification: mirasim recognized as agent
test_process_classification() {
  [ "$(fm_agent_process_classify_name /usr/local/bin/mirasim)" = agent ] || fail "process path /usr/local/bin/mirasim must classify as agent"
  [ "$(fm_agent_process_classify_name mirasim)" = agent ] || fail "bare mirasim must classify as agent"
  [ "$(fm_agent_process_classify_name mirasim-other)" = other ] || fail "mirasim-other must not match anchored mirasim"
  pass "mirasim process classification"
}

# 2. Spawn with config/claude-launcher = mirasim
test_claude_launcher_mirasim() {
  local case_dir home proj wt fakebin id out launch

  case_dir="$TMP_ROOT/claude-launcher-mirasim"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" mirasim claude)
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=launcher-crew
  fm_test_spawn_home "$home"
  printf 'mirasim\n' > "$home/config/claude-launcher"
  fm_git_worktree "$proj" "$wt" "$id"
  fm_test_spawn_brief "$home" "$id"

  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
      --harness claude --model 'claude-opus-5-5' --effort high \
      --mode local-only --yolo off)
  expect_code 0 $? "Claude spawn with claude-launcher=mirasim should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" "'$fakebin/mirasim' claude" \
    "claude-launcher=mirasim did not prefix Claude worker launch with mirasim binary"
  assert_contains "$launch" "--model 'claude-opus-5-5'" \
    "Claude model flag --model 'claude-opus-5-5' missing"
  assert_contains "$launch" "--effort 'high'" \
    "Claude effort flag --effort 'high' missing"
  assert_contains "$launch" "--dangerously-skip-permissions" \
    "Claude bypass permission flag missing"
  assert_present "$wt/.claude/settings.local.json" \
    "Claude settings.local.json hook file was not written"
  pass "config/claude-launcher = mirasim prefixes Claude launch and preserves flags and hooks"
}

# 3. Default / absent config/claude-launcher uses direct claude
test_claude_launcher_default() {
  local case_dir home proj wt fakebin id out launch

  case_dir="$TMP_ROOT/claude-launcher-default"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=default-crew
  fm_test_spawn_home "$home"
  fm_git_worktree "$proj" "$wt" "$id"
  fm_test_spawn_brief "$home" "$id"

  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
      --harness claude --model 'claude-opus-5-5' \
      --mode local-only --yolo off)
  expect_code 0 $? "Claude spawn with absent claude-launcher should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_not_contains "$launch" "mirasim" \
    "absent claude-launcher should not reference mirasim"
  assert_contains "$launch" "claude" \
    "Claude launch command missing claude binary"
  pass "absent config/claude-launcher launches standard claude directly"
}

# 4. Explicit config/claude-launcher = claude uses direct claude
test_claude_launcher_explicit_claude() {
  local case_dir home proj wt fakebin id out launch

  case_dir="$TMP_ROOT/claude-launcher-explicit"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=explicit-crew
  fm_test_spawn_home "$home"
  printf 'claude\n' > "$home/config/claude-launcher"
  fm_git_worktree "$proj" "$wt" "$id"
  fm_test_spawn_brief "$home" "$id"

  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
      --harness claude --model 'claude-opus-5-5' \
      --mode local-only --yolo off)
  expect_code 0 $? "Claude spawn with claude-launcher=claude should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_not_contains "$launch" "mirasim" \
    "explicit claude-launcher=claude should not reference mirasim"
  pass "explicit config/claude-launcher = claude launches standard claude directly"
}

# 5. config/claude-launcher = mirasim does NOT apply to secondmate launches
test_claude_launcher_secondmate_exclusion() {
  local case_dir home wt sm_home fakebin id out launch

  case_dir="$TMP_ROOT/claude-launcher-secondmate"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" mirasim claude)
  home="$case_dir/home"
  wt="$case_dir/wt"
  sm_home="$case_dir/sm_home"
  id=launcher-secondmate
  fm_test_spawn_home "$home"
  printf 'mirasim\n' > "$home/config/claude-launcher"
  mkdir -p "$sm_home/bin" "$sm_home/data"
  printf '# Firstmate\n' > "$sm_home/AGENTS.md"
  printf '%s\n' "$id" > "$sm_home/.fm-secondmate-home"
  fm_test_spawn_brief "$home" "$id"

  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$sm_home" \
      --secondmate --harness claude)
  expect_code 0 $? "Claude secondmate spawn should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_not_contains "$launch" "$fakebin/mirasim" \
    "claude-launcher=mirasim must not apply to persistent secondmates"
  assert_contains "$launch" "claude" \
    "Claude secondmate launch command missing claude binary"
  pass "config/claude-launcher = mirasim ignores secondmate launches"
}

# 6. Invalid config/claude-launcher rejected
test_claude_launcher_invalid() {
  local case_dir home proj wt fakebin id out

  case_dir="$TMP_ROOT/claude-launcher-invalid"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" mirasim claude)
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=launcher-invalid
  fm_test_spawn_home "$home"
  printf 'unrecognized-launcher\n' > "$home/config/claude-launcher"
  fm_git_worktree "$proj" "$wt" "$id"
  fm_test_spawn_brief "$home" "$id"

  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness claude --mode local-only --yolo off 2>&1) && {
    fail "spawn with invalid claude-launcher must be rejected: $out"
  }
  assert_contains "$out" "config/claude-launcher holds 'unrecognized-launcher'" \
    "invalid claude-launcher error did not report current value"
  assert_contains "$out" "accepted values are: claude" \
    "invalid claude-launcher error did not name accepted values"
  pass "invalid config/claude-launcher is rejected before launch"
}

# 7. Missing mirasim binary on PATH rejected when claude-launcher is mirasim
test_claude_launcher_missing_binary() {
  local case_dir home proj wt fakebin id out

  case_dir="$TMP_ROOT/claude-launcher-missing"
  # fakebin only has claude, not mirasim; constrain PATH to exclude host ~/.local/bin
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=launcher-missing
  fm_test_spawn_home "$home"
  printf 'mirasim\n' > "$home/config/claude-launcher"
  fm_git_worktree "$proj" "$wt" "$id"
  fm_test_spawn_brief "$home" "$id"

  out=$(PATH="$fakebin:/usr/bin:/bin" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness claude --mode local-only --yolo off 2>&1) && {
    fail "spawn with missing mirasim binary must be rejected: $out"
  }
  assert_contains "$out" "mirasim executable not found on PATH" \
    "missing mirasim error did not report executable not found"
  pass "missing mirasim binary is rejected with clear error"
}

test_process_classification
test_claude_launcher_mirasim
test_claude_launcher_default
test_claude_launcher_explicit_claude
test_claude_launcher_secondmate_exclusion
test_claude_launcher_invalid
test_claude_launcher_missing_binary

echo "all fm-claude-launcher tests passed"

# Mirasim adapter verification

This record covers the crewmate and scout adapter only.
Primary and secondmate operation remain unsupported.

## Current evidence

Verified on 2026-09-23 with Mirasim `0.0.303` wrapping Claude Code `2.1.278` on macOS arm64.

`mirasim ui-cli catalog --agent claude` advertised the requested `claude-fable-5-1[1m]` model in the authenticated environment.
Firstmate accepts low, medium, high, xhigh, and max effort for this route, matching its Claude adapter, and refuses ultra.
The live guard below verifies low effort.
Portable regressions cover high-effort launch, max-effort dispatch, and rejection of ultra.

Run the portable adapter regression with:

```sh
bin/fm-test-run.sh tests/fm-mirasim-harness.test.sh
```

It proves the selectable route records `harness=mirasim`, launches the absolute Mirasim executable resolved during preflight, preserves a bracketed model id as one shell-quoted argument, propagates effort and permission mode, installs Claude lifecycle hooks, trusts `claude-hook`, reuses Claude control mechanics, and refuses secondmate use.
It also checks Mirasim and Devin retain their distinct control and hook contracts, the launch-prompt live guard remains classified, and Mirasim's owner paths resolve inside the repository.

Run the credentialed live guard with:

```sh
FM_MIRASIM_LIVE_E2E=1 bin/fm-test-run.sh --per-script-timeout-secs 120 tests/fm-mirasim-live-e2e.test.sh
```

The guard uses a temporary empty directory and sends the fixed prompt `Reply with exactly MIRASIM_SMOKE_OK and nothing else.` with tools disabled and session persistence off.
It prefers `claude-fable-5-1[1m]` when the current catalog contains that id, otherwise requests the catalog default, observes the exact response, and checks Claude's `UserPromptSubmit` and `Stop` hook transitions through Firstmate's real busy-state writer.
The run proves that the requested id completed through the authenticated Mirasim route.
It does not prove the upstream served-model identity or quota coverage.
The guard requires both UserPromptSubmit and normal Stop events; SessionEnd and StopFailure cannot substitute for normal completion.

Observed output:

```text
ok - Mirasim requested model claude-fable-5-1[1m] completed the synthetic prompt through Claude hooks; served identity remains unproven
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=29954
```

This refresh covers a headless synthetic turn, not an interactive backend lifecycle.
It does not revalidate steering, interrupt, exit, or relaunch against a live terminal.

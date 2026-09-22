---
name: quiet
description: >-
  Enter quiet supervision mode when the captain invokes /quiet or asks for quiet mode, quiet-while-present, or fewer routine wake turns while they stay in the session.
  It reuses the confirmed afk posture and keeps ordinary chat from ending that posture; only an explicit `/quiet off` does.
user-invocable: true
metadata:
  internal: true
---

# quiet

Quiet supervision mode (kunchenguid/firstmate#2356) is the afk presentation policy for a captain who stays in the session and does not want ordinary chat to end the mode.

This skill is a thin wrapper.
The `afk` skill owns the posture record, daemon lifecycle, guards, classification policy, and reliability properties.
Quiet mode changes only the non-Pi flag mode and the exit signal.

## Entering quiet mode

1. Follow steps 1 through 3 in [`afk` entry](../afk/SKILL.md#entering-afk-words) to create the confirmed `state/.afk-contract` before any daemon command.
   Plain `/quiet` carries no away mandate, so use the no-words entry that `afk` permits and run `propose` and `confirm` back to back.
2. On `pi` and `pi-signed`, stop after confirmation.
   The confirmed record is the posture, `bin/fm-afk-launch.sh start` and `start-native` refuse on Pi, and the attended supervision branch already keeps routine wakes out of this conversation.
   Pi writes no `state/.afk` mode flag and launches no daemon.
3. On every other harness, follow the matching harness branch in step 4 of [`afk` entry](../afk/SKILL.md#entering-afk-words).
   Set `FM_AFK_MODE=quiet` in the shell that invokes `bin/fm-afk-launch.sh start` or `start-native`, so `state/.afk` records `quiet`.
   Leave `FM_AFK_MODE` unset only when refreshing an already-running quiet daemon; `fm_afk_flag_write` then preserves the recorded mode.
   Do not arm a separate `fm-watch.sh`.

4. Acknowledge in `AGENTS.md` section 9 language: "Captain, quiet mode is active; I will batch routine updates and surface only decisions, failures, credentials, or review-ready work - ordinary chat will not exit this, say `/quiet off` when you want normal per-wake responses back."

## How to exit quiet mode

Unlike `/afk`, ordinary chat is never the exit signal.
`AGENTS.md` section 8 owns this always-loaded distinction.

- Only an explicit `/quiet off`, or a plain request to resume normal supervision, exits quiet mode.
  Run `bin/fm-afk-return.sh` through the procedure in [`afk` return](../afk/SKILL.md#how-to-exit-the-return).
  The same command archives the confirmed posture record on Pi and stops the daemon before archiving it on other harnesses.
- A marked daemon escalation or a message beginning with `/quiet` while quiet mode is active stays in quiet mode and processes the message.
- Every other message receives an ordinary answer while the posture remains active.

## Orthogonal to approval authority

As in `/afk`, quiet mode changes which events firstmate surfaces and never changes approval authority.
A PR ready for merge keeps the merge authority from `AGENTS.md` section 7, and a needs-decision finding keeps the `ask-user-authority` policy.

## Must not hide a decision or a failure

The issue's author triage defines quiet mode as presentation only.
Progress, retries, and internal mechanics do not surface, but review-ready work, findings, decisions, failures, and credentials always escalate through the classification policy that `/afk` owns.
Quiet mode is opt-in and never the default; only an explicit `/quiet` invocation enters it.

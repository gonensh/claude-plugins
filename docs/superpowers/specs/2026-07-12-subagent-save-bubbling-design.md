# Subagent Save-Suggestion Bubbling — Design

**Date:** 2026-07-12
**Status:** Approved
**Component:** `plugins/safe-scripts`

## Problem

The safe-scripts save flow breaks for subagents. When a subagent's Bash command
needs approval, Claude Code (≥ 2.1.207) escalates the permission dialog to the
user, but the `PermissionRequest` hook's `[OFFER_SAFE_SCRIPT]` context is
injected into the *subagent's* transcript. The subagent has no conversation
with the user, so the save offer either runs into the void or is silently
dropped — the save opportunity is lost and the same command prompts again next
session.

A secondary bug affects the main agent: `[OFFER_SAFE_SCRIPT]` is injected at
`PermissionRequest` time, *before* the user decides. If the user denies the
command, the main agent still offers to save it (and the skill wording claims
"That command ran successfully").

## Goals

- Save offers for commands approved during a subagent run reach the user via
  the **main agent**, as soon as the subagent returns.
- Only commands that **actually ran** (i.e. were approved) generate offers —
  in both subagent and main-agent contexts.
- Multiple approved commands are offered **one at a time**, reusing the
  existing `[OFFER_SAFE_SCRIPT]` conversational flow.
- Suggestions do not persist across sessions: if the session ends before the
  offer surfaces, the suggestion is dropped.
- Main-agent UX is otherwise unchanged; normal sessions (no pending records)
  pay near-zero overhead.

## Non-Goals

- Injecting the safe-scripts catalog into subagent contexts (subagents remain
  covered reactively by the `PreToolUse` redirect).
- Cross-session resurfacing of unconsumed suggestions.
- Any change to the `PreToolUse` interception or heredoc flows.

## Mechanism Overview

One record store, one decision point, two exits:

```
Bash command needs approval (PermissionRequest, matcher: Bash)
  → write a "prompted" record (tagged with agent_id, or "main" if absent)
  → subagent:  emit [SAFE_SCRIPT_DEFERRED] ("do not run the save flow")
  → main agent: emit nothing (offer moves to after execution)

command runs (PostToolUse, matcher: Bash)   ← only fires if approved
  → record matches the executed command?
      subagent:   flip record status to "approved"
      main agent: emit [OFFER_SAFE_SCRIPT] additionalContext now,
                  delete the record

subagent tree returns (PostToolUse, matcher: Task|Agent)
  → only acts when agent_id is ABSENT (true main agent)
  → read this session's records; keep "approved"; dedupe identical commands;
    skip commands now covered by the manifest (saved mid-run)
  → emit [OFFER_SAFE_SCRIPT] additionalContext listing them, instructing
    sequential one-at-a-time offers
  → delete the session's pending dir ("prompted"-only records = denied,
    silently dropped)
```

Detection relies on documented hook-input fields: `agent_id` / `agent_type`
are present in hook input only when the hook fires inside a subagent.

## Record Store

Path: `~/.claude/safe-scripts/.pending/<session_id>/<epoch>-<random>.json`

- **One file per record** — parallel subagents write concurrently without
  locking; creation is race-free by construction.
- Always home-based, even when `safe_scripts_dir` is project-overridden:
  this is ephemeral state, not shareable content.
- `SAFE_SCRIPTS_PENDING_DIR` env var overrides the root (mirrors
  `SAFE_SCRIPTS_DIR`; used by tests).

Record shape:

```json
{
  "command": "git log --oneline -10 -- src/App.tsx",
  "agent_type": "Explore",
  "agent_id": "abc123",
  "status": "prompted",
  "ts": 1784000000
}
```

`agent_id` is `"main"` for main-agent records. `status` is `"prompted"` or
`"approved"`. Matching between the prompted and executed command is exact
string equality (it is the same command string end to end).

## Component Changes

### `hooks/hooks.json`

Add two `PostToolUse` entries:

- matcher `Bash` → `run-hook.cmd post-tool-use-bash`
- matcher `Task|Agent` → `run-hook.cmd post-tool-use-task`
  (both names covered; the subagent-spawning tool is exposed as either,
  depending on surface)

### `hooks/permission-request` (modified)

- Parse `agent_id` / `agent_type` from hook input.
- Always write a `prompted` record to the pending dir (atomic: unique
  filename per record).
- `agent_id` present → emit `[SAFE_SCRIPT_DEFERRED]` context: do not offer
  to save; the main agent will offer the user after you finish.
- `agent_id` absent → emit nothing. (The `[OFFER_SAFE_SCRIPT]` emission moves
  to `post-tool-use-bash`.)

### `hooks/post-tool-use-bash` (new)

- First-line guard: no pending dir for this session → `exit 0`.
- Find a `prompted` record whose `command` exactly matches the executed
  command. None → `exit 0`.
- `agent_id` present → rewrite the record with `status: "approved"`
  (tmp file + `mv`).
- `agent_id` absent (main agent) → emit `[OFFER_SAFE_SCRIPT]`
  `additionalContext` (lands next to the tool result) and delete the record.

### `hooks/post-tool-use-task` (new)

- Guard: `agent_id` present (we are inside a nested subagent) → `exit 0`.
  Nested subagent trees therefore drain only when the top-level Task returns
  to the true main agent.
- Read all records for this `session_id`; keep `approved`; dedupe identical
  commands; drop commands matching an existing manifest pattern
  (`find_matching_script`).
- If any remain: emit `additionalContext` — subagent-flavored
  `[OFFER_SAFE_SCRIPT]` listing the commands and which agent type approved
  them, instructing the main agent to invoke the safe-scripts skill and offer
  each command sequentially.
- Delete the session's pending dir in all cases where it exists.

### `hooks/session-start` (modified)

One extra step: sweep `.pending/` session subdirectories older than 24 hours
(leftovers from sessions that ended before a drain).

Also update the "no scripts yet" message wording: the `[OFFER_SAFE_SCRIPT]`
hint now appears after an approved command runs, not when approval is
requested.

### `scripts/lib.sh` (modified)

Add `get_pending_dir()` (env override → default home path) and small helpers
for writing / reading / updating record files.

### `skills/safe-scripts/SKILL.md` (modified)

Add section **"On [OFFER_SAFE_SCRIPT] (from a subagent run)"**:

- Wording acknowledges the command(s) were approved during a subagent's work.
- Offer **one command per reply** with the existing (a) save / (b) leave
  choice; after resolving one, offer the next.
- Reuses the existing Save Procedure unchanged.

The existing "On [OFFER_SAFE_SCRIPT]" section stays as-is for the main path.

## Edge Cases

| Case | Behavior |
|---|---|
| Command denied (either context) | Record stays `prompted`; never offered; dropped at drain (subagent) or swept at SessionStart (main). |
| Same command approved by two parallel subagents | Two records; deduped at drain; one offer. |
| Command saved as a script mid-run | Dropped at drain via manifest-pattern check. |
| Session ends before drain | Records orphaned; swept by next SessionStart; **not** resurfaced. |
| Nested subagents (subagent spawns subagent) | Inner Task returns inside a subagent (`agent_id` present) → no drain; records surface when the top-level Task returns. |
| Bash ran without ever prompting (already allowed) | No record exists; `post-tool-use-bash` exits on the first guard. |
| Malformed record file | Skipped with a stderr warning (same pattern as `load_manifest`). |
| Task drain deleting the session dir vs. live main-agent records | Cannot conflict: main records are consumed at the same event that flips them; only denied (`prompted`) main records can linger, and dropping those is harmless. |
| Windows | New hooks are extensionless bash scripts dispatched via the existing `run-hook.cmd` polyglot. |

## Behavioral Changes (main agent)

- Denied main-agent commands no longer generate save offers (bug fix).
- The offer context arrives at `PostToolUse` (next to the tool result) instead
  of at `PermissionRequest`. The skill's "in your next reply" behavior is
  unchanged in practice.

## Testing

Extend the existing bash test harness (`tests/test-lib.sh`, `run-tests.sh`),
using `SAFE_SCRIPTS_PENDING_DIR` pointed at a temp dir:

- **`test-permission-request.sh`** (extended): input with `agent_id` → record
  written + `[SAFE_SCRIPT_DEFERRED]` context; input without `agent_id` →
  record written + no context output.
- **`test-post-tool-use-bash.sh`** (new):
  - subagent record prompted + command ran → record flipped to `approved`
  - main record prompted + command ran → `[OFFER_SAFE_SCRIPT]` emitted +
    record deleted
  - prompted + never ran (denied) → record untouched, no output
  - no pending dir → instant clean exit
- **`test-post-tool-use-task.sh`** (new):
  - approved records → context emitted listing commands, dir deleted
  - prompted-only records → no context, dir deleted
  - duplicate commands → single mention
  - command matching manifest pattern → dropped
  - input with `agent_id` (nested) → no-op
- **`test-session-start.sh`** (extended): stale pending dirs swept; fresh ones
  kept.

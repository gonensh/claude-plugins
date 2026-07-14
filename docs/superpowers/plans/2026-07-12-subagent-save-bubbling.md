# Subagent Save-Suggestion Bubbling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Save offers for Bash commands approved during subagent runs bubble up to the main agent; offers only fire for commands that actually ran (fixes denied-command offers in the main agent too).

**Architecture:** A file-per-record pending store under `~/.claude/safe-scripts/.pending/<session_id>/`. The `PermissionRequest` hook writes a `prompted` record (main and subagent alike). A new `PostToolUse(Bash)` hook is the approval detector: subagent records flip to `approved`; main-agent records emit the `[OFFER_SAFE_SCRIPT]` context immediately and are deleted. A new `PostToolUse(Task|Agent)` hook drains approved records into the main agent's context when a subagent returns. Detection of subagent context uses the documented `agent_id`/`agent_type` hook-input fields (present only inside subagents).

**Tech Stack:** bash ≥ 3.2, jq ≥ 1.5, Claude Code plugin hooks. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-12-subagent-save-bubbling-design.md`

## Global Constraints

- All work is inside `plugins/safe-scripts/`. Run all commands from the repo root `/Users/gonen/dev/claude-safe-scripts` unless a step says otherwise.
- bash ≥ 3.2 compatible (macOS default bash): no associative arrays, no `mapfile`.
- Hook scripts are extensionless (Windows `run-hook.cmd` polyglot dispatch); new hooks must be `chmod +x` and start with `#!/usr/bin/env bash` + `set -euo pipefail`, matching existing hooks.
- Record matching is **exact string equality** on the command.
- Pending store root: env `SAFE_SCRIPTS_PENDING_DIR` override, else `${HOME}/.claude/safe-scripts/.pending`. **Never** the project-overridden scripts dir.
- Tests must never touch the real `~/.claude/safe-scripts` — every hook invocation in tests sets `SAFE_SCRIPTS_PENDING_DIR` (and `SAFE_SCRIPTS_DIR` where relevant) to a temp dir.
- Marker strings are load-bearing (`[OFFER_SAFE_SCRIPT]`, `[SAFE_SCRIPT_DEFERRED]`, `[SAFE_SCRIPT_AVAILABLE]`, `[HEREDOC_POSSIBLE_MATCH]`) — copy them exactly.
- Commit after every task; test suite (`bash plugins/safe-scripts/tests/run-tests.sh`) must pass before each commit.

---

### Task 1: Pending-record store helpers in lib.sh

**Files:**
- Modify: `plugins/safe-scripts/scripts/lib.sh` (append after `find_heredoc_candidates`, before `emit_context`)
- Test: `plugins/safe-scripts/tests/test-lib.sh` (append before the final results block)

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Tasks 2–5):
  - `get_pending_dir` → echoes pending-store root path
  - `write_pending_record <session_id> <command> <agent_id> <agent_type>` → creates a `prompted` record file; `agent_id` is the literal string `main` for main-agent records
  - `find_prompted_record <session_id> <command>` → echoes path of first record with `status=="prompted"` and exact command match, else empty
  - `approve_pending_record <record_file>` → rewrites record with `status:"approved"` (tmp + mv)
  - `list_approved_records <session_id>` → echoes JSON array of approved records, deduped by command; `[]` when none; malformed files skipped with stderr warning
  - `clear_pending_session <session_id>` → deletes the session's pending dir; no-op on empty session_id
  - `sweep_pending_dirs` → deletes session dirs older than 24h under the pending root

- [ ] **Step 1: Write the failing tests**

Append to `plugins/safe-scripts/tests/test-lib.sh`, immediately before the final `echo ""` / results block:

```bash
# --- pending record store ---
PENDING_ROOT="$TMPDIR_TEST/pending"

assert_eq "$(SAFE_SCRIPTS_PENDING_DIR="$PENDING_ROOT" get_pending_dir)" "$PENDING_ROOT" \
    "get_pending_dir: env override"
assert_eq "$(get_pending_dir)" "${HOME}/.claude/safe-scripts/.pending" \
    "get_pending_dir: default path"

export SAFE_SCRIPTS_PENDING_DIR="$PENDING_ROOT"

write_pending_record "sess1" "git log --oneline -10 -- src/App.tsx" "agent-1" "Explore"
REC_FILE=$(ls "$PENDING_ROOT/sess1"/*.json | head -1)
assert_eq "$(jq -r '.command' "$REC_FILE")" "git log --oneline -10 -- src/App.tsx" \
    "write_pending_record: stores command"
assert_eq "$(jq -r '.status' "$REC_FILE")" "prompted" "write_pending_record: status prompted"
assert_eq "$(jq -r '.agent_type' "$REC_FILE")" "Explore" "write_pending_record: stores agent_type"
assert_eq "$(jq -r '.agent_id' "$REC_FILE")" "agent-1" "write_pending_record: stores agent_id"

FOUND=$(find_prompted_record "sess1" "git log --oneline -10 -- src/App.tsx")
assert_eq "$FOUND" "$REC_FILE" "find_prompted_record: exact match"
assert_eq "$(find_prompted_record "sess1" "git log")" "" \
    "find_prompted_record: no partial match"
assert_eq "$(find_prompted_record "nosess" "git log --oneline -10 -- src/App.tsx")" "" \
    "find_prompted_record: missing session returns empty"

approve_pending_record "$REC_FILE"
assert_eq "$(jq -r '.status' "$REC_FILE")" "approved" "approve_pending_record: flips status"
assert_eq "$(find_prompted_record "sess1" "git log --oneline -10 -- src/App.tsx")" "" \
    "find_prompted_record: skips approved records"

APPROVED=$(list_approved_records "sess1")
assert_eq "$(printf '%s' "$APPROVED" | jq 'length')" "1" "list_approved_records: one record"
assert_eq "$(printf '%s' "$APPROVED" | jq -r '.[0].command')" \
    "git log --oneline -10 -- src/App.tsx" "list_approved_records: returns command"

# duplicate command from a second (parallel) subagent → deduped
write_pending_record "sess1" "git log --oneline -10 -- src/App.tsx" "agent-2" "Plan"
approve_pending_record "$(find_prompted_record "sess1" "git log --oneline -10 -- src/App.tsx")"
assert_eq "$(list_approved_records "sess1" | jq 'length')" "1" \
    "list_approved_records: dedupes identical commands"

# malformed record file is skipped, not fatal
echo "not json" > "$PENDING_ROOT/sess1/broken.json"
assert_eq "$(list_approved_records "sess1" 2>/dev/null | jq 'length')" "1" \
    "list_approved_records: skips malformed record"

# prompted-only session → empty array
write_pending_record "sess2" "ls -la" "main" ""
assert_eq "$(list_approved_records "sess2")" "[]" \
    "list_approved_records: prompted-only returns []"

# missing session dir → empty array
assert_eq "$(list_approved_records "no-such-session")" "[]" \
    "list_approved_records: missing dir returns []"

clear_pending_session "sess1"
assert_false test -d "$PENDING_ROOT/sess1"
clear_pending_session ""
assert_true test -d "$PENDING_ROOT"

# sweep: old session dir removed, fresh one kept
mkdir -p "$PENDING_ROOT/old-sess" "$PENDING_ROOT/fresh-sess"
touch -m -t 202001010000 "$PENDING_ROOT/old-sess"
sweep_pending_dirs
assert_false test -d "$PENDING_ROOT/old-sess"
assert_true test -d "$PENDING_ROOT/fresh-sess"

unset SAFE_SCRIPTS_PENDING_DIR
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/safe-scripts/tests/test-lib.sh; echo "exit=$?"`
Expected: `command not found` errors for the new helpers (the first bare `write_pending_record` call aborts the script under `set -e`), exit non-zero.

- [ ] **Step 3: Implement the helpers**

In `plugins/safe-scripts/scripts/lib.sh`, insert after `find_heredoc_candidates` (before the `emit_context` comment block):

```bash
# Resolve the pending-record store root.
# Always home-based (ephemeral state, never the shareable scripts dir).
# SAFE_SCRIPTS_PENDING_DIR env overrides (tests).
get_pending_dir() {
    if [ -n "${SAFE_SCRIPTS_PENDING_DIR:-}" ]; then
        echo "$SAFE_SCRIPTS_PENDING_DIR"
        return
    fi
    echo "${HOME}/.claude/safe-scripts/.pending"
}

# Write a "prompted" record for a command that triggered a permission dialog.
# One file per record so parallel subagents never contend on a shared file.
# Usage: write_pending_record <session_id> <command> <agent_id> <agent_type>
# agent_id is the literal string "main" for main-agent records.
write_pending_record() {
    local session_id="$1" command="$2" agent_id="$3" agent_type="$4"
    local dir
    dir="$(get_pending_dir)/${session_id}"
    mkdir -p "$dir"
    local file="${dir}/$(date +%s)-$$-${RANDOM}.json"
    jq -n --arg cmd "$command" --arg aid "$agent_id" --arg atype "$agent_type" \
        --argjson ts "$(date +%s)" \
        '{"command":$cmd,"agent_id":$aid,"agent_type":$atype,"status":"prompted","ts":$ts}' \
        > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Echo the path of the first "prompted" record whose command is an exact
# string match, or nothing.
# Usage: find_prompted_record <session_id> <command>
find_prompted_record() {
    local session_id="$1" command="$2"
    local dir f
    dir="$(get_pending_dir)/${session_id}"
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.json; do
        [ -f "$f" ] || continue
        if jq -e --arg cmd "$command" \
            'select(.status=="prompted" and .command==$cmd)' "$f" >/dev/null 2>&1; then
            echo "$f"
            return 0
        fi
    done
}

# Flip a record to approved (atomic rewrite).
# Usage: approve_pending_record <record_file>
approve_pending_record() {
    local file="$1"
    jq '.status="approved"' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Echo a JSON array of approved records for the session, deduped by command.
# Malformed record files are skipped with a warning. Missing dir → [].
# Usage: list_approved_records <session_id>
list_approved_records() {
    local session_id="$1"
    local dir f out="[]"
    dir="$(get_pending_dir)/${session_id}"
    if [ ! -d "$dir" ]; then
        printf '[]'
        return
    fi
    for f in "$dir"/*.json; do
        [ -f "$f" ] || continue
        if ! jq . "$f" >/dev/null 2>&1; then
            printf 'safe-scripts: warning: malformed pending record %s, skipping\n' "$f" >&2
            continue
        fi
        out=$(printf '%s' "$out" | jq --slurpfile rec "$f" '. + $rec')
    done
    printf '%s' "$out" | jq -c '[ .[] | select(.status=="approved") ] | unique_by(.command)'
}

# Delete a session's pending dir. No-op on empty session_id (never
# deletes the store root).
# Usage: clear_pending_session <session_id>
clear_pending_session() {
    local session_id="$1"
    [ -z "$session_id" ] && return 0
    rm -rf "$(get_pending_dir)/${session_id:?}"
}

# Delete pending session dirs older than 24h (sessions that ended
# before a drain).
sweep_pending_dirs() {
    local root
    root="$(get_pending_dir)"
    [ -d "$root" ] || return 0
    find "$root" -mindepth 1 -maxdepth 1 -type d -mtime +0 -exec rm -rf {} + 2>/dev/null || true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/safe-scripts/tests/test-lib.sh`
Expected: all new `pending`/`sweep` assertions PASS, `Results: N passed, 0 failed`, exit 0. Also run the full suite: `bash plugins/safe-scripts/tests/run-tests.sh` — all suites pass (nothing else changed yet).

- [ ] **Step 5: Commit**

```bash
git add plugins/safe-scripts/scripts/lib.sh plugins/safe-scripts/tests/test-lib.sh
git commit -m "feat(safe-scripts): add pending-record store helpers to lib.sh"
```

---

### Task 2: permission-request writes records; offer text moves out

**Files:**
- Modify: `plugins/safe-scripts/hooks/permission-request` (full rewrite of body)
- Test: `plugins/safe-scripts/tests/test-permission-request.sh` (full rewrite)

**Interfaces:**
- Consumes: `write_pending_record`, `get_pending_dir` from Task 1; `emit_context` (existing).
- Produces: pending `prompted` records consumed by Tasks 3–4; `[SAFE_SCRIPT_DEFERRED]` context (subagent only). **Main-agent invocations emit no stdout.** Missing `session_id` falls back to the literal string `unknown` (Tasks 3–4 use the same fallback so records match up).

- [ ] **Step 1: Rewrite the test file (failing tests)**

Replace the entire contents of `plugins/safe-scripts/tests/test-permission-request.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

assert_eq() {
    if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "PASS: $3"
    else FAIL=$((FAIL+1)); echo "FAIL: $3"; echo "  want: $2"; echo "  got:  $1"; fi
}
assert_contains() {
    if echo "$1" | grep -q "$2"; then PASS=$((PASS+1)); echo "PASS: contains '$2'"
    else FAIL=$((FAIL+1)); echo "FAIL: expected '$2'"; echo "  in: $1"; fi
}

TMPDIR_TEST=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST'" EXIT
PENDING_ROOT="$TMPDIR_TEST/pending"

run_hook() {
    local input="$1"
    printf '%s' "$input" | \
        CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.." \
        SAFE_SCRIPTS_PENDING_DIR="$PENDING_ROOT" \
        bash "${SCRIPT_DIR}/../hooks/permission-request"
}

# Test 1: main agent (no agent_id) → no stdout, prompted record written
INPUT='{"session_id":"s-main","tool_name":"Bash","tool_input":{"command":"git log --oneline -10 -- src/Button.tsx"}}'
OUTPUT=$(run_hook "$INPUT")
assert_eq "$OUTPUT" "" "main agent: emits nothing"
REC_FILE=$(ls "$PENDING_ROOT/s-main"/*.json | head -1)
assert_eq "$(jq -r '.command' "$REC_FILE")" "git log --oneline -10 -- src/Button.tsx" \
    "main agent: record stores command"
assert_eq "$(jq -r '.status' "$REC_FILE")" "prompted" "main agent: record is prompted"
assert_eq "$(jq -r '.agent_id' "$REC_FILE")" "main" "main agent: agent_id is 'main'"

# Test 2: subagent (agent_id present) → SAFE_SCRIPT_DEFERRED, record written
INPUT='{"session_id":"s-sub","agent_id":"a1","agent_type":"Explore","tool_name":"Bash","tool_input":{"command":"rg -n TODO src/"}}'
OUTPUT=$(run_hook "$INPUT")
CONTEXT=$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$CONTEXT" "SAFE_SCRIPT_DEFERRED" "subagent: emits SAFE_SCRIPT_DEFERRED"
if printf '%s' "$CONTEXT" | grep -q "OFFER_SAFE_SCRIPT"; then
    FAIL=$((FAIL+1)); echo "FAIL: subagent context must not contain OFFER_SAFE_SCRIPT"
else
    PASS=$((PASS+1)); echo "PASS: subagent context has no OFFER_SAFE_SCRIPT"
fi
REC_FILE=$(ls "$PENDING_ROOT/s-sub"/*.json | head -1)
assert_eq "$(jq -r '.agent_id' "$REC_FILE")" "a1" "subagent: record stores agent_id"
assert_eq "$(jq -r '.agent_type' "$REC_FILE")" "Explore" "subagent: record stores agent_type"

# Test 3: subagent output is valid JSON with PermissionRequest event name
printf '%s' "$OUTPUT" | jq . > /dev/null
assert_eq "$?" "0" "subagent output is valid JSON"
assert_eq "$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.hookEventName')" \
    "PermissionRequest" "hookEventName is PermissionRequest"

# Test 4: missing command → no output, no record
INPUT='{"session_id":"s-empty","tool_name":"Bash","tool_input":{}}'
OUTPUT=$(run_hook "$INPUT")
assert_eq "$OUTPUT" "" "missing command: emits nothing"
if [ -d "$PENDING_ROOT/s-empty" ]; then
    FAIL=$((FAIL+1)); echo "FAIL: missing command must not write a record"
else
    PASS=$((PASS+1)); echo "PASS: missing command writes no record"
fi

# Test 5: missing session_id → record written under 'unknown'
INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
run_hook "$INPUT" > /dev/null
REC_FILE=$(ls "$PENDING_ROOT/unknown"/*.json | head -1)
assert_eq "$(jq -r '.command' "$REC_FILE")" "ls -la" "missing session_id: falls back to 'unknown'"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/safe-scripts/tests/test-permission-request.sh; echo "exit=$?"`
Expected: FAIL on "main agent: emits nothing" (current hook emits `[OFFER_SAFE_SCRIPT]`) and the script aborts when `ls "$PENDING_ROOT/s-main"/*.json` finds nothing. Exit non-zero.

- [ ] **Step 3: Rewrite the hook**

Replace the entire contents of `plugins/safe-scripts/hooks/permission-request` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../scripts/lib.sh"

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)

[ -z "$COMMAND" ] && exit 0

# Record the prompt; approval is confirmed later by the PostToolUse(Bash)
# hook (which only fires if the command actually ran).
write_pending_record "$SESSION_ID" "$COMMAND" "${AGENT_ID:-main}" "$AGENT_TYPE"

# Main agent: say nothing here — the offer is emitted after the command
# runs, so denied commands never generate offers.
[ -z "$AGENT_ID" ] && exit 0

# Subagent: it has no conversation with the user, so it must not run the
# save flow. The main agent will offer after this subagent returns.
CONTEXT="[SAFE_SCRIPT_DEFERRED] This command needed user approval. Do NOT offer to save it as a safe script and do NOT invoke the safe-scripts skill — you have no direct conversation with the user. If approved, the main agent will offer to save it after you finish. Just continue your task."

emit_context "$CONTEXT" "PermissionRequest"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/safe-scripts/tests/test-permission-request.sh`
Expected: all 13 assertions pass, `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/safe-scripts/hooks/permission-request plugins/safe-scripts/tests/test-permission-request.sh
git commit -m "feat(safe-scripts): permission-request records prompts, defers subagent offers"
```

---

### Task 3: post-tool-use-bash hook (approval detector + main-agent offer)

**Files:**
- Create: `plugins/safe-scripts/hooks/post-tool-use-bash` (mode 755)
- Modify: `plugins/safe-scripts/hooks/hooks.json`
- Modify: `plugins/safe-scripts/skills/safe-scripts/SKILL.md:47` (one wording line)
- Modify: `plugins/safe-scripts/tests/run-tests.sh`
- Test: `plugins/safe-scripts/tests/test-post-tool-use-bash.sh` (new)

**Interfaces:**
- Consumes: `get_pending_dir`, `find_prompted_record`, `approve_pending_record`, `emit_context` from lib.sh; `prompted` records from Task 2.
- Produces: `approved` records (subagent path, consumed by Task 4); `[OFFER_SAFE_SCRIPT]` PostToolUse context (main-agent path — same marker and skill instructions as the pre-change permission-request hook, so the existing SKILL.md flow keeps working).

- [ ] **Step 1: Write the failing test file**

Create `plugins/safe-scripts/tests/test-post-tool-use-bash.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../scripts/lib.sh"

assert_eq() {
    if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "PASS: $3"
    else FAIL=$((FAIL+1)); echo "FAIL: $3"; echo "  want: $2"; echo "  got:  $1"; fi
}
assert_contains() {
    if echo "$1" | grep -q "$2"; then PASS=$((PASS+1)); echo "PASS: contains '$2'"
    else FAIL=$((FAIL+1)); echo "FAIL: expected '$2'"; echo "  in: $1"; fi
}

TMPDIR_TEST=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST'" EXIT
export SAFE_SCRIPTS_PENDING_DIR="$TMPDIR_TEST/pending"

run_hook() {
    local input="$1"
    printf '%s' "$input" | \
        CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.." \
        SAFE_SCRIPTS_PENDING_DIR="$SAFE_SCRIPTS_PENDING_DIR" \
        bash "${SCRIPT_DIR}/../hooks/post-tool-use-bash"
}

# Test 1: no pending dir for session → clean, silent exit
OUTPUT=$(run_hook '{"session_id":"none","tool_name":"Bash","tool_input":{"command":"ls"}}')
assert_eq "$OUTPUT" "" "no pending dir: silent exit"

# Test 2: subagent record flips to approved, no stdout
write_pending_record "s1" "rg -n TODO src/" "a1" "Explore"
OUTPUT=$(run_hook '{"session_id":"s1","agent_id":"a1","agent_type":"Explore","tool_name":"Bash","tool_input":{"command":"rg -n TODO src/"}}')
assert_eq "$OUTPUT" "" "subagent: no stdout"
REC_FILE=$(ls "$SAFE_SCRIPTS_PENDING_DIR/s1"/*.json | head -1)
assert_eq "$(jq -r '.status' "$REC_FILE")" "approved" "subagent: record flipped to approved"

# Test 3: main-agent record → OFFER_SAFE_SCRIPT emitted, record deleted
write_pending_record "s2" "git log --oneline -10 -- src/App.tsx" "main" ""
OUTPUT=$(run_hook '{"session_id":"s2","tool_name":"Bash","tool_input":{"command":"git log --oneline -10 -- src/App.tsx"}}')
CONTEXT=$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$CONTEXT" "OFFER_SAFE_SCRIPT" "main agent: emits OFFER_SAFE_SCRIPT"
assert_contains "$CONTEXT" "safe-scripts:safe-scripts" "main agent: instructs skill invocation"
assert_contains "$CONTEXT" "git log" "main agent: includes command preview"
assert_eq "$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.hookEventName')" \
    "PostToolUse" "hookEventName is PostToolUse"
assert_eq "$(ls "$SAFE_SCRIPTS_PENDING_DIR/s2" | wc -l | tr -d ' ')" "0" \
    "main agent: record consumed"

# Test 4: command mismatch (denied cmd still prompted, different cmd ran) → untouched
write_pending_record "s3" "rm -rf build/" "main" ""
OUTPUT=$(run_hook '{"session_id":"s3","tool_name":"Bash","tool_input":{"command":"ls -la"}}')
assert_eq "$OUTPUT" "" "mismatch: no output"
REC_FILE=$(ls "$SAFE_SCRIPTS_PENDING_DIR/s3"/*.json | head -1)
assert_eq "$(jq -r '.status' "$REC_FILE")" "prompted" "mismatch: record untouched"

# Test 5: long main-agent command truncated with ellipsis
LONG_CMD="git log $(printf 'x%.0s' {1..250})"
write_pending_record "s4" "$LONG_CMD" "main" ""
INPUT=$(jq -n --arg cmd "$LONG_CMD" '{"session_id":"s4","tool_name":"Bash","tool_input":{"command":$cmd}}')
OUTPUT=$(run_hook "$INPUT")
assert_contains "$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')" \
    "\.\.\." "long command truncated with ellipsis"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/safe-scripts/tests/test-post-tool-use-bash.sh; echo "exit=$?"`
Expected: aborts — `hooks/post-tool-use-bash: No such file or directory`. Exit non-zero.

- [ ] **Step 3: Implement the hook**

Create `plugins/safe-scripts/hooks/post-tool-use-bash`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../scripts/lib.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)

# Cheap guard: normal sessions have no pending records — exit immediately.
[ -d "$(get_pending_dir)/${SESSION_ID}" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

RECORD=$(find_prompted_record "$SESSION_ID" "$COMMAND")
[ -z "$RECORD" ] && exit 0

AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)

# Subagent: mark approved; the Task|Agent drain hook surfaces it to the
# main agent when this subagent returns.
if [ -n "$AGENT_ID" ]; then
    approve_pending_record "$RECORD"
    exit 0
fi

# Main agent: the command prompted and then ran — offer to save it now.
rm -f "$RECORD"

DISPLAY_CMD="${COMMAND:0:200}"
[ "${#COMMAND}" -gt 200 ] && DISPLAY_CMD="${DISPLAY_CMD}..."

CONTEXT="[OFFER_SAFE_SCRIPT] A Bash command you approved just ran: ${DISPLAY_CMD}

Invoke the safe-scripts:safe-scripts skill. In your next reply, offer the user:
(a) Save a generalized safe script — permanent auto-approval for this and similar commands
(b) Leave it — run as-is with approval each time"

emit_context "$CONTEXT" "PostToolUse"
```

Then: `chmod +x plugins/safe-scripts/hooks/post-tool-use-bash`

- [ ] **Step 4: Register the hook in hooks.json**

In `plugins/safe-scripts/hooks/hooks.json`, add a `PostToolUse` key after the `PreToolUse` array:

```json
"PostToolUse": [
  {
    "matcher": "Bash",
    "hooks": [
      {
        "type": "command",
        "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" post-tool-use-bash"
      }
    ]
  }
],
```

Validate: `jq . plugins/safe-scripts/hooks/hooks.json > /dev/null && echo OK` → `OK`

- [ ] **Step 5: Update SKILL.md wording for the new trigger point**

In `plugins/safe-scripts/skills/safe-scripts/SKILL.md`, the "On [OFFER_SAFE_SCRIPT]" section, replace the line:

```
A command just needed approval. In your **next reply**, before anything else, present this choice:
```

with:

```
A command you approved just ran. In your **next reply**, before anything else, present this choice:
```

- [ ] **Step 6: Wire the suite into run-tests.sh**

In `plugins/safe-scripts/tests/run-tests.sh`, after the `permission-request` line, add:

```bash
run_suite "post-tool-use-bash"   "${SCRIPT_DIR}/test-post-tool-use-bash.sh"
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bash plugins/safe-scripts/tests/run-tests.sh`
Expected: all suites including `post-tool-use-bash` pass, `Suite Results: 5 passed, 0 failed`, exit 0.

- [ ] **Step 8: Commit**

```bash
git add plugins/safe-scripts/hooks/post-tool-use-bash plugins/safe-scripts/hooks/hooks.json \
    plugins/safe-scripts/skills/safe-scripts/SKILL.md plugins/safe-scripts/tests/test-post-tool-use-bash.sh \
    plugins/safe-scripts/tests/run-tests.sh
git commit -m "feat(safe-scripts): add post-tool-use-bash approval detector"
```

---

### Task 4: post-tool-use-task drain hook + SKILL.md subagent section

**Files:**
- Create: `plugins/safe-scripts/hooks/post-tool-use-task` (mode 755)
- Modify: `plugins/safe-scripts/hooks/hooks.json`
- Modify: `plugins/safe-scripts/skills/safe-scripts/SKILL.md` (new section after "On [OFFER_SAFE_SCRIPT]")
- Modify: `plugins/safe-scripts/tests/run-tests.sh`
- Test: `plugins/safe-scripts/tests/test-post-tool-use-task.sh` (new)

**Interfaces:**
- Consumes: `list_approved_records`, `clear_pending_session`, `get_pending_dir`, `get_safe_scripts_dir`, `load_manifest`, `find_matching_script`, `emit_context` from lib.sh; `approved` records from Task 3.
- Produces: `[OFFER_SAFE_SCRIPT] (from subagent run)` PostToolUse context in the main agent; deletes the session's pending dir.

- [ ] **Step 1: Write the failing test file**

Create `plugins/safe-scripts/tests/test-post-tool-use-task.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../scripts/lib.sh"

assert_eq() {
    if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "PASS: $3"
    else FAIL=$((FAIL+1)); echo "FAIL: $3"; echo "  want: $2"; echo "  got:  $1"; fi
}
assert_contains() {
    if echo "$1" | grep -q "$2"; then PASS=$((PASS+1)); echo "PASS: contains '$2'"
    else FAIL=$((FAIL+1)); echo "FAIL: expected '$2'"; echo "  in: $1"; fi
}

TMPDIR_TEST=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST'" EXIT
export SAFE_SCRIPTS_PENDING_DIR="$TMPDIR_TEST/pending"
export SAFE_SCRIPTS_DIR="$TMPDIR_TEST/scripts"

run_hook() {
    local input="$1"
    printf '%s' "$input" | \
        CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.." \
        SAFE_SCRIPTS_PENDING_DIR="$SAFE_SCRIPTS_PENDING_DIR" \
        SAFE_SCRIPTS_DIR="$SAFE_SCRIPTS_DIR" \
        bash "${SCRIPT_DIR}/../hooks/post-tool-use-task"
}

# Test 1: approved records → offer emitted listing command + agent type, dir deleted
write_pending_record "s1" "rg -n TODO src/" "a1" "Explore"
approve_pending_record "$(find_prompted_record "s1" "rg -n TODO src/")"
OUTPUT=$(run_hook '{"session_id":"s1","tool_name":"Task","tool_input":{}}')
CONTEXT=$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$CONTEXT" "OFFER_SAFE_SCRIPT" "drain: emits OFFER_SAFE_SCRIPT"
assert_contains "$CONTEXT" "subagent" "drain: mentions subagent origin"
assert_contains "$CONTEXT" "rg -n TODO src/" "drain: lists approved command"
assert_contains "$CONTEXT" "Explore" "drain: lists agent type"
assert_contains "$CONTEXT" "safe-scripts:safe-scripts" "drain: instructs skill invocation"
assert_eq "$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.hookEventName')" \
    "PostToolUse" "hookEventName is PostToolUse"
if [ -d "$SAFE_SCRIPTS_PENDING_DIR/s1" ]; then
    FAIL=$((FAIL+1)); echo "FAIL: drain must delete session pending dir"
else
    PASS=$((PASS+1)); echo "PASS: drain deletes session pending dir"
fi

# Test 2: prompted-only (denied) records → no output, dir still deleted
write_pending_record "s2" "rm -rf build/" "a1" "Explore"
OUTPUT=$(run_hook '{"session_id":"s2","tool_name":"Task","tool_input":{}}')
assert_eq "$OUTPUT" "" "denied-only: no output"
if [ -d "$SAFE_SCRIPTS_PENDING_DIR/s2" ]; then
    FAIL=$((FAIL+1)); echo "FAIL: denied-only drain must still delete dir"
else
    PASS=$((PASS+1)); echo "PASS: denied-only drain deletes dir"
fi

# Test 3: command now covered by manifest → dropped
mkdir -p "$SAFE_SCRIPTS_DIR"
printf '{"version":1,"scripts":[{"name":"todo-scan","description":"Scan TODOs","script":"todo-scan.sh","usage":"todo-scan <dir>","patterns":["^rg -n TODO"]}]}' \
    > "$SAFE_SCRIPTS_DIR/manifest.json"
write_pending_record "s3" "rg -n TODO src/" "a1" "Explore"
approve_pending_record "$(find_prompted_record "s3" "rg -n TODO src/")"
OUTPUT=$(run_hook '{"session_id":"s3","tool_name":"Task","tool_input":{}}')
assert_eq "$OUTPUT" "" "manifest-covered command: no offer"
rm -f "$SAFE_SCRIPTS_DIR/manifest.json"

# Test 4: nested subagent (agent_id present) → no-op, dir untouched
write_pending_record "s4" "ls -la" "a2" "Plan"
approve_pending_record "$(find_prompted_record "s4" "ls -la")"
OUTPUT=$(run_hook '{"session_id":"s4","agent_id":"outer","agent_type":"claude","tool_name":"Task","tool_input":{}}')
assert_eq "$OUTPUT" "" "nested: no output"
assert_eq "$(ls "$SAFE_SCRIPTS_PENDING_DIR/s4"/*.json | wc -l | tr -d ' ')" "1" \
    "nested: pending dir untouched"

# Test 5: no pending dir at all → silent exit
OUTPUT=$(run_hook '{"session_id":"never-prompted","tool_name":"Task","tool_input":{}}')
assert_eq "$OUTPUT" "" "no pending dir: silent exit"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/safe-scripts/tests/test-post-tool-use-task.sh; echo "exit=$?"`
Expected: aborts — `hooks/post-tool-use-task: No such file or directory`. Exit non-zero.

- [ ] **Step 3: Implement the hook**

Create `plugins/safe-scripts/hooks/post-tool-use-task`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../scripts/lib.sh"

INPUT=$(cat)

# Only drain in the true main agent. Inside a nested subagent tree this
# hook fires too (agent_id present) — records surface when the top-level
# Task returns.
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
[ -n "$AGENT_ID" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -d "$(get_pending_dir)/${SESSION_ID}" ] || exit 0

RECORDS=$(list_approved_records "$SESSION_ID")
clear_pending_session "$SESSION_ID"

COUNT=$(printf '%s' "$RECORDS" | jq 'length' 2>/dev/null || echo 0)
[ "$COUNT" -eq 0 ] && exit 0

# Drop commands the manifest already covers (e.g. saved mid-run).
SCRIPTS_DIR="$(get_safe_scripts_dir)"
MANIFEST="$(load_manifest "$SCRIPTS_DIR")"

OFFERS=""
i=0
while [ "$i" -lt "$COUNT" ]; do
    CMD=$(printf '%s' "$RECORDS" | jq -r ".[$i].command")
    ATYPE=$(printf '%s' "$RECORDS" | jq -r ".[$i].agent_type // \"subagent\"")
    i=$((i+1))
    [ -n "$(find_matching_script "$CMD" "$MANIFEST")" ] && continue
    DISPLAY_CMD="${CMD:0:200}"
    [ "${#CMD}" -gt 200 ] && DISPLAY_CMD="${DISPLAY_CMD}..."
    OFFERS="${OFFERS}- (${ATYPE:-subagent}) ${DISPLAY_CMD}
"
done

[ -z "$OFFERS" ] && exit 0

CONTEXT="[OFFER_SAFE_SCRIPT] (from subagent run) While subagents were working, the user approved these Bash commands:
${OFFERS}
Invoke the safe-scripts:safe-scripts skill. In your next reply, offer to save the FIRST command as a generalized safe script:
(a) Save a generalized safe script — permanent auto-approval for this and similar commands
(b) Leave it — run as-is with approval each time
After the user resolves it, offer the next listed command the same way — one command per reply."

emit_context "$CONTEXT" "PostToolUse"
```

Then: `chmod +x plugins/safe-scripts/hooks/post-tool-use-task`

- [ ] **Step 4: Register the hook in hooks.json**

In `plugins/safe-scripts/hooks/hooks.json`, extend the `PostToolUse` array (after the `Bash` matcher object):

```json
{
  "matcher": "Task|Agent",
  "hooks": [
    {
      "type": "command",
      "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" post-tool-use-task"
    }
  ]
}
```

Validate: `jq . plugins/safe-scripts/hooks/hooks.json > /dev/null && echo OK` → `OK`

- [ ] **Step 5: Add the SKILL.md subagent section**

In `plugins/safe-scripts/skills/safe-scripts/SKILL.md`, insert after the "On [OFFER_SAFE_SCRIPT]" section (before `## Save Procedure`'s preceding `---`):

```markdown
---

## On [OFFER_SAFE_SCRIPT] (from subagent run)

The hook listed Bash commands the user approved while subagents were working. Offer them **one at a time**. In your next reply, before anything else:

> "While the <agent type> subagent was working, you approved: `<command>`. I can save a generalized version as a safe script — future similar commands would be auto-approved with no dialog. Want me to:
> **(a) Save as a safe script** — I'll generalize it, show you the script, and save it permanently
> **(b) Leave it** — keep approving it manually"

Wait for the user's response. If (a): follow the Save Procedure. Once resolved, offer the next listed command in your following reply, the same way. Never present more than one command per reply.
```

Also add the new trigger to the invocation list at the top of SKILL.md — the existing line already covers `[OFFER_SAFE_SCRIPT]`, so no change needed there (verify this while editing).

- [ ] **Step 6: Wire the suite into run-tests.sh**

In `plugins/safe-scripts/tests/run-tests.sh`, after the `post-tool-use-bash` line, add:

```bash
run_suite "post-tool-use-task"   "${SCRIPT_DIR}/test-post-tool-use-task.sh"
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bash plugins/safe-scripts/tests/run-tests.sh`
Expected: `Suite Results: 6 passed, 0 failed`, exit 0.

- [ ] **Step 8: Commit**

```bash
git add plugins/safe-scripts/hooks/post-tool-use-task plugins/safe-scripts/hooks/hooks.json \
    plugins/safe-scripts/skills/safe-scripts/SKILL.md plugins/safe-scripts/tests/test-post-tool-use-task.sh \
    plugins/safe-scripts/tests/run-tests.sh
git commit -m "feat(safe-scripts): drain subagent-approved commands into main-agent offers"
```

---

### Task 5: session-start sweep + wording update

**Files:**
- Modify: `plugins/safe-scripts/hooks/session-start`
- Test: `plugins/safe-scripts/tests/test-session-start.sh`

**Interfaces:**
- Consumes: `sweep_pending_dirs`, `get_pending_dir` from lib.sh.
- Produces: nothing new — housekeeping plus message wording.

- [ ] **Step 1: Extend the tests (failing)**

In `plugins/safe-scripts/tests/test-session-start.sh`:

Replace the `run_hook` function with (adds the pending-dir override so the sweep never touches the real home dir):

```bash
PENDING_ROOT="$TMPDIR_TEST/pending"

run_hook() {
    SAFE_SCRIPTS_DIR="$1" \
    SAFE_SCRIPTS_PENDING_DIR="$PENDING_ROOT" \
    CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR" \
        bash "${SCRIPT_DIR}/../hooks/session-start"
}
```

Append before the final results block:

```bash
# Test 5: stale pending session dirs are swept; fresh ones kept
mkdir -p "$PENDING_ROOT/old-sess" "$PENDING_ROOT/fresh-sess"
touch -m -t 202001010000 "$PENDING_ROOT/old-sess"
run_hook "$TMPDIR_TEST/empty" > /dev/null
if [ -d "$PENDING_ROOT/old-sess" ]; then
    FAIL=$((FAIL+1)); echo "FAIL: stale pending dir should be swept"
else
    PASS=$((PASS+1)); echo "PASS: stale pending dir swept"
fi
if [ -d "$PENDING_ROOT/fresh-sess" ]; then
    PASS=$((PASS+1)); echo "PASS: fresh pending dir kept"
else
    FAIL=$((FAIL+1)); echo "FAIL: fresh pending dir must be kept"
fi

# Test 6: onboarding wording reflects post-run offer timing
OUTPUT=$(run_hook "$TMPDIR_TEST/empty")
CONTEXT=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$CONTEXT" "runs" "onboarding mentions post-run offer timing"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/safe-scripts/tests/test-session-start.sh; echo "exit=$?"`
Expected: FAIL on "stale pending dir swept" and "onboarding mentions post-run offer timing". Exit non-zero.

- [ ] **Step 3: Implement**

In `plugins/safe-scripts/hooks/session-start`:

(a) After the `source` line block (right after `MANIFEST="$(load_manifest "$SCRIPTS_DIR")"`), add:

```bash
# Housekeeping: drop pending save-suggestions from sessions that ended
# before their drain (suggestions are session-scoped by design).
sweep_pending_dirs
```

(b) Replace the no-scripts message:

```bash
    CONTEXT="<safe-scripts>
No safe scripts saved yet. After you approve a Bash command and it runs, you will see an [OFFER_SAFE_SCRIPT] hint — invoke the safe-scripts:safe-scripts skill to offer the user a generalized pre-approved version.
</safe-scripts>"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/safe-scripts/tests/run-tests.sh`
Expected: `Suite Results: 6 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/safe-scripts/hooks/session-start plugins/safe-scripts/tests/test-session-start.sh
git commit -m "feat(safe-scripts): sweep stale pending suggestions at session start"
```

---

### Task 6: End-to-end hook-chain verification

**Files:**
- Test: `plugins/safe-scripts/tests/test-e2e-bubbling.sh` (new)
- Modify: `plugins/safe-scripts/tests/run-tests.sh`

**Interfaces:**
- Consumes: all three hooks as black boxes (stdin JSON → stdout JSON), exercising the full record lifecycle across hook processes.
- Produces: regression coverage for the full subagent flow: prompt → approve → drain.

- [ ] **Step 1: Write the failing test file**

Create `plugins/safe-scripts/tests/test-e2e-bubbling.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

assert_contains() {
    if echo "$1" | grep -q "$2"; then PASS=$((PASS+1)); echo "PASS: contains '$2'"
    else FAIL=$((FAIL+1)); echo "FAIL: expected '$2'"; echo "  in: $1"; fi
}
assert_eq() {
    if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "PASS: $3"
    else FAIL=$((FAIL+1)); echo "FAIL: $3"; echo "  want: $2"; echo "  got:  $1"; fi
}

TMPDIR_TEST=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST'" EXIT

hook() {
    local name="$1" input="$2"
    printf '%s' "$input" | \
        CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.." \
        SAFE_SCRIPTS_PENDING_DIR="$TMPDIR_TEST/pending" \
        SAFE_SCRIPTS_DIR="$TMPDIR_TEST/scripts" \
        bash "${SCRIPT_DIR}/../hooks/${name}"
}

SESS="e2e-sess"

# 1. Subagent command prompts → deferred note, record written
OUT=$(hook permission-request "{\"session_id\":\"$SESS\",\"agent_id\":\"sub1\",\"agent_type\":\"Explore\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rg -n TODO src/\"}}")
assert_contains "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')" \
    "SAFE_SCRIPT_DEFERRED" "e2e: subagent gets deferred note"

# 2. A second subagent command prompts but is DENIED (never runs)
hook permission-request "{\"session_id\":\"$SESS\",\"agent_id\":\"sub1\",\"agent_type\":\"Explore\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf build/\"}}" > /dev/null

# 3. Approved command runs → PostToolUse(Bash) flips it
OUT=$(hook post-tool-use-bash "{\"session_id\":\"$SESS\",\"agent_id\":\"sub1\",\"agent_type\":\"Explore\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rg -n TODO src/\"}}")
assert_eq "$OUT" "" "e2e: approval detector is silent in subagent"

# 4. Subagent returns → drain offers ONLY the approved command
OUT=$(hook post-tool-use-task "{\"session_id\":\"$SESS\",\"tool_name\":\"Task\",\"tool_input\":{}}")
CONTEXT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$CONTEXT" "OFFER_SAFE_SCRIPT" "e2e: drain emits offer"
assert_contains "$CONTEXT" "rg -n TODO src/" "e2e: approved command offered"
if printf '%s' "$CONTEXT" | grep -q "rm -rf build/"; then
    FAIL=$((FAIL+1)); echo "FAIL: denied command must not be offered"
else
    PASS=$((PASS+1)); echo "PASS: denied command not offered"
fi

# 5. Second drain (another Task returns) → nothing left, silent
OUT=$(hook post-tool-use-task "{\"session_id\":\"$SESS\",\"tool_name\":\"Task\",\"tool_input\":{}}")
assert_eq "$OUT" "" "e2e: second drain is silent"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run it to verify current state**

Run: `bash plugins/safe-scripts/tests/test-e2e-bubbling.sh; echo "exit=$?"`
Expected: PASS everywhere if Tasks 1–5 are correct (this task is integration regression coverage; if anything fails, fix the offending hook before proceeding — do not adjust the test to pass).

- [ ] **Step 3: Wire into run-tests.sh**

In `plugins/safe-scripts/tests/run-tests.sh`, after the `post-tool-use-task` line, add:

```bash
run_suite "e2e-bubbling"         "${SCRIPT_DIR}/test-e2e-bubbling.sh"
```

- [ ] **Step 4: Run the full suite**

Run: `bash plugins/safe-scripts/tests/run-tests.sh`
Expected: `Suite Results: 7 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/safe-scripts/tests/test-e2e-bubbling.sh plugins/safe-scripts/tests/run-tests.sh
git commit -m "test(safe-scripts): end-to-end coverage for subagent save bubbling"
```

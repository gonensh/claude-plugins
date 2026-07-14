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

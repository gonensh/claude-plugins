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

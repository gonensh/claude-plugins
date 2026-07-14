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

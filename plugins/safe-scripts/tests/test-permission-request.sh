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

run_hook() {
    local input="$1"
    printf '%s' "$input" | CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.." \
        bash "${SCRIPT_DIR}/../hooks/permission-request"
}

# Test 1: emits OFFER_SAFE_SCRIPT marker
INPUT='{"tool_name":"Bash","tool_input":{"command":"git log --oneline -10 -- src/Button.tsx"}}'
OUTPUT=$(run_hook "$INPUT")
CONTEXT=$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$CONTEXT" "OFFER_SAFE_SCRIPT" "injects OFFER_SAFE_SCRIPT marker"

# Test 2: instructs Claude to invoke the skill
assert_contains "$CONTEXT" "safe-scripts:safe-scripts" "instructs Claude to invoke skill"

# Test 3: includes a truncated version of the command
assert_contains "$CONTEXT" "git log" "context includes command preview"

# Test 4: output is valid JSON
printf '%s' "$OUTPUT" | jq . > /dev/null
assert_eq "$?" "0" "output is valid JSON"

# Test 5: correct JSON shape for Claude Code
HOOK_EVENT=$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.hookEventName')
assert_eq "$HOOK_EVENT" "PermissionRequest" "hookEventName is PermissionRequest"

# Test 6: missing command field → still emits offer (command display is empty/blank but marker is present)
INPUT='{"tool_name":"Bash","tool_input":{}}'
OUTPUT=$(run_hook "$INPUT")
assert_contains "$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')" \
    "OFFER_SAFE_SCRIPT" "missing command still emits OFFER_SAFE_SCRIPT"

# Test 7: long command is truncated to ≤200 chars in display
LONG_CMD=$(printf 'git log %0.s' {1..20})  # ~120 chars; pad to >200
LONG_CMD="${LONG_CMD}$(printf 'x%.0s' {1..100})"  # force >200 chars total
INPUT=$(jq -n --arg cmd "$LONG_CMD" '{"tool_name":"Bash","tool_input":{"command":$cmd}}')
OUTPUT=$(run_hook "$INPUT")
CONTEXT=$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$CONTEXT" "..." "long command is truncated with ellipsis"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

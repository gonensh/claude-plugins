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

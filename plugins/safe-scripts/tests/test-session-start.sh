#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/." && pwd)"

assert_eq() {
    if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "PASS: $3"
    else FAIL=$((FAIL+1)); echo "FAIL: $3"; echo "  want: $2"; echo "  got:  $1"; fi
}
assert_contains() {
    if echo "$1" | grep -q "$2"; then PASS=$((PASS+1)); echo "PASS: contains '$2'"
    else FAIL=$((FAIL+1)); echo "FAIL: expected to contain '$2'"; echo "  in: $1"; fi
}

TMPDIR_TEST=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST'" EXIT

run_hook() {
    SAFE_SCRIPTS_DIR="$1" CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR" \
        bash "${SCRIPT_DIR}/../hooks/session-start"
}

# Test 1: empty safe-scripts dir → onboarding note
OUTPUT=$(run_hook "$TMPDIR_TEST/empty")
CONTEXT=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$CONTEXT" "safe-scripts"
assert_contains "$CONTEXT" "No safe scripts"

# Test 2: manifest with scripts → catalog injected
mkdir -p "$TMPDIR_TEST/with-scripts"
cat > "$TMPDIR_TEST/with-scripts/manifest.json" <<'JSON'
{
  "version": 1,
  "scripts": [
    {
      "name": "git-file-log",
      "description": "Show git history for a specific file",
      "script": "git-file-log.sh",
      "usage": "git-file-log <file> [--limit N]",
      "patterns": ["^git log"]
    }
  ]
}
JSON
OUTPUT=$(run_hook "$TMPDIR_TEST/with-scripts")
CONTEXT=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$CONTEXT" "git-file-log"
assert_contains "$CONTEXT" "Show git history"
assert_contains "$CONTEXT" "SAFE_SCRIPT_AVAILABLE"
assert_contains "$CONTEXT" "OFFER_SAFE_SCRIPT"

# Test 3: output is valid JSON
echo "$OUTPUT" | jq . > /dev/null
assert_eq "$?" "0" "session-start output is valid JSON"

# Test 4: catalog lists usage string (not just name)
assert_contains "$CONTEXT" "git-file-log <file> [--limit N]"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

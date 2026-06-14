#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

assert_eq() {
    if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "PASS: $3"
    else FAIL=$((FAIL+1)); echo "FAIL: $3"; echo "  want: $2"; echo "  got:  $1"; fi
}
assert_contains() {
    if echo "$1" | grep -q "$2"; then PASS=$((PASS+1)); echo "PASS: contains '$2'"
    else FAIL=$((FAIL+1)); echo "FAIL: expected '$2'"; echo "  in: $1"; fi
}
assert_empty() {
    if [ -z "$1" ]; then PASS=$((PASS+1)); echo "PASS: $2"
    else FAIL=$((FAIL+1)); echo "FAIL: $2 (expected empty, got '$1')"; fi
}

TMPDIR_TEST=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST'" EXIT

mkdir -p "$TMPDIR_TEST"
cat > "$TMPDIR_TEST/manifest.json" <<'JSON'
{
  "version": 1,
  "scripts": [
    {
      "name": "git-file-log",
      "description": "Show git history for a specific file",
      "script": "git-file-log.sh",
      "usage": "git-file-log <file> [--limit N]",
      "patterns": ["^git log (--oneline )?(-[0-9]+ )?-- .+"]
    },
    {
      "name": "analyze-csv",
      "description": "Analyze a CSV file with pandas",
      "script": "analyze-csv.py",
      "usage": "analyze-csv <file>",
      "patterns": ["^python3?\\s+<<\\s*'?EOF"],
      "heredoc": true
    }
  ]
}
JSON

run_hook() {
    local input="$1"
    printf '%s' "$input" | SAFE_SCRIPTS_DIR="$TMPDIR_TEST" CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR" \
        bash "${SCRIPT_DIR}/hooks/pre-tool-use"
}

# Test 1: matching command → block with SAFE_SCRIPT_AVAILABLE
INPUT='{"tool_name":"Bash","tool_input":{"command":"git log --oneline -10 -- src/Button.tsx"}}'
OUTPUT=$(run_hook "$INPUT")
assert_eq "$(printf '%s' "$OUTPUT" | jq -r '.decision')" "block" "standard match: decision is block"
assert_contains "$(printf '%s' "$OUTPUT" | jq -r '.reason')" "SAFE_SCRIPT_AVAILABLE" "standard match: reason has marker"
assert_contains "$(printf '%s' "$OUTPUT" | jq -r '.reason')" "git-file-log" "standard match: reason names script"

# Test 2: non-matching command → empty output (pass-through)
INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
OUTPUT=$(run_hook "$INPUT")
assert_empty "$OUTPUT" "no match: empty output"

# Test 3: heredoc with candidates → block with HEREDOC_POSSIBLE_MATCH
INPUT='{"tool_name":"Bash","tool_input":{"command":"python3 << '\''EOF'\''\nimport pandas as pd\nEOF"}}'
OUTPUT=$(run_hook "$INPUT")
assert_eq "$(printf '%s' "$OUTPUT" | jq -r '.decision')" "block" "heredoc: decision is block"
assert_contains "$(printf '%s' "$OUTPUT" | jq -r '.reason')" "HEREDOC_POSSIBLE_MATCH" "heredoc: reason has marker"
assert_contains "$(printf '%s' "$OUTPUT" | jq -r '.reason')" "analyze-csv" "heredoc: reason lists candidate"

# Test 4: heredoc with no candidates → pass-through
INPUT='{"tool_name":"Bash","tool_input":{"command":"python3 << '\''EOF'\''\nprint(1)\nEOF"}}'
OUTPUT=$(printf '%s' "$INPUT" | SAFE_SCRIPTS_DIR="$TMPDIR_TEST/empty" CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR" \
    bash "${SCRIPT_DIR}/hooks/pre-tool-use")
assert_empty "$OUTPUT" "heredoc with no candidates: pass-through"

# Test 5: missing command field → pass-through
INPUT='{"tool_name":"Bash","tool_input":{}}'
OUTPUT=$(run_hook "$INPUT")
assert_empty "$OUTPUT" "missing command: pass-through"

# Test 6: block output is valid JSON
INPUT='{"tool_name":"Bash","tool_input":{"command":"git log --oneline -10 -- src/Button.tsx"}}'
OUTPUT=$(run_hook "$INPUT")
printf '%s' "$OUTPUT" | jq . > /dev/null
assert_eq "$?" "0" "block output is valid JSON"

# Test 7: reason includes the full path to the safe script
assert_contains "$(printf '%s' "$OUTPUT" | jq -r '.reason')" "$TMPDIR_TEST/git-file-log.sh" \
    "reason includes full script path"

# Test 8: heredoc:true entry NOT matched by standard path even when pattern matches
INPUT='{"tool_name":"Bash","tool_input":{"command":"python3 analyze.py --input data.csv"}}'
OUTPUT=$(run_hook "$INPUT")
assert_empty "$OUTPUT" "heredoc:true entry skipped by standard matcher"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

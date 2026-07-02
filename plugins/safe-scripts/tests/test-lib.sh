#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/scripts/lib.sh"

assert_eq() {
    if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "PASS: $3"
    else FAIL=$((FAIL+1)); echo "FAIL: $3"; echo "  want: $2"; echo "  got:  $1"; fi
}
assert_true() {
    if "$@" 2>/dev/null; then PASS=$((PASS+1)); echo "PASS: $*"
    else FAIL=$((FAIL+1)); echo "FAIL: $*"; fi
}
assert_false() {
    if ! "$@" 2>/dev/null; then PASS=$((PASS+1)); echo "PASS: (not) $*"
    else FAIL=$((FAIL+1)); echo "FAIL: expected false: $*"; fi
}

TMPDIR_TEST=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST'" EXIT

# --- get_safe_scripts_dir ---
assert_eq "$(SAFE_SCRIPTS_DIR="$TMPDIR_TEST" get_safe_scripts_dir)" "$TMPDIR_TEST" \
    "get_safe_scripts_dir: env override"

assert_eq "$(get_safe_scripts_dir)" "${HOME}/.claude/safe-scripts" \
    "get_safe_scripts_dir: default path"

mkdir -p "$TMPDIR_TEST/project/.claude"
printf '{"safe_scripts_dir":"%s/custom"}' "$TMPDIR_TEST" > "$TMPDIR_TEST/project/.claude/safe-scripts-config.json"
assert_eq "$(cd "$TMPDIR_TEST/project" && get_safe_scripts_dir)" "$TMPDIR_TEST/custom" \
    "get_safe_scripts_dir: project config override"

# --- load_manifest ---
assert_eq "$(load_manifest "$TMPDIR_TEST/empty")" '{"version":1,"scripts":[]}' \
    "load_manifest: missing dir returns empty manifest"

mkdir -p "$TMPDIR_TEST/with-manifest"
printf '{"version":1,"scripts":[{"name":"test-script"}]}' > "$TMPDIR_TEST/with-manifest/manifest.json"
assert_eq "$(load_manifest "$TMPDIR_TEST/with-manifest" | jq -r '.scripts[0].name')" "test-script" \
    "load_manifest: reads manifest file"

# --- is_heredoc ---
assert_true is_heredoc "python3 << 'EOF'"
assert_true is_heredoc 'bash <<EOF'
assert_true is_heredoc "node << 'SCRIPT'"
assert_false is_heredoc "git log --oneline -10 -- src/App.tsx"
assert_false is_heredoc "python3 analyze.py --input data.csv"

# --- find_matching_script ---
MANIFEST='{"version":1,"scripts":[{"name":"git-file-log","description":"Show git history","script":"git-file-log.sh","usage":"git-file-log <file> [--limit N]","patterns":["^git log (--oneline )?(-[0-9]+ )?-- .+"]}]}'

MATCH=$(find_matching_script "git log --oneline -10 -- src/Button.tsx" "$MANIFEST")
assert_eq "$(echo "$MATCH" | jq -r '.name')" "git-file-log" \
    "find_matching_script: matches git log variant"

MATCH=$(find_matching_script "git log -- src/App.tsx" "$MANIFEST")
assert_eq "$(echo "$MATCH" | jq -r '.name')" "git-file-log" \
    "find_matching_script: matches git log without --oneline"

NO_MATCH=$(find_matching_script "ls -la" "$MANIFEST")
assert_eq "$NO_MATCH" "" "find_matching_script: no match returns empty"

# heredoc:true entries are skipped even when patterns match a non-heredoc command
HD_MANIFEST='{"version":1,"scripts":[{"name":"analyze-csv","heredoc":true,"description":"CSV","script":"analyze-csv.py","usage":"analyze-csv <file>","patterns":["^python3"]}]}'
SKIPPED=$(find_matching_script "python3 analyze.py --input data.csv" "$HD_MANIFEST")
assert_eq "$SKIPPED" "" "find_matching_script: skips heredoc:true entry even when pattern matches"

# --- find_heredoc_candidates ---
HDMANIFEST='{"version":1,"scripts":[{"name":"analyze-csv","heredoc":true,"description":"Analyze a CSV"},{"name":"git-log","description":"Git log"}]}'
CANDIDATES=$(find_heredoc_candidates "$HDMANIFEST")
if echo "$CANDIDATES" | grep -q "analyze-csv"; then
    PASS=$((PASS+1)); echo "PASS: find_heredoc_candidates: includes heredoc entry"
else
    FAIL=$((FAIL+1)); echo "FAIL: find_heredoc_candidates: missing analyze-csv"
fi
if ! echo "$CANDIDATES" | grep -q "git-log"; then
    PASS=$((PASS+1)); echo "PASS: find_heredoc_candidates: excludes non-heredoc entry"
else
    FAIL=$((FAIL+1)); echo "FAIL: find_heredoc_candidates: should not include git-log"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

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

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

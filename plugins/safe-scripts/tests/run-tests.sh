#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0

run_suite() {
    local name="$1"
    local file="$2"
    echo "=== $name ==="
    if [ ! -f "$file" ]; then
        echo "MISSING: $file" >&2
        TOTAL_FAIL=$((TOTAL_FAIL+1))
        echo ""
        return
    fi
    if bash "$file"; then
        TOTAL_PASS=$((TOTAL_PASS+1))
    else
        TOTAL_FAIL=$((TOTAL_FAIL+1))
    fi
    echo ""
}

run_suite "lib.sh"               "${SCRIPT_DIR}/test-lib.sh"
run_suite "session-start"        "${SCRIPT_DIR}/test-session-start.sh"
run_suite "pre-tool-use"         "${SCRIPT_DIR}/test-pre-tool-use.sh"
run_suite "permission-request"   "${SCRIPT_DIR}/test-permission-request.sh"
run_suite "post-tool-use-bash"   "${SCRIPT_DIR}/test-post-tool-use-bash.sh"

echo "=== Suite Results: ${TOTAL_PASS} passed, ${TOTAL_FAIL} failed ==="
[ "$TOTAL_FAIL" -eq 0 ]

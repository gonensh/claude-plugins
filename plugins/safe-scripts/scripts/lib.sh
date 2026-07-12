#!/usr/bin/env bash
# Shared utilities for safe-scripts hooks.
# Source this file — do not execute directly.

# Resolve the safe-scripts directory.
# Priority: SAFE_SCRIPTS_DIR env (tests/override) > .claude/safe-scripts-config.json > default.
get_safe_scripts_dir() {
    if [ -n "${SAFE_SCRIPTS_DIR:-}" ]; then
        echo "$SAFE_SCRIPTS_DIR"
        return
    fi
    local config=".claude/safe-scripts-config.json"
    if [ -f "$config" ]; then
        local dir
        dir=$(jq -r '.safe_scripts_dir // empty' "$config" 2>/dev/null)
        if [ -n "$dir" ]; then
            # Resolve relative paths against cwd
            if [[ "$dir" != /* ]]; then
                dir="$(pwd)/${dir}"
            fi
            echo "$dir"
            return
        fi
    fi
    echo "${HOME}/.claude/safe-scripts"
}

# Read manifest.json from dir, or return an empty-scripts manifest.
load_manifest() {
    local dir="$1"
    local manifest="${dir}/manifest.json"
    if [ -f "$manifest" ]; then
        if ! jq . "$manifest" >/dev/null 2>&1; then
            printf 'safe-scripts: warning: malformed manifest at %s, using empty\n' "$manifest" >&2
            printf '{"version":1,"scripts":[]}'
        else
            cat "$manifest"
        fi
    else
        printf '{"version":1,"scripts":[]}'
    fi
}

# Return true if the command contains a heredoc redirection operator (<<).
# Requires << to be preceded by whitespace or appear at start, to avoid
# false-positives from quoted strings like grep "<<EOF" file.txt.
is_heredoc() {
    local command="$1"
    printf '%s\n' "$command" | grep -qE '(^|\s)<<\s*'"'"'?[A-Z_a-z]+'
}

# Find the first manifest entry whose patterns match the command.
# Returns the JSON object of the matching entry, or empty string.
# Skips entries with heredoc:true.
find_matching_script() {
    local command="$1"
    local manifest="$2"
    echo "$manifest" | jq -c --arg cmd "$command" '
        [ .scripts[] | select(
            (.heredoc // false | not) and
            (.patterns // [] | map(
                . as $pat | try ($cmd | test($pat)) catch false
            ) | any)
        ) ] | first // empty
    ' 2>/dev/null
}

# Return names+descriptions of scripts flagged heredoc:true.
find_heredoc_candidates() {
    local manifest="$1"
    echo "$manifest" | jq -r \
        '.scripts[] | select(.heredoc == true) | "- " + .name + ": " + .description' \
        2>/dev/null
}

# Resolve the pending-record store root.
# Always home-based (ephemeral state, never the shareable scripts dir).
# SAFE_SCRIPTS_PENDING_DIR env overrides (tests).
get_pending_dir() {
    if [ -n "${SAFE_SCRIPTS_PENDING_DIR:-}" ]; then
        echo "$SAFE_SCRIPTS_PENDING_DIR"
        return
    fi
    echo "${HOME}/.claude/safe-scripts/.pending"
}

# Write a "prompted" record for a command that triggered a permission dialog.
# One file per record so parallel subagents never contend on a shared file.
# Usage: write_pending_record <session_id> <command> <agent_id> <agent_type>
# agent_id is the literal string "main" for main-agent records.
write_pending_record() {
    local session_id="$1" command="$2" agent_id="$3" agent_type="$4"
    local dir
    dir="$(get_pending_dir)/${session_id}"
    mkdir -p "$dir"
    local file="${dir}/$(date +%s)-$$-${RANDOM}.json"
    jq -n --arg cmd "$command" --arg aid "$agent_id" --arg atype "$agent_type" \
        --argjson ts "$(date +%s)" \
        '{"command":$cmd,"agent_id":$aid,"agent_type":$atype,"status":"prompted","ts":$ts}' \
        > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Echo the path of the first "prompted" record whose command is an exact
# string match, or nothing.
# Usage: find_prompted_record <session_id> <command>
find_prompted_record() {
    local session_id="$1" command="$2"
    local dir f
    dir="$(get_pending_dir)/${session_id}"
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.json; do
        [ -f "$f" ] || continue
        if jq -e --arg cmd "$command" \
            'select(.status=="prompted" and .command==$cmd)' "$f" >/dev/null 2>&1; then
            echo "$f"
            return 0
        fi
    done
}

# Flip a record to approved (atomic rewrite).
# Usage: approve_pending_record <record_file>
approve_pending_record() {
    local file="$1"
    jq '.status="approved"' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Echo a JSON array of approved records for the session, deduped by command.
# Malformed record files are skipped with a warning. Missing dir → [].
# Usage: list_approved_records <session_id>
list_approved_records() {
    local session_id="$1"
    local dir f out="[]"
    dir="$(get_pending_dir)/${session_id}"
    if [ ! -d "$dir" ]; then
        printf '[]'
        return
    fi
    for f in "$dir"/*.json; do
        [ -f "$f" ] || continue
        if ! jq . "$f" >/dev/null 2>&1; then
            printf 'safe-scripts: warning: malformed pending record %s, skipping\n' "$f" >&2
            continue
        fi
        out=$(printf '%s' "$out" | jq --slurpfile rec "$f" '. + $rec')
    done
    printf '%s' "$out" | jq -c '[ .[] | select(.status=="approved") ] | unique_by(.command)'
}

# Delete a session's pending dir. No-op on empty session_id (never
# deletes the store root).
# Usage: clear_pending_session <session_id>
clear_pending_session() {
    local session_id="$1"
    [ -z "$session_id" ] && return 0
    rm -rf "$(get_pending_dir)/${session_id:?}"
}

# Delete pending session dirs older than 24h (sessions that ended
# before a drain).
sweep_pending_dirs() {
    local root
    root="$(get_pending_dir)"
    [ -d "$root" ] || return 0
    find "$root" -mindepth 1 -maxdepth 1 -type d -mtime +0 -exec rm -rf {} + 2>/dev/null || true
}

# Emit platform-aware additionalContext JSON.
# Platform detection order: Cursor (CURSOR_PLUGIN_ROOT) → Claude Code
# (CLAUDE_PLUGIN_ROOT set, COPILOT_CLI unset) → generic SDK / Copilot CLI.
# Usage: emit_context <context_string> <event_name>
emit_context() {
    local context="$1"
    local event_name="$2"
    if [ -n "${CURSOR_PLUGIN_ROOT:-}" ]; then
        jq -n --arg ctx "$context" '{"additional_context":$ctx}'
    elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -z "${COPILOT_CLI:-}" ]; then
        jq -n --arg ctx "$context" --arg evt "$event_name" \
            '{"hookSpecificOutput":{"hookEventName":$evt,"additionalContext":$ctx}}'
    else
        jq -n --arg ctx "$context" '{"additionalContext":$ctx}'
    fi
}

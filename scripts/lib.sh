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
        cat "$manifest"
    else
        printf '{"version":1,"scripts":[]}'
    fi
}

# Return true if the command is a heredoc inline script.
is_heredoc() {
    local command="$1"
    echo "$command" | grep -qE '<<\s*'"'"'?[A-Z_a-z]+'
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

# Return names+descriptions of all scripts in the manifest.
# When a heredoc is detected, all scripts are presented as candidates
# since any script could match the inline command.
find_heredoc_candidates() {
    local manifest="$1"
    echo "$manifest" | jq -r \
        '.scripts[] | "- " + .name + ": " + .description' \
        2>/dev/null
}

# Emit platform-aware additionalContext JSON.
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

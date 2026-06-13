# Design: `safe-scripts` Claude Code Plugin

**Date:** 2026-06-12
**Status:** Approved

---

## Problem

Claude Code frequently generates ad-hoc bash commands that require manual user approval. Each permission dialog forces the user to read, understand, and approve arbitrary shell code under time pressure — or blindly click through. Neither outcome is good. Over time, the same patterns repeat: the same `git log` variant, the same test runner invocation, the same file search — each needing fresh approval.

## Goal

A Claude Code plugin that builds a personal library of **safe scripts** — generalized, pre-approved bash wrappers — and teaches Claude to prefer them over raw bash. The first time a command needs approval, Claude offers to save a generalized version. From then on, Claude uses that script automatically, with no permission dialog.

---

## Architecture

### Hooks (three, each with one job)

| Hook | Trigger | Responsibility |
|---|---|---|
| `SessionStart` | Every new session | Read config + manifest; inject safe-script catalog into Claude's context |
| `PreToolUse` | Any `Bash` tool call | Pattern-match command against manifest; if match → block + inject redirect instruction |
| `PermissionRequest` | Any `Bash` permission request | Inject `[OFFER_SAFE_SCRIPT]` hint into Claude's context for the next turn |

**Why not block in `PermissionRequest`?**
`PermissionRequest` additionalContext is processed by Claude *after* the permission decision — Claude is blocked waiting for user action during the dialog. So the hook cannot truly intercept before approval. Instead, `PermissionRequest` acts as a learning trigger: Claude gets the hint on its next turn and offers to save. Meanwhile, the skill instructs Claude to *proactively* offer safe-script creation before writing raw bash in the first place — this is the primary interception path, not the hook.

### Skill (one, behavior-shaping)

The skill encodes four behaviors Claude must follow:

1. **Proactive preference** — Before writing raw bash, check the injected safe-script catalog. If a script covers the task, use it. Do not write a raw bash equivalent.
2. **On `[SAFE_SCRIPT_AVAILABLE]` injection** (PreToolUse blocked) — Do not retry the original command. Call the safe script shown in the injection with equivalent arguments.
3. **On `[OFFER_SAFE_SCRIPT]` injection** (PermissionRequest hint) — In the next reply, offer the user two options: (a) save a generalized safe script (permanent auto-approval), or (b) approve this one time.
4. **Save procedure** — When the user chooses to save: generalize the command into a parameterized script, write it to the configured directory, append its entry to `manifest.json`, add the script path to `settings.json` allow-list, then re-attempt the task via the new script.

The script generalization logic (parameterizing hardcoded values, writing regex match patterns) lives entirely in the skill — no LLM call inside the hook.

---

## Storage

### Paths

| Scope | Path |
|---|---|
| User-global default | `~/.claude/safe-scripts/` |
| Project override | `.claude/safe-scripts-config.json` → `{ "safe_scripts_dir": "./relative/or/absolute/path" }` |

Project config is optional. When present, it overrides the user-global path for the current working directory. This allows teams to commit a shared safe-scripts library to version control.

### Directory layout

```
~/.claude/safe-scripts/
├── manifest.json
├── git-file-log.sh
├── run-tests.sh
└── ...
```

### `manifest.json` schema

```json
{
  "version": 1,
  "scripts": [
    {
      "name": "git-file-log",
      "description": "Show git history for a specific file",
      "script": "git-file-log.sh",
      "usage": "git-file-log <file> [--limit N]",
      "patterns": ["^git log (--oneline )?(-[0-9]+ )?-- .+"],
      "added": "2026-06-12"
    }
  ]
}
```

**Fields:**
- `name` — short identifier, used in injected context
- `description` — one-line human summary, shown to Claude and user
- `script` — filename relative to the safe-scripts directory
- `usage` — signature shown to Claude for argument mapping
- `patterns` — array of regexes the `PreToolUse` hook tests against incoming commands
- `added` — ISO date the script was saved

### Allow-list registration

When a script is saved, the plugin appends a `Bash` allow-list entry to the nearest `settings.json` (project-local `.claude/settings.json` if in a project, otherwise `~/.claude/settings.json`):

```json
{
  "permissions": {
    "allow": ["Bash(~/.claude/safe-scripts/git-file-log.sh*)"]
  }
}
```

This ensures the safe script never triggers a permission dialog.

---

## Hook I/O Details

### Hook matcher configuration

All three hooks must be scoped to the `Bash` tool in `hooks.json` to avoid firing on `Read`, `Edit`, `Write`, etc.:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "..." }] }
    ],
    "PermissionRequest": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "..." }] }
    ]
  }
}
```

`SessionStart` uses the `startup|clear|compact` event matcher (no tool scoping needed).

### SessionStart

**Output (Claude Code format):**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<safe-scripts-catalog>\nAvailable safe scripts (prefer these over raw bash):\n- git-file-log <file> [--limit N] — Show git history for a specific file\n- run-tests [--watch] — Run the project test suite\n</safe-scripts-catalog>"
  }
}
```

If no scripts exist yet, the hook injects a short onboarding note instead.

### PreToolUse

**Input (stdin):** `{ "tool_name": "Bash", "tool_input": { "command": "git log --oneline -10 -- src/Button.tsx" } }`

**Match found — output:**
```json
{
  "decision": "block",
  "reason": "[SAFE_SCRIPT_AVAILABLE] name=git-file-log usage='git-file-log <file> [--limit N]' suggested_call='/home/user/.claude/safe-scripts/git-file-log.sh src/Button.tsx --limit 10'"
}
```

The hook expands the safe-scripts path using `$HOME` at runtime so Claude receives a fully-qualified path, not a `~`-relative string.

**No match — output:** *(nothing, exit 0)*

### PermissionRequest

**Input (stdin):** `{ "tool_name": "Bash", "tool_input": { "command": "..." } }`

**Output:**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "additionalContext": "[OFFER_SAFE_SCRIPT] command='git log --oneline -10 -- src/Button.tsx'"
  }
}
```

The permission dialog still appears. Claude processes the hint on its next turn and retroactively offers to save.

---

## Generalization Rules (skill-encoded)

When saving a new safe script from a command, Claude must:

1. **Identify hardcoded values** — file paths, numeric limits, branch names, test filters. These become positional arguments or named flags.
2. **Write a parameterized bash script** — includes a usage comment, argument parsing (`$1`, `$2`, or `getopts`/`while` for flags), and the generalized command.
3. **Generate regex patterns** — one or more patterns that match the original command and reasonable variants (with/without optional flags, different file paths, etc.).
4. **Choose a descriptive name** — verb-noun kebab-case (e.g., `git-file-log`, `run-tests`, `find-in-files`).
5. **Show the user the script before saving** — present the script content and name, wait for confirmation, then write to disk.

---

## Plugin Repository Structure

```
claude-safe-scripts/
├── .claude-plugin/
│   └── plugin.json              ← plugin manifest
├── hooks/
│   ├── hooks.json               ← hook event bindings
│   ├── run-hook.cmd             ← cross-platform hook runner (Windows compat)
│   ├── session-start            ← SessionStart script (no .sh extension for Windows compat)
│   ├── pre-tool-use             ← PreToolUse script
│   └── permission-request       ← PermissionRequest script
├── scripts/
│   └── lib.sh                   ← shared: config resolution, manifest loading, pattern matching
├── skills/
│   └── safe-scripts/
│       └── SKILL.md             ← behavior-shaping skill
├── tests/
│   └── ...                      ← unit tests for hook scripts
├── README.md
├── LICENSE
└── package.json
```

---

## User-Facing Flow Summary

**First run of a new command:**
1. Claude considers writing `git log --oneline -10 -- src/Button.tsx`
2. Skill instructs Claude to check catalog first → no match
3. Claude says: *"I need to run a git log command. I could save this as a safe script `git-file-log` so future runs are auto-approved. Want to save it, or run once?"*
4. User: *"Save it"* → Claude shows the generalized script, user confirms, script is saved and registered
5. Claude runs `~/.claude/safe-scripts/git-file-log.sh src/Button.tsx --limit 10` — no permission dialog

**Subsequent runs (same session or future sessions):**
1. Claude considers writing `git log --oneline -5 -- src/App.tsx`
2. SessionStart catalog is in context → Claude proactively calls `git-file-log src/App.tsx --limit 5`
3. No permission dialog, no interruption

**Slippage (Claude writes raw bash that matches a saved script):**
1. PreToolUse hook fires → pattern match found → blocks with `[SAFE_SCRIPT_AVAILABLE]`
2. Claude redirects to `git-file-log` with mapped arguments
3. No permission dialog

---

## Non-Goals

- No LLM call inside any hook (hooks are pure shell; all reasoning happens in Claude via the skill)
- No automatic saving without user confirmation
- No centralized script registry or cloud sync — library is local to the machine/project
- No support for non-Bash script runners (Python, Node, Perl) in v1 — Bash only; other interpreters can be added as future matchers

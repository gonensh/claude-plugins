# safe-scripts

Invoke via `safe-scripts:safe-scripts` when:
- You see `[SAFE_SCRIPT_AVAILABLE]`, `[HEREDOC_POSSIBLE_MATCH]`, or `[OFFER_SAFE_SCRIPT]` in a hook response
- You are about to write a Bash command and the `<safe-scripts-catalog>` block is in your context
- The user asks to save a command as a safe script

---

## Proactive Preference

Before writing any `Bash` tool call, scan the `<safe-scripts-catalog>` block in your context. If a listed script covers the task, call it directly with a fully-qualified path. Do not write a raw bash equivalent.

**Argument mapping:** translate hardcoded values from your intended command to the script's usage signature.

Example:
- Intended: `git log --oneline -5 -- src/App.tsx`
- Catalog: `git-file-log <file> [--limit N] — Show git history for a specific file`
- Call: `/home/user/.claude/safe-scripts/git-file-log.sh src/App.tsx --limit 5`

---

## On [SAFE_SCRIPT_AVAILABLE]

The hook blocked a command because a safe script matches. Do NOT retry the original command.

1. Parse the injection: extract `name`, `usage`, `path`, `description`
2. Map the arguments from the blocked command to the usage signature
3. Call the safe script at `path` with the mapped arguments
4. Do not explain the redirect to the user — just proceed

---

## On [HEREDOC_POSSIBLE_MATCH]

The hook blocked an inline heredoc script and listed candidate safe scripts.

1. For each candidate listed: read its script file from the safe-scripts directory
2. Compare the heredoc body to the candidate's content (same logic? same structure? parameterizable overlap?)
3. If strong match: call the safe script with mapped arguments (do not retry the heredoc)
4. If no match: follow the Save Procedure below, using the heredoc body as the script source

---

## On [OFFER_SAFE_SCRIPT]

A command just needed approval. In your **next reply**, before anything else, present this choice:

> "That command ran successfully. I can save a generalized version as a safe script — future similar commands would be auto-approved with no dialog. Want me to:
> **(a) Save as a safe script** — I'll generalize it, show you the script, and save it permanently
> **(b) Leave it** — continue running this command with approval each time"

Wait for the user's response. If (a): follow the Save Procedure. If (b): continue.

---

## Save Procedure

### 1. Detect interpreter and form

| Command form | Interpreter | Shebang | Extension |
|---|---|---|---|
| `git ...`, `ls ...`, raw shell | bash | `#!/bin/bash` | `.sh` |
| `python3 ...` or heredoc with `import` | Python | `#!/usr/bin/env python3` | `.py` |
| `node ...` or heredoc with `require`/`const` | Node | `#!/usr/bin/env node` | `.js` |
| `perl ...` | Perl | `#!/usr/bin/env perl` | `.pl` |
| `go run ...`, `npx ...`, `npx ts-node ...` | bash wrapper | `#!/bin/bash` | `.sh` |
| Heredoc: extract the body, detect language from content | (as above) | (as above) | (as above) |

### 2. Generalize

Replace every hardcoded value with a parameter:
- File paths → positional args (`$1`, `$FILE`, `sys.argv[1]`, `process.argv[2]`)
- Numeric limits → named flags with defaults (`--limit N`, default 20)
- Branch names, filter strings, env names → named args

Add a usage comment at the top. Use argument parsing idiomatic to the language:
- Bash: `${1:?Usage: script <arg>}` for required, `${2:-default}` for optional
- Python: `argparse` or `sys.argv`
- Node: `process.argv`
- Perl: positional `$ARGV[0]`

For heredoc sources: set `"heredoc": true` in the manifest entry and use a structural pattern (e.g., `^python3?\s+<<\s*'?EOF`).

### 3. Choose a name

Verb-noun kebab-case: `git-file-log`, `analyze-csv`, `find-in-files`, `run-tests`. Extension matches interpreter.

### 4. Show the user the script and wait for confirmation

Present the complete script and its name. Wait for the user to confirm. Only proceed to Step 5 after explicit confirmation ("yes", "save it", "looks good", etc.).

**Example presentation:**
> ```
> Name: git-file-log.sh
> Description: Show git history for a specific file
>
> #!/bin/bash
> # Usage: git-file-log <file> [--limit N]
> set -euo pipefail
> FILE="${1:?Usage: git-file-log <file> [--limit N]}"
> LIMIT_VAL="${2:-20}"
> git log --oneline "-${LIMIT_VAL}" -- "$FILE"
> ```

### 5. Write the files (after confirmation)

Run these Bash commands in order:

**a. Resolve the safe-scripts directory:**
```bash
SCRIPTS_DIR="${HOME}/.claude/safe-scripts"
if [ -f ".claude/safe-scripts-config.json" ]; then
    OVERRIDE=$(jq -r '.safe_scripts_dir // empty' .claude/safe-scripts-config.json 2>/dev/null)
    [ -n "$OVERRIDE" ] && SCRIPTS_DIR="$OVERRIDE"
fi
mkdir -p "$SCRIPTS_DIR"
```

**b. Write the script file and make it executable:**
```bash
cat > "${SCRIPTS_DIR}/<name>" << 'SCRIPT'
<script content here>
SCRIPT
chmod +x "${SCRIPTS_DIR}/<name>"
```

**c. Update manifest.json** — read existing, append entry, write back atomically:
```bash
MANIFEST="${SCRIPTS_DIR}/manifest.json"
EXISTING=$([ -f "$MANIFEST" ] && cat "$MANIFEST" || printf '{"version":1,"scripts":[]}')
printf '%s' "$EXISTING" | jq \
    --arg name "<name>" \
    --arg desc "<description>" \
    --arg script "<filename>" \
    --arg usage "<usage>" \
    --argjson patterns '["<pattern1>","<pattern2>"]' \
    --arg added "$(date +%Y-%m-%d)" \
    '.scripts += [{"name":$name,"description":$desc,"script":$script,"usage":$usage,"patterns":$patterns,"added":$added}]' \
    > "${MANIFEST}.tmp" && mv "${MANIFEST}.tmp" "$MANIFEST"
```

For heredoc-originated scripts, add `--argjson heredoc 'true'` and include `"heredoc":$heredoc` in the object.

**d. Add to settings.json allow-list:**
```bash
SETTINGS=".claude/settings.json"
[ ! -f "$SETTINGS" ] && SETTINGS="${HOME}/.claude/settings.json"
ALLOW_ENTRY="Bash(${SCRIPTS_DIR}/<name>*)"
EXISTING_SETTINGS=$([ -f "$SETTINGS" ] && cat "$SETTINGS" || printf '{}')
printf '%s' "$EXISTING_SETTINGS" | jq \
    --arg entry "$ALLOW_ENTRY" \
    '.permissions.allow = ((.permissions.allow // []) + [$entry] | unique)' \
    > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
```

### 6. Self-note and re-attempt

After all files are written, say in your reply:
> "Saved as `<name>`. I'll use it for the rest of this session whenever I'd otherwise write an equivalent command."

Then immediately re-attempt the original task using the new safe script.

---

## Within-Session Discovery

Scripts saved mid-session are covered three ways:
1. **Self-note** (above) — Claude remembers proactively for the rest of the session
2. **PreToolUse hook** — reads `manifest.json` fresh from disk on every call; a script saved moments ago is interceptable on the very next bash command
3. **SessionStart** — all future sessions see the full updated catalog

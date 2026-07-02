# safe-scripts

A Claude Code plugin that turns one-off Bash commands into reusable, parameterized scripts that preserve their original intent — then pre-approves them so equivalent commands never trigger a permission dialog again.

## How it works

Most permission dialogs are repetitive: the same `git log` variant, the same test runner, the same file search — each needing fresh approval because the exact arguments differ. safe-scripts breaks that loop.

When Claude is about to run a Bash command that needs approval, the plugin offers to save it as a **safe script**. Rather than whitelisting the literal command, it generalizes the command — extracting the specific values (file paths, limits, branch names) into parameters while preserving what the command actually does. The result is a small, reviewable wrapper you approve **once**.

From then on, the script is pre-approved. Whenever Claude would otherwise write an equivalent command, it calls the safe script instead — with no permission dialog. This works through three pieces:

- **A catalog**, injected at the start of each session, so Claude prefers existing safe scripts over raw Bash.
- **Interception**, which catches matching commands Claude writes anyway and redirects them to the saved script.
- **A save flow**, which turns a brand-new command into a reusable script the first time you approve it.

Because everything runs through the Bash tool, the same mechanism covers every interpreter — not just shell, but Python, Node, Perl, Go, and inline heredoc scripts.

## Requirements

- Claude Code with plugin support
- `jq` ≥ 1.5 (`brew install jq` / `apt install jq`)
- bash ≥ 3.2

## Installation

Add the marketplace, then install the plugin:

```shell
/plugin marketplace add gonensh/claude-plugins
/plugin install safe-scripts@cc-plugins
```

## Usage

Once installed, the plugin works automatically — there are no commands to run. Here's the typical flow the first time Claude hits a command worth saving:

1. Claude needs to run something like `git log --oneline -10 -- src/App.tsx`.
2. The plugin checks your saved scripts. If one already covers it, Claude calls that script directly — no dialog.
3. If nothing matches, Claude offers to save it: *"I can save this as a safe script `git-file-log` so future runs are auto-approved. Save it, or run once?"*
4. If you save, Claude shows you the generalized script — e.g. `git-file-log <file> [--limit N]` — for review. Once you confirm, it writes the script, pre-approves it, and runs your command.

Every equivalent command after that — this session or any future one — runs through the script with no interruption. Saved scripts live in `~/.claude/safe-scripts/` and are added to Claude's allow-list automatically.

## Configuration

By default, scripts are saved to `~/.claude/safe-scripts/`.

To override per-project, create `.claude/safe-scripts-config.json`:

```json
{
  "safe_scripts_dir": "./.claude/safe-scripts"
}
```

Point this at a directory inside your repo and commit it to share a vetted script library across your team.

## Supported interpreters

Any command that runs through the Bash tool is covered. Scripts are saved in their native interpreter where one exists, and wrapped in a bash launcher otherwise:

| Interpreter | Saved as |
|---|---|
| bash | native `.sh` |
| python3 | native `.py` |
| node | native `.js` |
| perl | native `.pl` |
| go, npx / ts-node | bash wrapper |

Inline heredoc scripts (`python3 << 'EOF' … EOF`) are extracted and saved as first-class script files.

## License

MIT

# claude-plugins

A [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces) by Gonen Shoham — a small, curated collection of plugins and skills that make Claude Code safer and less interruptive to work with.

## Add the marketplace

```shell
/plugin marketplace add gonensh/claude-plugins
```

Then install any plugin below by name:

```shell
/plugin install <plugin-name>@cc-plugins
```

Refresh your local copy after new plugins are published with `/plugin marketplace update`.

## Plugins

| Plugin | Description |
|---|---|
| [**safe-scripts**](plugins/safe-scripts/) | Turns one-off Bash commands into reusable, parameterized scripts that preserve their original intent, then pre-approves them — so equivalent commands never trigger a permission dialog again. |

```shell
/plugin install safe-scripts@cc-plugins
```

## Repository layout

```
claude-plugins/
├── .claude-plugin/
│   └── marketplace.json          ← marketplace catalog
├── plugins/
│   └── safe-scripts/             ← one self-contained plugin per directory
│       ├── .claude-plugin/plugin.json
│       ├── hooks/
│       ├── scripts/
│       ├── skills/
│       ├── tests/
│       └── README.md
└── docs/                         ← design specs and implementation plans
```

Each plugin lives in its own directory under `plugins/` and is fully self-contained — it references only files within its own directory, since Claude Code copies each plugin to a cache on install. To add a new plugin, create a directory under `plugins/`, give it a `.claude-plugin/plugin.json`, and add an entry to `.claude-plugin/marketplace.json`.

## License

MIT — see [LICENSE](LICENSE). Individual plugins carry their own copy of the license.

---
name: nushell
description: Use when the user asks about Nushell, nu, shell commands, pipelines, Nushell scripting, config, or any shell-related task. The user uses Nushell as their primary shell.
---

# Nushell

## Pipelines

Nushell pipes structured data (tables, lists, records), not text.

```nu
ls | where size > 1mb | sort-by modified
```

## Common commands

- `ls` — list files (returns table with name/type/size/modified)
- `open <file>` — read file (auto-detects JSON, CSV, TOML, etc.)
- `save <file>` — write output to file
- `from json` / `to json` — convert from/to JSON
- `where <condition>` — filter rows
- `select <cols>` — pick columns
- `sort-by <col>` — sort
- `group-by <col>` — group
- `str replace` — string replacement
- `each { |it| ... }` — iterate

## Config

Config file: `~/.config/nushell/config.nu`
Env file: `~/.config/nushell/env.nu`

- `$env` — environment variables
- `$env.config` — shell configuration (table)
- `let <var> = <expr>` — define variable
- `def <name> [args] { body }` — define custom command
- `source <file>` — load another Nu file

## Scripting

```nu
def greet [name: string] {
  $"hello ($name)"
}
```

- Strings: `$"my name is ($name)"` — interpolation
- Conditionals: `if <cond> { } else { }`
- Loops: `for x in [1 2 3] { }; loop { }; while <cond> { }`
- Errors: `try { } catch { }; error make { msg: "..." }`

---
name: editor
description: the AIU editor's own commands — read a file, see what changed, send the selection to an agent, and put the tree back
---

# The AIU editor

The editor opens a file, edits it, saves it, and never loses a change:
every edit is journalled as it happens, and the tree can be put back at
a checkpoint.

## What this surface is

- The **CLI** — one command per call; the same commands the keys run.
- The **MCP server** — the same commands, over JSON-RPC on stdio.
- The **feed** — the journal: one record per line, flushed as it is
  written.

## The commands

Reading is free. A change needs the human's token, and the engine
checks the token itself: a change without it is refused by name.

| command | what it does | changes the tree |
|---|---|---|
| `routes` | walk the routing: every key, every layer | no |
| `keys` | list the keys and what each one means | no |
| `tasks` | list the task table | no |
| `dashboard` | show the dashboard and every piece of it | no |
| `agent` | show the agent's state and its pins | no |
| `audit` | show what changed, and who changed it | no |
| `checkpoint` | make a checkpoint of the tree | yes |
| `rollback` | put the tree back at a checkpoint | yes |
| `send` | send the bundle to the agent | yes |
| `permit` | answer a permission ask | yes |
| `audit-accept` | accept a change of the audit | yes |
| `audit-undo` | undo a change of the audit | yes |
| `stop` | throw or clear the stop switch | yes |
| `agent-end` | end the agent's session | yes |

## The examples

These are runnable: they are the commands as they are typed, and each
one answers on its own.

```
racket editor/src/entry/cli.rkt routes
racket editor/src/entry/cli.rkt keys
racket editor/src/entry/cli.rkt audit
```

## The MCP calls

The server speaks JSON-RPC 2.0 on the standard input and the standard
output: one request per line, one answer per line. The answer carries
the one envelope — `program`, `version`, `kind`, `ok`, `data`,
`refusal`, `events` — and a refusal names the rule it refused by.

```
{"jsonrpc":"2.0","id":1,"method":"tools/list"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"routes","arguments":{}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"checkpoint","arguments":{"args":["why"],"confirm":"the human's token"}}}
```

## What is NOT here

- The editing session: it reads the terminal, and the terminal is not
  in this conversation. The CLI keeps it.
- The agent's own API: the editor talks to it through its own boundary,
  and an agent never sees the editor's inside.

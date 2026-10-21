---
name: multiplexer
description: the AIU terminal multiplexer's sessions — list them, read a session's records, send text to a session's shell; the sessions outlive the screen that watches them.
---

# The AIU terminal multiplexer

The multiplexer holds sessions: a shell on a terminal that keeps running
whether or not anyone is watching it. A screen attaches, reads, and
detaches; the session goes on. The log is the record — one JSON object per
line, flushed as it is written.

## What this surface is

- The **client** — the human's screen: attach, ask, read, detach.
- The **MCP server** — the same session wire, over JSON-RPC on stdio, for an
  AI agent.
- The **log** — the record of the session: one record per line, flushed as it
  is written.

## The tools

Reading is free. A change needs the human's token, and the server checks the
token itself: a change without it is refused by name.

| tool | what it does | changes a session |
|---|---|---|
| `multiplexer_sessions` | the sessions the multiplexer holds, and what each one holds right now | no |
| `multiplexer_records` | the records of one session, from a number onwards | no |
| `multiplexer_send` | send text to the shell of one session | yes |

## How to use them

- `multiplexer_sessions` first: it names the sessions and the shell each one
  holds. A session with no holder is named as not held.
- `multiplexer_records` with a session's name and a `since` number: the
  records are the log, in order. The shell's output arrives as a `progress`
  record.
- `multiplexer_send` with a session's name, the text, and the human's
  token: the text goes to the session's shell as if it were typed there.

## What the phone cannot do

The holder dies with the session that started it: a process on this phone
does not outlive the shell that made it. What the multiplexer proves is the
detach — the session goes on while the screen goes away — not that the phone
survives. That limit is written down in the ecosystem's phone list, and the
holder's log says which session died.

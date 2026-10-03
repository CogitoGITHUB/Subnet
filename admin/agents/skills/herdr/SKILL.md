---
name: herdr
description: Use when running any command that takes over a minute (builds, boots, tests) or when the user should watch live output. Run it in a herdr pane via the herdr CLI instead of a hidden background shell, then read the pane for output — never ask the user to paste output.
---

# Herdr — visible runs

Herdr server is normally running (`herdr status`). Panes outlive this session; the user watches them live.

## Find a target

```bash
herdr tab list
herdr pane list
```

- **Reuse, never accumulate.** The user usually already has several tabs open. Look at `herdr tab list`, pick a pane that is not the agent's own and not busy, and use it. Only `herdr tab create` when there is genuinely nothing spare.
- **Name the tab you work in**, right after finding or creating it:
  ```bash
  herdr tab rename <TAB_ID> <short-task-slug>   # e.g. aiu-stage-loader
  ```
  Leave no default numeric label on a tab you are actually using.

## Run visible

```bash
herdr pane run <pane_id> <command...>
```

- Long builds/tests/boots go here, not hidden background shells.
- Never `run` into the pane this agent lives in — use a spare tab/pane or `herdr tab create` first.
- One builder at a time per tree: concurrent straight/npm builds race on the same dirs.
- Nushell panes reject `&&`, `2>&1` and `| tee` with their own diagnostics. Wrap in `sh -c '...'` when the command needs plain shell syntax.

## Never block on a long run

Sending the command is not the end of the job — and waiting for it is not done by sleeping.

**Forbidden outright**, because each of these has burned real time here:

- a foreground shell call with a long `timeout` (`timeout 900 neomacs ...`)
- `sleep 300` in a foreground call
- any tool call wrapped in a wall-clock wait

There is no "but it's only a probe" exception. Anything that can take minutes gets: a herdr pane to run it in, a `DONE`/`EXIT=` marker on disk, and a background watcher that greps for it. Then end the turn and let the harness notification arrive.

**The user must be able to watch it.** So stream the output into the pane. Do NOT redirect the whole run to a log file — that hides the very thing the tab is for and turns the pane into a hidden shell with extra steps. Use `tee`: live in the pane, greppable on disk.

```bash
# 1. send the run, e.g.
herdr pane send-text <pane> "sh -c 'cd DIR && make 2>&1 | tee /tmp/run.log; echo EXIT=\$? >> /tmp/run.log'"
herdr pane send-keys <pane> enter
herdr pane read <pane>          # confirm it started AND that text is visible

# 2. arm a completion watcher — background, no timeout
#    (shell tool: background: true, timeout: 0)
for i in $(seq 1 180); do
  grep -q "EXIT=" /tmp/run.log && { grep EXIT= /tmp/run.log; tail -3 /tmp/run.log; break; }
  sleep 10
done
```

- `sh -c` around the whole thing is what makes `2>&1 | tee` legal in a Nushell pane; on its own nu rejects it with a syntax error.
- The watcher blocks on the run's **own** completion marker (`EXIT=`/`BOOT-EXIT=`, a `done` file, the prompt returning to the pane) and then prints only the summary you need.
- The harness notifies you when the watcher exits. **That notification is the echo.** End your turn; do not sleep in a foreground call, do not re-issue the wait loop, do not poll the watcher's output file.
- Use the waiting time for work that does not depend on the result: read code, draft the report, edit files the run is not touching. Report *decisions* in your messages, not a mirror of the log — the user is already reading the pane.
- If there is genuinely no independent work, just stop and answer when the notification lands.
- If a run was already started with a bare `> file` redirect and the user wants to watch it, do NOT restart it — `tail -f <log>` in a spare pane recovers the visibility for free.

## Read output yourself

```bash
herdr pane read <pane_id>
```

- Read the pane for status; never ask the user for output.
- ALWAYS read the pane right after `run`/`send-text` to confirm the command actually started — never fire-and-forget.
- Quoting: your own shell eats quotes before herdr sees them. For a nu pane, wrap the whole TEXT in double quotes so single-quoted elisp survives: `herdr pane send-text <pane> "cmd --eval '(elisp)'"`.
- Keep reads thin: `head`/`tail` the result, report only status lines and errors.

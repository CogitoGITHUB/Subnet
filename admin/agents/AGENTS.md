## Herdr + neomacs: run it, watch it, get pinged
- Open neomacs in a spare pane/tab: `herdr pane run <pane> 'bash -c "neomacs -nw ... 2>&1 | tee <log>; echo DONE-MARKER=\${PIPESTATUS[0]} >> <log>"'`. Output streams (watchable) AND lands in a file.
- Read it live anytime: `herdr pane read <pane>` — progress, errors, backtraces — without touching the session.
- Notify on done: background watcher polls for the exit marker; the harness pings on completion. Never sleep-loop in foreground.
- Safety, learned the hard way: verify a pane is an idle shell BEFORE sending anything (typed into the user's live Emacs twice); never use your own pane; one boot at a time (unit-times.log/module-el race); plain `-nw` never exits — read results, then kill it; batch probes that hang get `timeout`, batch `read`/`with-temp-buffer` flakiness is real.

# Global instructions — loaded in every session

## Environment: proot-Ubuntu on Termux (phone)
- No systemd, no Docker. Never suggest `systemctl`, `service`, or docker daemons.
- Phone limits: 7.5GB RAM, battery + mobile data. Prefer cheap models for scout/fix, remote MCPs over heavy locals.
- Bind loopback only: `127.0.0.1`, never `0.0.0.0`.
- `$HOME` is `/root/home/shape`; Termux home is `/data/data/com.termux/files/home`. NOT the same files — check `readlink -f` before assuming.
- Login shell is Nushell (`/usr/local/bin/nu`). Emit nu-compatible commands or state bash explicitly.
- TTY-only, small phone screen: keep output terse.

## Todo convention
- "todo this/that" without a stated location means append to `/root/home/shape/Subnet/TODO.org` (top level, never `WIP/`).
- One `* TODO <item>` per line, with date when useful.

## Emacs access
- Neomacs 0.0.19 available via `neomacsclient`. For quick elisp eval use `neomacsclient --eval '(...)'`.
- emacs-mcp-server tools (when its MCP is connected): `eval-elisp`, `get-diagnostics`, `org-agenda`, `org-search`, `org-get-node`, `org-capture`, `org-update-node`, `org-refile`, `org-archive`, `org-clock`.
- Never edit `~/.config/emacs/*.el` — build artifacts.

## Herdr: run visible (skill: herdr)
- Herdr is the terminal multiplexer. Long runs (builds, boots, tests) go in a herdr pane via `herdr pane run <pane_id> <cmd>`, never hidden background shells.
- Read output yourself with `herdr pane read <pane_id>` — never ask the user to paste output. Always read right after sending to confirm it started.
- Never run into your own pane; use a spare tab/pane. One builder per tree at a time.
- REUSE A TAB, do not pile up new ones. `herdr tab list` first; if a spare pane/tab already exists, use it. Only `herdr tab create` when there is genuinely none spare.
- Name every tab you use for work: `herdr tab rename <TAB_ID> <short-task-slug>` (e.g. `aiu-stage-loader`). Do not leave default numeric labels on tabs you are using.

## Long runs: never block on them
- NEVER call a shell tool with a long foreground `timeout` (e.g. `timeout 900 ...`), never sleep-loop in a foreground call, and never wrap any tool call in a wall-clock wait. If a command can take minutes, it goes to a herdr pane AND gets a background watcher.
- The ONLY permitted pattern for anything over a few seconds: run it detached with a completion marker written to a log, arm a background watcher that greps for that marker, then END THE TURN and wait for the harness notification.
- `timeout 600 neomacs ...` in a foreground tool call is the same mistake as `sleep 300`. There is no exception for "it's only a probe".
- The tab exists so the USER CAN WATCH. Stream output into the pane with `tee`, never `> logfile` — a fully redirected run makes the tab a hidden shell and defeats the point. `sh -c 'cmd 2>&1 | tee /tmp/run.log; echo EXIT=$? >> /tmp/run.log'` gives live output *and* a greppable log.
- NEVER `sleep` in a loop waiting for a build/boot/test to finish, and never sit in a foreground call that outlasts the work. That burns minutes of wall clock and the phone's battery for nothing.
- After sending a long run to a herdr pane, arm a completion watcher with the shell tool's `background: true` and `timeout: 0`, then STOP and end the turn. The harness notifies you on completion — that notification is the "echo".
- The watcher should block on the run's own completion signal (the command's `BOOT-EXIT=` / `EXIT=` marker line, a `done` file, `herdr pane read` showing the prompt back) and then print the summary lines you actually need: exit code, key counts, timings, artifact paths.
- Do the useful non-dependent work while it runs (reading code, drafting the report, editing files it does not touch), then answer. If there is no such work, end the response and wait for the notification.
- Do not re-issue the same wait loop, and do not poll the watcher output file.

## Git: always ship with `git gg`
- After making any changes, always finish with `git gg` (`git add -A && git commit -m 'update' && git push`).
- Applies to both repos: Subnet vault root AND `~/.config` (dotfiles). The `gg` alias exists in both — run it from each root you touched.

## Warnings/errors: fix everything you see
- Every error or warning you observe (boot logs, *Warnings*, byte-compiler
  output, test results) gets fixed in the same session, not deferred.
  Unfixed issues compound: one silent failure masks the next and each costs
  more to diagnose later than now.
- No silent suppression as a "fix". Filtering/counting is instrumentation;
  the fix removes the cause. Third-party/upstream causes get a durable
  in-scope workaround or an explicit user decision, never a quiet filter.
- Verify each fix with the project's own gates (balance/tangle/reader/
  byte-compile/boot as applicable) before reporting it fixed.

## Session 2026-10-03 (Subnet vault) — what changed
- Staged boot (S1/S2/S0), modular 19-file loader, keyboard + dashboard renames, db path
  repair, warning cleanup. Details in the vault AGENT.md session entry.

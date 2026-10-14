# Verbosity — the ten rules

Bought with a 41-minute hang. A `pm apply` test run stopped emitting
events, stopped writing files, stopped spawning processes, and sat at 0%
CPU in `do_sys_poll` with 100+ leaked pipe fds. Nothing on disk said
anything. We found it only by attaching to `/proc` and reading fds, then
bisecting by hand. The engine's one job is to not be silent, and it was.

So: **if it can block, it says so first.** This is the operative form of
law 1, and it is a separate discipline from "log your operations" — a
step log records what finished, which is no use at all while nothing is
finishing.

## The schema addition

Two kinds, added to the existing closed set in `agents/narration.md`:

| kind | emitted | meaning |
|------|---------|---------|
| `WAIT` | **before** the block | "I am about to block here, for this reason" |
| `WAIT-DONE` | after the block returns | "it returned, in this long" |

`WAIT` carries the same fields as everything else, so it nests, orders
by the run's one `seq` counter, and prints the same screen line. A
`WAIT` without its `WAIT-DONE` is not a bug report — it is **the exact
line that names the hang**, and it is sitting in your feed already.

## The ten

1. **A block announces itself before it happens.** `WAIT` first, then
   block. Never after. A post-hoc log of a hang is a post-mortem.
2. **Every blocking primitive goes through the one wait door.** `sync`,
   `thread-wait`, `semaphore-wait`, `channel-get/put`, `read-line` on a
   fifo or pipe, `close-input-port` on a pipe, `subprocess-wait`, any
   network read. Enumerate them once per project and grep for new ones.
3. **Every wait has an escape.** A deadline, an event, or a detectable
   dead peer. **A wait that can never return is a design error**, not a
   risk. Canonical: opening a named pipe for reading when no writer
   exists blocks inside the open, with no error and no timeout.
4. **`why` is mandatory on a wait, too.** "waiting for the status line"
   is a reason. "waiting" is not.
5. **Narration is per phase, not per command.** Entry and exit around
   every phase of every command, so the feed reads as a path, not a
   series of endpoints. A reader must never have to guess what was
   happening between two lines.
6. **The last line is the last word.** Flush per event so a killed
   process leaves a readable prefix, not a torn record.
7. **No off-switch.** No `--quiet`, no env var, no level. A prior
   screen-only switch was explicitly superseded and removed. Tests may
   redirect the screen port; the feed is never silenced.
8. **Un-narrated blocking paths are test failures.** Assert the `WAIT`
   event exists for every blocking path you care about. A path with no
   `WAIT` is a path you have not finished instrumenting — find it by
   grepping for blocking primitives, not by reading the code.
9. **Verbosity is the product, not debug logging.** It must cost
   nothing when nothing goes wrong, and it must be complete when
   something does. If verbosity needs a flag to be affordable, the flag
   is the bug.
10. **Reaching for a debugger is a failure of the narration.** The moment
    you attach `/proc`, `gdb`, or `strace` to a silent process, the
    mechanism has already failed the user. Fix the narration first, then
    diagnose.

## Reading a hang, once the rules hold

The feed's last `WAIT` names the block. Its `how` names the mechanism.
Nothing else is needed — no fd inspection, no bisect, no timing
arithmetic. Build the narration so this is possible, and most debugging
never happens at all.

## What we got wrong first

- Step-logging only. Every completed operation narrated; nothing that
  was *waiting* narrated. Perfect record of the run up to the hang,
  total silence after it — which is worse than useless, because it
  looks like the hang happened at the last logged step.
- Waiting on a child's status line with no liveness check. The child
  died before writing; the read blocked forever; no event said so.
- Instrumenting after the fact. Logging the phases once the hang was
  reproduced put the marker exactly one statement away from where the
  evidence said the problem was.
#+TITLE: aiu-pm -- using pm from an AI
#+AUTHOR: Shape

* What pm is
A declarative, target-neutral package manager. You declare what a
machine should have in a =.rktd= file; pm decides how to get it there,
records every step of what it did, and can undo it.

This file tells an AI how to drive it. It is not a tutorial.

** Two properties you can rely on
1. *Nothing runs silently.* Every operation narrates itself: what, why,
   how, UTC time, duration. You can read that after the fact from the
   event feed, so you never have to guess what pm did or why it
   skipped something.
2. *Nothing is unreversible.* Installs are journalled per input hash,
   and profile generations are kept, so a half-finished run resumes or
   rolls back rather than leaving a machine in an unknown state.

* What you may and may not do
- You may READ anything: the feed, plans, checks, locks, queries.
- You may NOT change the machine from here. The MCP server puts every
  state-changing tool behind a confirmation token, and the OpenCode
  plugin deliberately exposes no state-changing tool at all. If you
  need an install, a human runs it.

* The commands that work today
=check= and =plan= are executable. Everything else parses, reports its
own arguments back, and then refuses with =command not executable yet=
and exit 2. That refusal is honest, not a bug: do not retry it, and do
not try to work around it by shelling out.

| command | does |
| - | - |
| =pm check DIR= | validate every =.rktd= under DIR |
| =pm plan DIR= | the install plan as written, no resolution yet |
| =pm --help= | the full command list |

* Reading the feed
Each run writes =<state>/events/<run-id>.jsonl=, one JSON object per
line, plus =<state>/events/current= naming the active run. The state
root is =$XDG_DATA_HOME/cyberdeck/= or =~/.local/share/cyberdeck/=.

An event carries =run-id=, =seq=, =parent-id=, =kind=, =depth=, =who=,
=what=, =why=, =how=, =inputs=, =outputs=, =result=, =utc=, =mono-ms=
and =duration-ms=.

** The kinds, and what each one means for you
| kind | read it as |
| - | - |
| =START= | an operation began; =what= names it, =why= says why it was needed |
| =STEP= | one unit of work finished; =how= is the detail |
| =INFO= | a note with no action attached |
| =DECIDE= | a choice was made; =result= is what was chosen, =how= lists what it beat |
| =SKIP= | work was NOT done, and =why= is the reason. This is the one to read. |
| =PROGRESS= | a counter; =how= is =done/total= |
| =END= | the operation finished; =result= is the outcome |
| =FAIL= | it did not; =result= is the error text |
| =WARN= | something worth knowing that is not fatal |

** Why is never empty
A step, decision, skip or failure with no reason is a bug in pm and
raises. So when you see a =why=, it is the actual reason. A =SKIP= is
always explained; there are no silent skips.

** Nesting
=depth= increases inside an operation and =parent-id= points at the
enclosing event. A step at depth 1 belongs to the =START= at depth 0
with the matching =parent-id=.

* Worked example 1 -- validate a directory of specs
**Goal:* confirm four declarations are well-formed before proposing
anything else.

#+begin_src sh
pm check docs/examples --format json
#+end_src

**What comes back* (real output from this repository):

#+begin_src json
{"name":"check","format":"json","operands":["docs/examples"],"ok":["ok: bats-core 1.14.0","ok: cjson 1.7.19","ok: hello 2.12.3","ok: lua 5.5.1"]}
#+end_src

**What the feed said* while that ran:

#+begin_src
[10:47:17 +0.028s] START pm   | what: run | why: session start
[10:47:17 +0.038s] START cli  | what: pm  | why: a command was requested | how: check docs/examples
  [10:47:18 +0.056s] STEP check | what: bats-core 1.14.0 | why: the spec parsed and passed every field check
  [10:47:18 +0.056s] STEP check | what: cjson 1.7.19   | why: the spec parsed and passed every field check
  [10:47:18 +0.057s] STEP check | what: hello 2.12.3    | why: the spec parsed and passed every field check
  [10:47:18 +0.058s] STEP check | what: lua 5.5.1       | why: the spec parsed and passed every field check
[10:47:18 +0.061s] END run    | what: run | why: session end
#+end_src

**What to conclude:* every spec parsed and passed its field checks. If
one had failed you would get exit 3, an =ok= line missing, and a =SKIP=
carrying the error text as its reason.

* Worked example 2 -- see what a directory would install
**Goal:* know the versions and dependency edges before a human decides.

#+begin_src sh
pm plan docs/examples --format json
#+end_src

**What comes back*:

#+begin_src json
{"name":"plan","format":"json","operands":["docs/examples"],"packages":[{"deps":[],"name":"bats-core","version":"1.14.0"},{"deps":[],"name":"cjson","version":"1.7.19"},{"deps":[],"name":"hello","version":"2.12.3"},{"deps":[],"name":"lua","version":"5.5.1"}]}
#+end_src

**How to read it:* =packages= is the declarations as written, in file
order. =deps= is empty for all four because pm does not resolve a
closure yet (that is item G-01, open). Do not describe this as "the
install order" or "the dependency graph"; it is neither yet.

* Worked example 3 -- find out what a run did, and what it skipped
**Goal:* after someone ran pm, answer "what happened and why was
anything skipped?" without guessing.

#+begin_src sh
cat ~/.local/share/cyberdeck/events/current          # the active run id
tail -n 20 ~/.local/share/cyberdeck/events/pm-7040.jsonl
#+end_src

**Or over MCP*, which is what an AI should use (seqs start at 0, so
-1 means "from the beginning"; afterwards pass back =next-seq=):

#+begin_src json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"events.tail","arguments":["pm-7040","-1"]}}
#+end_src

**What comes back* (abridged, one line per event):

#+begin_src json
{"run-id":"pm-7040","from-seq":-1,"count":10,"lines":["#0 START pm | what: run | why: session start","#4 STEP check | what: bats-core 1.14.0 | why: the spec parsed and passed every field check","#9 END run | what: run | why: session end"],"next-seq":9}
#+end_src

**And for the summary only:*

#+begin_src json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run.get","arguments":["pm-7040"]}}
#+end_src

=run.get= answers =events=, =started=, =ended=, =end-result= and
=failures= in one object. If =ended= is =false=, the run was killed
mid-flight: say so rather than describing a result that does not exist.

* The confirmation rule
Any MCP tool that changes state requires the token =initialize= handed
out. Without it you get =-32001= and a message naming
=confirmationToken=. That is not a bug to route around: it means a
human is required. Report it and stop.

The OpenCode plugin has no state-changing tools at all, so approval
there is not a matter for you.

* The redaction rule
Every field is passed through one redaction path before it reaches any
destination, so a URL with a password in it appears as =://***@host=.
You will not see a secret in the feed, in the screen output, or in an
error message. Do not ask for one, and do not treat its absence as
evidence that a step did not happen.

* Things that will bite you
- *exit 2 with =command not executable yet=* means the command parses
  but does not run. =verify=, =fetch=, =apply=, =update=, =activate=,
  =rollback=, =remove=, =hold=, =lock=, =why=, =owner= are all in this
  state today. Say so; do not retry.
- *exit 3 is a bad spec, 5 a fetch failure, 6 a verify failure, 7 a
  build failure, 8 an install failure, 9 an activate conflict, 70 a pm
  bug, 130 a cancellation.* See =docs/ERRORS.org= for the full table.
- *=deps= is not a resolution.* It is what the spec declares.
- *There is no lock over a whole closure yet* (G-02), so do not treat
  a plan as reproducible.

* Where to look next
- =docs/API.org= -- every field and a real example, and the doc is a test
- =docs/OPEN-DECISIONS.org= -- everything not finished, with the
  defaults being used
- =docs/DECISIONS.org= -- why things are the way they are
- =docs/ENGINE-CHECKLIST.org= -- the build state of each item
# measure.nu -- the phone test for the tiny Rust binary (TODO item 2).
#
# One job: build the probe on this phone, run it, and print the measured
# build time and the measured start time. The numbers are the evidence
# for the route decision (D-002): can the phone BUILD the holder itself,
# or must the holder be adopted?
#
# Nothing here waits: the two clock reads are measurement only, and
# nothing waits on a timer (D-015, rule 04). The build and the run are
# ordinary child processes, and the script ends when they end.
#
# One place to change the compiler: MUX_RUSTC. The default is the
# toolchain on this phone.

def now [] { (date now) }

let rustc = ($env | get -o MUX_RUSTC? | default "/root/home/shape/.cargo/bin/rustc")
const here = (path self | path dirname)
let source = ($here | path join "probe.rs")
let binary = ($here | path join "probe")

print $"[probe] rustc=($rustc)"
print $"[probe] source=($source)"

let build_begin = (now)
let build = (do -i { ^$rustc -O $source -o $binary } | complete)
let build_end = (now)
print $"BUILD rc=($build.exit_code) ms=(($build_end - $build_begin) / 1ms)"

if $build.exit_code != 0 {
  print $"BUILD-FAILED: ($build.stderr | str trim)"
  exit 1
}

let start_begin = (now)
let run = (do -i { ^$binary } | complete)
let start_end = (now)
print $"START ms=(($start_end - $start_begin) / 1ms) rc=($run.exit_code)"
print $"SAID: ($run.stdout | str trim)"

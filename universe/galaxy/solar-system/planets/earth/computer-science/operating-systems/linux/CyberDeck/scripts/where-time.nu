# -> table, where the seven minutes of backends/vault.rkt actually went.
#
# Reads a runner log and splits it three ways: how many child processes ran,
# how long the children themselves took (the after= each pm-run-end reports),
# and where the WALL time went that no child accounted for. That last part is
# the interesting one: a gap between two pm-run-start lines is time the
# gate spent outside any git child, which is Racket work, fixture building
# or a stall.
#
# usage: nu scripts/where-time.nu LOGFILE

def main [logfile: string] {
    let lines = (open --raw $logfile | lines)

    let starts = ($lines | where {|l| $l | str starts-with "pm-run-start"})
    let ends = ($lines | where {|l| $l | str starts-with "pm-run-end"})

    # every child duration, in ms, from the after= field of pm-run-end
    let child_ms = ($ends | each {|l|
        let m = ($l | str replace -r '.*after=([0-9]+)ms.*' '$1')
        ($m | into int) })

    # the clock reading each child started at, as epoch seconds
    let stamps = ($starts | each {|l|
        ($l | split row " " | get 1 | into datetime | format date "%s" | into int) })

    mut biggest = []
    mut i = 1
    while $i < ($stamps | length) {
        let gap = (($stamps | get $i) - ($stamps | get ($i - 1)))
        $biggest = ($biggest | append [[$gap, $i]])
        $i = ($i + 1)
    }

    print $"children: ($starts | length) started, ($ends | length) ended"
    print $"child after= total: $(($child_ms | math sum) / 1000 | into int)s"
    print $"largest gaps with NO child running:"
    for row in ($biggest | sort-by {|r| $r.0 } | reverse | first 5) {
        print $"  ($row.0)s before child ($row.1)"
    }
}
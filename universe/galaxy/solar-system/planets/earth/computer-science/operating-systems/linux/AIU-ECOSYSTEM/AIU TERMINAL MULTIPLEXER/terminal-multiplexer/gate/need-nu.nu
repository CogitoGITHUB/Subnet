#!/usr/bin/env nu
# One job: pinned Nu or exit 3; never fetches. Registered in multiplexer/INDEX.org.
#
# The gate needs one Nushell version, so this script states which one and
# refuses anything else. It never downloads, never installs and never writes
# anywhere. Exit 3 means "the toolchain is not here", which is a different
# answer from a red gate, and a caller must not confuse the two.

use ./env.nu *

# required_major is the major number of the pinned version: 0.116 is the Nu this
# phone runs.
const REQUIRED_MAJOR = 0

# required_minor is the minor number of the pinned version; the patch number
# does not matter.
const REQUIRED_MINOR = 116

# main prints the running Nu version and exits 3 unless it is the pinned one,
# recording the mismatch rather than installing anything.
def main [] {
    let version = (nu --version | str trim)
    let parts = ($version | split row ".")
    let major = ($parts | get -o 0 | into int)
    let minor = ($parts | get -o 1 | into int)

    if $major != $REQUIRED_MAJOR or $minor != $REQUIRED_MINOR {
        let need = $"Nu ($REQUIRED_MAJOR).($REQUIRED_MINOR)"
        print $"NEED-NU exit 3: this gate needs ($need); this machine has ($version)"
        print "NEED-NU: install nothing here, record it for the laptop list and say so"
        exit 3
    }

    print $"NEED-NU ok: Nu ($version), the pinned version, nothing fetched"
}

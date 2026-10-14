#!/usr/bin/env nu
# install-tv-channels.nu -- PRINTS the commands that install pm's
# television channels. It never writes anything itself (D-039: the tv
# side is opt-in, and a script that silently edits a config directory
# is exactly the surprise this project does not do).
#
# Run it, read the commands, run them yourself if you agree.

def main [
    --cwd: string
    --config: string
] {
    let cwd = (if ($cwd == null) { pwd | path expand } else { $cwd })
    let config = (if ($config == null) {
        $nu.home-dir | path join ".config" "television"
    } else {
        $config
    })
    let src = ($cwd | path join "tv")
    let cable = ($config | path join "cable")

    print $"channel source: ($src)"
    print $"cable target: ($cable)"
    print ""
    print "Prerequisites (once):"
    print "  1. television installed: pm installs it"
    print "     (see docs/examples/tv.rktd, pinned v0.4.21)"
    print "  2. shell integration, save this line once:"
    print "     tv init nu | save -f vendor-autoload-tv.nu"
    print ""
    print "This script writes nothing. Run these yourself if you agree:"
    print $"  mkdir -p ($cable)"
    let specs_ln = ($src | path join 'pm-specs.toml' | path expand)
    let packs_ln = ($src | path join 'pm-packages.toml' | path expand)
    print $"  ln -sfn ($specs_ln) ($cable | path join 'pm-specs.toml')"
    print $"  ln -sfn ($packs_ln) ($cable | path join 'pm-packages.toml')"
    print ""
    print "Required environment (export before launching tv):"
    print $"  PM_ROOT=($cwd)  # the AIU-PM checkout"
    print "  PM_PROFILE=<profile dir> PM_LOCK=<lockfile>  # for pm-packages"
    print "  PM_SPECS=<specs dir>  # optional, defaults to the repo examples"
    print ""
    print "Then list and launch:"
    print "  tv list-channels"
    print "  tv pm-specs"
    print ""
    print "To remove again:"
    print $"  rm -f ($cable | path join 'pm-specs.toml') ($cable | path join 'pm-packages.toml')"
}


#!/usr/bin/env nu
# install-tv-channels.nu -- PRINTS the commands that install the
# multiplexer's television channels. It never writes anything itself:
# the tv side is opt-in, and a script that silently edits a config
# directory is exactly the surprise this project does not do.
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
    let src = ($cwd | path join "picker")
    let cable = ($config | path join "cable")

    print $"channel source: ($src)"
    print $"cable target: ($cable)"
    print ""
    print "Prerequisites (once):"
    print "  1. television installed, and new enough to read a cable:"
    print "     the channels in the cable directory are read by television"
    print "     v0.15 and later; v0.4.21 has five built-in channels only."
    print "  2. shell integration, save this line once:"
    print "     tv init nu | save -f vendor-autoload-tv.nu"
    print ""
    print "This script writes nothing. Run these yourself if you agree:"
    print $"  mkdir -p ($cable)"
    let records_ln = ($src | path join 'tm-records.toml' | path expand)
    let panes_ln = ($src | path join 'tm-panes.toml' | path expand)
    let sessions_ln = ($src | path join 'tm-sessions.toml' | path expand)
    print $"  ln -sfn ($records_ln) ($cable | path join 'tm-records.toml')"
    print $"  ln -sfn ($panes_ln) ($cable | path join 'tm-panes.toml')"
    print $"  ln -sfn ($sessions_ln) ($cable | path join 'tm-sessions.toml')"
    print ""
    print "Required environment (export before launching tv):"
    print $"  TM_STATE_DIR=<the holder's state dir>  # the session's own directory"
    print "  TM_LAYOUT=<the layout file>           # optional, defaults to"
    print "                                          $TM_STATE_DIR/layout.json"
    print "  TM_SESSIONS_DIR=<the sessions dir>    # for tm-sessions"
    print ""
    print "Then list and launch:"
    print "  tv list-channels"
    print "  tv tm-records"
    print "  tv tm-panes"
    print "  tv tm-sessions"
}

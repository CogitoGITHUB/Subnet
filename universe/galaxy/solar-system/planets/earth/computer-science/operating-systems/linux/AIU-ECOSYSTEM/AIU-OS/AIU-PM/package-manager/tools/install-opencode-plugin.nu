#!/usr/bin/env nu
# install-opencode-plugin.nu -- PRINTS the command that installs the pm
# plugin. It never writes outside CyberDeck/ and never installs anything
# itself (D-036: the AI side is opt-in, and a script that silently
# edits a config directory is exactly the surprise this project does
# not do).
#
# Run it, read the command, run the command yourself if you agree.

def main [
    --cwd: string
    --config: string
] {
    let cwd = (if ($cwd == null) { pwd | path expand } else { $cwd })
    let config = (if ($config == null) {
        $nu.home-dir | path join ".config" "opencode"
    } else {
        $config
    })
    let src = ($cwd | path join "agent" "opencode-plugin")
    let dest = ($config | path join "plugins" "aiu-pm.mjs")

    print $"plugin source: ($src)"
    print $"plugin target: ($dest)"
    print ""
    print "This script writes nothing. Run these yourself if you agree:"
    print $"  mkdir -p ($config | path join 'plugins')"
    print $"  ln -sfn ($src | path expand) ($dest)"
    print ""
    print "The @opencode-ai/plugin dependency is installed by npm inside"
    print "the plugin directory, once per clone; it is never symlinked"
    print $"  cd ($src) && npm install --no-audit --no-fund"
    print ""
    print "Then check the tools are registered:"
    print "  opencode run 'list the pm tools you have'"
    print ""
    print "To remove the plugin again:"
    print $"  rm -f ($dest)"
    print ""
    print "Verify the plugin logic on its own (no OpenCode, no pm run):"
    print $"  cd ($src) && node test.mjs"
}

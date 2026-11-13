public enum DefaultConfig {
    /// Written on first launch when no config exists.
    public static let text = #"""
# Runbar config. Saved changes are picked up automatically.
#
# kind = "service"    long-running, kept by launchd; keeps running after Runbar quits
#        restart   = "no" | "on-failure" | "always"   (default "no")
#        autostart = true  -> also starts at login     (default false)
# kind = "command"    runs once when clicked
#        output = "silent" (notify on failure only, default) | "notify" (always)
# kind = "scheduled"  runs on a cron schedule while Runbar is running
#        schedule = "*/30 * * * *"   minute hour day month weekday
#        catch_up = true  -> run once after sleep/launch if a run was missed (default)
#        output works as for "command"
#
# Every item also takes: name, dir (default "~"), env = { KEY = "value" },
# icon = SF Symbol name for the section header.
# Commands run through your login shell, so your PATH applies. RUNBAR=1 is set,
# so your .zshrc can skip slow interactive-only setup with: [[ -n $RUNBAR ]] && return

[settings]
# Menu bar icon: an SF Symbol name (browse them in Apple's free SF Symbols app),
# or a path to a black-on-transparent PNG/PDF about 18x18 pt, e.g. "~/icons/bar.pdf".
# If "<name>.fill" exists, it is shown while something is running.
icon = "terminal"

[[sections]]
title = "Services"
icon = "server.rack"

  [[sections.items]]
  id = "syncthing"
  name = "Syncthing"
  kind = "service"
  command = "syncthing serve --no-browser"
  restart = "on-failure"

[[sections]]
title = "Commands"
icon = "terminal"

  [[sections.items]]
  id = "brew-outdated"
  name = "Brew outdated"
  kind = "command"
  command = "brew outdated"
  output = "notify"

# [[sections]]
# title = "Scheduled"
# icon = "clock"
#
#   [[sections.items]]
#   id = "brew-update"
#   name = "Brew update"
#   kind = "scheduled"
#   schedule = "0 9 * * 1-5"
#   command = "brew update"
"""#
}

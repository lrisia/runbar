# Runbar

A menu bar app for macOS 14+ that starts and stops saved commands, so no
terminal has to stay open.

- **service**: a long-running process kept by launchd. It keeps running when
  Runbar quits, can restart on failure, and can start at login.
- **command**: runs once when clicked. Click again while it runs to stop it.
- **scheduled**: runs on a cron schedule while Runbar is running. A run missed
  during sleep or while Runbar was closed runs once on wake or launch.

Click the menu bar icon for the panel. It stays open while you use it, closes
on a click elsewhere or Esc, and leaves the app you were in focused. Services
have a switch, commands a run/stop button, and a spinner shows while something
starts, stops or runs. Click a row to see its command and settings; the `⋯`
button has Restart, Open Log and Copy Command. ⌘, opens the config, ⌘R reloads
it, ⌘Q quits.

`+` (⌘N) adds an item from a form: kind, command, name, folder (typed or
picked) and options. Edit and Delete are in each row's details and its `⋯`
menu; Delete takes effect at once and shows Undo for 5 seconds (a service
comes back stopped). The form changes the config as text, so your comments
stay, an edit keeps keys the form doesn't show (`env`, `icon`), and nothing is
written if the result doesn't load.

To browse SF Symbols for the icon: `brew install --cask sf-symbols`.

## Build and install

```bash
scripts/build.sh install
```

This builds `build/Runbar.app`, copies it to `~/Applications` and opens it.
Tick **Open Runbar at login** in the panel.

Run the tests with `swift test`.

The app icon is drawn by `scripts/icon.swift`. After changing it, run
`swift scripts/icon.swift` to rewrite `Resources/AppIcon.icns`.

## Config

`~/.config/runbar/config.toml`, created with examples on first launch.
Saved changes apply right away. If the file has an error, the menu shows it
and Runbar keeps using the last good config.

```toml
[settings]
icon = "terminal"               # SF Symbol name, or a path to an ~18 pt template PNG/PDF

[[sections]]
title = "Services"
icon = "server.rack"            # SF Symbol for the section header

  [[sections.items]]
  id = "syncthing"              # letters, digits, . _ -
  name = "Syncthing"
  kind = "service"
  command = "syncthing serve --no-browser"
  restart = "on-failure"        # no (default) | on-failure | always
  autostart = false             # true: also start at login
  dir = "~"                     # working directory (default ~)
  env = { STNORESTART = "1" }

  [[sections.items]]
  id = "backup"
  kind = "scheduled"
  schedule = "0 9 * * 1-5"      # minute hour day month weekday, or @daily etc.
  catch_up = true               # run once after a missed time (default true)
  output = "silent"             # silent: notify on failure (default) | notify: always
  command = "~/bin/backup.sh"
```

Commands run as `<login shell> -ilc 'exec <login shell> -c "$RUNBAR_COMMAND"'`.
The interactive login shell loads your PATH and exports, then hands off to a
plain shell, because an interactive shell ignores SIGTERM. `RUNBAR=1` is set,
so a slow `.zshrc` can skip interactive-only setup:

```zsh
[[ -n $RUNBAR ]] && return
```

Editing a running service's entry takes effect on Restart; until then its row
says "config changed, restart to apply". Removing a service from the config
stops it and deletes its agent.

## URL scheme

For Raycast, Shortcuts or shell aliases:

```bash
open runbar://toggle/syncthing    # also start, stop, restart, run
open runbar://reload
open runbar://menu
```

## Files

| Path | What |
|---|---|
| `~/.config/runbar/config.toml` | Config |
| `~/Library/Logs/runbar/<id>.log` | Output of each item, moved to `.log.1` past 5 MB |
| `~/Library/Logs/runbar/history.log` | One line per command or scheduled run |
| `~/Library/LaunchAgents/local.runbar.<id>.plist` | Agents with `autostart = true` |
| `~/Library/Application Support/runbar/agents/` | Agents started only from the menu |
| `~/Library/Application Support/runbar/loaded/` | The definition each service was last started with |
| `~/Library/Application Support/runbar/state.json` | Last handled time of each schedule |

## How it stays light

No polling. Service state is read with one `launchctl list` when the menu
opens, after an action, and when a watched process exits (kqueue process
events). The config file is watched with file-system events. Idle CPU is zero.

## Uninstall

Remove all items from the config first (this stops services and deletes their
agents), then quit Runbar and delete `~/Applications/Runbar.app`,
`~/.config/runbar`, `~/Library/Logs/runbar` and
`~/Library/Application Support/runbar`.

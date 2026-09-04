# Luminos

DDC brightness companion for external monitors on Apple Silicon Macs.
Closes the gap where macOS only adjusts the built-in display's brightness.

## What it does

- **Auto-sync**: keeps the external monitor's hardware backlight mapped to the
  built-in display's brightness (polls 1×/s). This means F14/F15 *and* the
  ambient-light sensor drive both displays — no Accessibility permission needed.
- **Movie mode**: one-command hardware backlight boost for dark movies.
  Saves current DDC luminance/contrast, sets max; running it again restores.
- **Status bar item**: monitor icon in the menu bar with a **gamma slider**
  (0.5–3.5) for the external display — lift shadow detail in dark scenes —
  plus Reset Gamma, Sync toggle, Movie Mode toggle, and Quit.

## Usage

Luminos is a menu-bar app (`LSUIElement` agent, no Dock icon). It installs to
`~/Applications/Luminos.app` and starts at login via LaunchAgent.

```sh
# CLI (works while the app is running)
~/Applications/Luminos.app/Contents/MacOS/Luminos --movie   # toggle movie mode
~/Applications/Luminos.app/Contents/MacOS/Luminos --test    # diagnostics + DDC write probe
```

Log: `/tmp/luminos.log` (launchd stdout) and the unified log
(`log show --predicate 'process == "Luminos"' --last 10m`).

## Install / autostart

```sh
./build.sh    # build → bundle → ad-hoc sign → deploy to ~/Applications → (re)start
```

LaunchAgent: `~/Library/LaunchAgents/dev.luminos.daemon.plist`
(starts at login, KeepAlive with 30 s throttle)

```sh
launchctl kickstart -k gui/$(id -u)/dev.luminos.daemon   # restart
launchctl bootout gui/$(id -u)/dev.luminos.daemon        # stop
```

## Configuration

Tunables at the top of `Sources/luminos/main.swift`:

| Constant | Default | Meaning |
|---|---|---|
| `DISPLAY_ARG` | `2` | m1ddc display index (`m1ddc display list`) |
| `STEP` | `8` | DDC step for key mirroring (if tap enabled) |
| `SYNC_MIN/MAX` | 10 / 100 | DDC range the built-in 0–100% maps onto |
| `SYNC_HYSTERESIS` | `2` | min change before writing to the monitor |
| `MOVIE_LUMINANCE/CONTRAST` | 100 / 85 | movie mode targets |

## Rebuilding

Just run `./build.sh` — it builds, bundles, signs, stops the daemon, replaces
the app and restarts it in one go.

**Important**: the script replaces `Luminos.app` with `rm -rf` + `cp -R` (new
inode). Never overwrite the app in place — macOS tracks the running binary by
inode (code-signature provenance); overwriting it makes the kernel SIGKILL
future launches with "Taskgated Invalid Signature".

Note: the binary is ad-hoc signed; if you ever enable the CGEvent tap code path
(media-key interception), macOS Accessibility grants bind to the build hash and
must be re-granted after each rebuild. A self-signed identity
(`certs/`) was created for this but is not currently wired into the build.

## Dependencies

- [m1ddc](https://github.com/waydabber/m1ddc) (`brew install m1ddc`) — DDC/CI transport
- No other dependencies; single-file Swift executable.

## Known limitations

- External monitor must support DDC/CI over its connection (USB-C/DP on
  Apple Silicon; built-in HDMI on M1 does not pass DDC).
- Some monitors accept DDC contrast writes but silently ignore luminance
  writes (often due to a dynamic-contrast/eco picture mode). Auto-sync and
  movie mode require a monitor that accepts luminance writes; the gamma
  slider works regardless. Run `bin/luminos --test` to probe your display.
- Sync has ~1–2 s latency by design (polling + hysteresis) to avoid spamming
  the monitor's I²C bus.
- Gamma is a GPU color-table adjustment: it resets on display sleep, reconnect,
  or reboot (re-apply via the slider), and conflicts with f.lux-style tools.

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

```sh
bin/luminos --sync    # daemon mode (managed by launchd, see below)
bin/luminos --movie   # toggle movie mode on the external monitor
bin/luminos --test    # print external luminance + built-in brightness
```

Log: `/tmp/luminos.log`

## Install / autostart

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

```sh
swift build -c release
launchctl bootout gui/$(id -u)/dev.luminos.daemon
rm -f bin/luminos && cp .build/release/luminos bin/luminos   # new inode, see below
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.luminos.daemon.plist
```

**Important**: replace `bin/luminos` with `rm` + `cp`, never `cp` in place.
macOS tracks the running binary by inode (code-signature provenance);
overwriting the file in place invalidates the signature tracking and the
kernel SIGKILLs any future launch with "Taskgated Invalid Signature".

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

# Luminos

DDC brightness companion for external monitors on Apple Silicon. Single-file
Swift menu-bar app (`Sources/luminos/main.swift`) shelling out to `m1ddc`.
See `README.md` for usage; `@docs/reliability-fixes.md` documents the
concurrency/state design and the reasoning behind it.

## Operational notes

- **Deploy**: `./build.sh` builds release, bundles, ad-hoc signs, boots out
  the old daemon, replaces `~/Applications/Luminos.app`, installs/refreshes
  the LaunchAgent plist (path patched via `plutil`, deliberately no sed), and
  bootstraps it. Never overwrite the .app in place (inode/signature).
- **LaunchAgent**: label and bundle id are both `dev.luminos.daemon` (keep
  them in sync). KeepAlive is `{SuccessfulExit = false}` — restart on crash
  only, so menu Quit stays quit.
- **Movie-mode state file**: `~/Library/Application Support/Luminos/
  movie-state.json` exists whenever the panel is supposed to be at 100/85.
  The next launch restores from it and deletes it. If a monitor is ever
  stuck bright, delete that file after fixing manually.
- **Flag files** (`/tmp`): `luminos_movie_toggle` (timestamped; daemon drops
  it if older than 10 s), `luminos_test_pause` (makes `--test` suspend the
  daemon's sync writes).
- **Concurrency model**: all app state (MovieMode, SyncEngine.lastSent,
  Gamma.current) is main-thread-confined; all m1ddc subprocess traffic is
  serialized on `DDC.queue`. Don't dispatch MovieMode work to background
  queues.
- **Display identity**: m1ddc index is auto-resolved from
  `m1ddc display list`; gamma resolves the external display as "first online
  display that isn't built-in". Never hardcode either.
- **Subprocess rule**: always read the pipe to EOF *before*
  `waitUntilExit()` — `corebrightnessdiag status-info` exceeds the pipe
  buffer and deadlocks otherwise.
- Logs: `/tmp/luminos.log` (launchd) + unified log
  (`log show --predicate 'process == "Luminos"' --last 10m`).

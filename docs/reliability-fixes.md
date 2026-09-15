# Reliability fixes (2026-09-15)

A full bug-hunt (architecture + code review passes) found five high-severity
and ~10 lower-severity defects. This doc captures what was broken and the
non-obvious decisions in the fixes. The bugs clustered in three areas:
brightness sensing, movie-mode state, and display identity.

## Brightness sensing

- `DisplayServicesGetBrightness` was dlsym'd with a **one-argument** c-function
  type. The real ABI is `int DisplayServicesGetBrightness(int display,
  float *brightness)` — the leading display id was missing, so the "primary"
  path could never succeed and every sync tick fell through to the
  `corebrightnessdiag` subprocess. The typealias now takes
  `(UInt32, UnsafeMutablePointer<Float>)` and resolves the built-in display id
  via `CGGetOnlineDisplayList` + `CGDisplayIsBuiltin` (which returns a
  `boolean_t`, not a `CGError` — 0 means "not built-in").
- `corebrightnessdiag status-info` emits far more than the 64 KB pipe buffer.
  Calling `waitUntilExit()` before draining the pipe deadlocked the main
  thread the first time the fallback ran. **Every subprocess in the app now
  reads to EOF before waiting** (m1ddc included, where it's harmless but kept
  for consistency).

## Movie mode

State is now **main-thread-confined** (a plain `var` mutated only from the
main run loop and menu actions). The old code dispatched `toggle()` onto a
global *concurrent* queue while the 1 s tick toggled on the main thread — a
data race where a double-toggle snapshotted 100/85 as the "restore point" and
stranded the panel at full brightness. DDC traffic itself is serialized on
`DDC.queue`; state decisions happen synchronously on main, so double-clicks
sequence correctly even though the writes are async.

Movie state is persisted to
`~/Library/Application Support/Luminos/movie-state.json` for as long as the
panel is supposed to be at 100/85. Restore paths, in order of preference:

1. `applicationWillTerminate` → synchronous restore (covers Quit and
   launchd's SIGTERM during deploy).
2. If that fails (or the process died harder), the file survives and the
   **next launch restores within one tick**, retrying every second until the
   DDC writes are accepted. The file is only deleted once the restore lands.

A failed toggle-off now keeps the restore pending instead of clearing state
unconditionally — the old code would mark movie mode "off" with the panel
still bright, and re-toggling would snapshot the bad values permanently.

## Sync engine

- `lastSent` (hysteresis memory) is only updated after the panel *accepts*
  the write; a failed write clears it so the next tick retries
  unconditionally. Previously a failed write was recorded as sent and the
  hysteresis could suppress retries forever.
- Re-enabling sync and completing a movie restore call `invalidate()`
  (clears `lastSent`) — otherwise hysteresis swallowed the first write and
  the toggle appeared dead.
- Sync writes run on `DDC.queue` with a `writeInFlight` guard; the 1 s tick
  no longer blocks the main thread on m1ddc subprocesses.

## Display identity

- `m1ddc`'s display index is **auto-resolved** from `display list` at startup
  and re-resolved once after any failed command (index re-enumerates on
  replug/reboot). This was not theoretical: the hardcoded index `2` was
  already wrong on this machine (monitor enumerated as `1`), silently
  breaking every DDC write.
- Gamma no longer targets `CGDirectDisplayID(2)` (an opaque registry value,
  not an index). The external display is resolved per call as "first online
  display that isn't built-in", CG return codes are checked, and the last
  gamma is persisted in UserDefaults and re-applied on wake
  (`NSWorkspace.didWakeNotification` / `screensDidWakeNotification`) and on
  display reconfiguration (`CGDisplayReconfigurationCallBack`, flags
  `setMode/add/remove/enabled`, +0.5 s delay). Swift note: the option values
  keep the `Flag` suffix — `.setModeFlag`, not `.setMode`.

## CLI handoff

- `--movie` writes a **timestamped** flag and refuses (exit 1) when no daemon
  is running. The daemon drops flags older than 10 s (ThrottleInterval is
  30 s, so any flag that survived a deploy/death window is stale) and drops
  unparsable legacy flags.
- `--test` writes `/tmp/luminos_test_pause`, which the tick honors as a
  pause, so the daemon's own writes can't produce a false
  `ddc-write: REJECTED` result. The pause file is removed via `defer` inside
  a `do` block — `defer` does *not* run around a bare `exit()` at top level.

## Deploy

- `build.sh` now installs the LaunchAgent plist (`cp` + `plutil -replace
  ProgramArguments -json` for the `$HOME`-dependent path — no sed, which once
  mangled Label/log paths). Gotcha discovered the hard way:
  `plutil -replace ProgramArguments.0` on an existing array index **inserts**
  a new element instead of replacing, yielding a duplicated argv[0]; replacing
  the whole array via `-json` is deterministic. Fresh machines no longer fail
  at `launchctl bootstrap`.
- `KeepAlive` is now `{SuccessfulExit = false}`: launchd restarts the job
  only after an abnormal exit, so the menu's Quit actually quits. (`KeepAlive
  = true` relaunched every clean exit after 30 s.)
- Bundle id unified to `dev.luminos.daemon` (was `dev.luminos.app` in
  Info.plist while everything else used `dev.luminos.daemon`).

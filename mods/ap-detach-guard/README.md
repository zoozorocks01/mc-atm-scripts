# AP Detach Guard

Tiny server-side NeoForge (1.21.1) mixin mod that stops the AdvancedPeripherals
whole-server crash this base has hit five times.

## The bug it guards

If a computer detaches (reboot, chunk unload, block broken) while AP still has an
RS Bridge craft job pending, AP fires the job's next state-change event at the
gone computer: `BasicCraftJob.fireEvent` → `IComputerAccess.queueEvent` with no
try/catch and no job cleanup on detach. CC throws `NotAttachedException`, which
escapes into `RSBridgeEntity.handleTick` on the server thread → server crash.
Verified against AP `1.21.1-0.7.61b` bytecode (both `fireEvent` overloads contain
exactly one `queueEvent` invoke; this mod redirects that exact call site).

Upstream report: see `~/Downloads/github-issue_ap-notattachedexception-server-crash_20260702.md`.
Remove this mod once AP fixes it.

## Build

```sh
./build.sh        # needs JDK 21 (brew openjdk@21 default) + the three jars in libs/
```

The script header shows the `scp` lines to fetch the compile-against jars from the
live server (they are NOT committed). Output: `build/ap-detach-guard-1.0.0.jar`.

## Install (operator action)

1. Copy the jar into the server's `mods/` folder.
2. Restart the server (a normal scheduled restart is fine).
3. Verify in logs: `mixin` lines mentioning `apdetachguard` / `BasicCraftJobMixin`,
   and the mod list showing `AP Detach Guard`.
4. Belt-and-suspenders test (optional, off-hours): start a small craft via the CC
   console, `safereboot --force` the manager mid-craft — the server should log
   nothing worse than a skipped event.

Client players do NOT need this mod (server-side only; lowcodefml, no entry class).

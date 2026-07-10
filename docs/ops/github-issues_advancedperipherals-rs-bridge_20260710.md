# Two paste-ready GitHub issues for IntelligenceModding/AdvancedPeripherals

File separately. Evidence gathered live on ATM10 (MC 1.21.1, NeoForge 21.1.228,
AP 1.21.1-0.7.61b, Refined Storage neoforge-2.0.6, CC:Tweaked 1.117.1).

---

## Issue 1: NPE in RSApi.getCraftingTasks when a job's crafting task reference is invalidated

**Title:** `RS Bridge: getCraftingTasks throws NPE when an RSCraftJob's task reference is null (poisons all subsequent calls)`

**Description:**

`RSApi.getCraftingTasks` dereferences `task.getCraftingTask().info()` with no
null check (RSApi.java:527 in 0.7.61b, same in dev/1.21.1):

```java
if (status.info().id().equals(task.getCraftingTask().info().id())) {
```

An `RSCraftJob` whose backing RS task reference has been invalidated while the
job is still listed (observed trigger: editing patterns in an autocrafter while
a bridge-initiated job was in flight) makes EVERY subsequent
`getCraftingTasks()` peripheral call throw:

```
java.lang.NullPointerException: Cannot invoke "com.refinedmods.refinedstorage.api.autocrafting.status.TaskStatus.info()"
because the return value of "de.srendi.advancedperipherals.common.addons.refinedstorage.RSCraftJob.getCraftingTask()" is null
    at de.srendi.advancedperipherals.common.addons.refinedstorage.RSApi.getCraftingTasks(RSApi.java:527)
    at de.srendi.advancedperipherals.common.addons.computercraft.peripheral.RSBridgePeripheral.getCraftingTasks(RSBridgePeripheral.java:742)
```

Once one poisoned job exists, the bridge's task visibility is dead until the
computer is rebooted (which purges the job list). We logged 937 consecutive
occurrences in one evening before finding the workaround.

**Repro:**
1. Computer with RS Bridge; `craftItem` a processing-pattern recipe.
2. While the job is pending, remove/reinsert the pattern in its autocrafter
   (or otherwise invalidate the task).
3. Call `getCraftingTasks()` — NPE on every call thereafter.

**Suggested fix:** skip jobs whose `getCraftingTask()` is null in the matching
loop (a job with no live task can't match any status). We run exactly that as
a local mixin patch and it fully resolves the storm:

```java
TaskStatus jobTask = task.getCraftingTask();
if (jobTask != null && status.info().id().equals(jobTask.info().id())) {
```

---

## Issue 2: RS Bridge craft jobs report "craft failed" when the RS preview calculation is slow (job actually completes)

**Title:** `RS Bridge: craftItem jobs fire false "craft failed" under server load — preview-not-done treated as terminal failure while RS completes the craft`

**Description:**

`RSCraftJob` treats an unfinished RS preview calculation as a terminal
failure ("Tried to get preview, but preview calculation is not done. Should be
done." → UNKNOWN_ERROR / craft failed). On a loaded server or a large network
(ours: ~6,700 item types, tick lag ~40 ticks behind during captures), RS's
async preview often isn't done inside AP's expectation window, so:

- AP fires the `rs_crafting` failure event ~18-22s after `craftItem`;
- RS meanwhile finishes planning and **completes the craft anyway** — items
  arrive ~10-20s after AP already declared failure.

Observed dozens of times over two days: jobs consistently "failed" at
~18-22s, with stock arriving at ~+35s. Grid-initiated crafts of the same
recipes never fail (no AP in the loop). Under healthy TPS the same
`craftItem` calls succeed cleanly, confirming this is a timing race, not a
recipe/setup problem.

**Impact:** any automation driving `craftItem` gets false failures under load
and must implement its own late-delivery reconciliation (we did) — and the
"failed" event is indistinguishable from a real failure at event time.

**Suggested fix:** treat preview-not-done as WAIT/retry (poll until the
calculation resolves or a generous configurable timeout), not as terminal
failure; only fire the failure event on a definitive RS answer
(MISSING_RESOURCES, etc.).

---

Both issues verified against 0.7.61b bytecode and the dev/1.21.1 sources.
Happy to provide the full server log excerpts or our mixin patch.

# Findings register — verified facts (don't re-derive)

Durable home for verified findings. Daily boards in `.k2/inbox/` should link
here instead of re-copying. Add a dated entry when a finding is verified;
strike (don't delete) entries that later prove wrong.

## Refined Storage / Advanced Peripherals

- **RS 2.0.6 collision bug, filmed (2026-07-09):** two concurrent tasks on one
  pattern+machine -> second freezes at 0% (screenshot 18:04). Fixed upstream
  in RS 2.0.7 (changelog verbatim). THE reason for the 2.0.9 jar swap.
- **AP preview-race (source-verified, 2026-07-09):** AP fails craftItem jobs
  when RS's async preview is slow ("preview calculation is not done" ->
  UNKNOWN_ERROR) while RS completes anyway — explains all "failed-but-
  delivered" (~18-22s failures, +35s deliveries) and why load poisons craft
  tests. Upstream issues drafted (see `docs/ops/`); Zach files.
- **AP getCraftingTasks NPE:** fixed permanently by our mixin (ap-detach-guard
  1.1.0, deployed 2026-07-09); NPE=0 since.
- **RS route choice is nondeterministic** when one output has multiple
  patterns (gold planned via dust, tin/aluminum via blocks, same day).
  Crafter PRIORITY is the deterministic lever. One-output-one-winner is the
  design rule.
- **Grid crafts are immune to all AP failure modes** (no AP in the loop) —
  use grid tests to isolate RS-vs-AP causes.
- **RS Detectors exist in RS2** (verified in jar) — code-free thermostat
  option for simple single-product lines.
- **AP has NO RS3 support** — RS 3.x is forbidden until AP updates.
- **Zombie active tasks accumulate behind a bad crafter (2026-07-10):** nine
  outstanding RS jobs piled up 04:46–10:53 (gold, lead x2, nickel x2, tin,
  uranium, aluminum/antimony tiny dust); RS held 5 "active" frozen tasks
  (lead job 786 re-observed activeNow=true every loop). Once actives are
  saturated, NEW compress jobs fail instantly ("craft failed" with hundreds
  of thousands of inputs on hand). Suspected trigger: unverified push-target
  crafter at 1149 75 2642. Full autopsy:
  `.k2/inbox/fable-autopsy-queue-jam-not-single-stuck-lead.md` (archive after
  resolution).

## Manager / queue behavior

- **Boot prunes queue approvals older than 30 min** (QUEUE_MAX_AGE_MS) — a
  reload sweeps stale quarantine; don't mistake it for a fix.
- **Failed compress entries auto-retry forever with no backoff (2026-07-10):**
  iron/osmium retried ~every 22s from jobId ~855 to ~1098 in one morning, all
  failing. Gap filed as a Codex brief (retry backoff + escalation to
  quarantine).
- **RS-side zombies are invisible to the stuck-detector (2026-07-10):**
  status showed stuckCount=0 while RS held 5 frozen active tasks — the
  detector only watches queue entries in CRAFTING, not RS's task list. Gap
  filed in the same brief. Codex's activeTasks persistence slice is the
  observability half.
- **Oresight reserve constraint (Zach):** never auto-consume allthemodium/
  vibranium/unobtainium raw forms + a few ores.

## Performance ledger (TPS budget)

- **Pre-slice baseline:** the manager was 65% of sampled server CPU (Terra's
  capture, 2026-07-09); manager loop 22.1s under load, 300%+ CPU spikes.
- **Terra slice result (merged 775ee21):** loop 22.1s -> 14.3s at reload,
  7.3-7.5s @ ~50% by 2026-07-10 morning. Viewer rate-limit (viewerSeconds,
  default 15s) was the headline win.
- **Current profile (2026-07-10):** planning dominates the loop —
  planningMs ~5.3s of ~7.1s total; indexItems ~1.15s. Tiered scan cadence
  (fast lane every scan, planning/trends on slow laps) is the designed next
  lever (backlog #2).
- **Entity culls, not bridge-poll frequency, fixed prior TPS dips** (config
  note) — the manager is not currently the server's TPS bottleneck.
- **Strategic direction for "smart" operation:** move steady-state control
  off the polling scripts and into local hardware loops — line-brain
  mini-computers (live path), RS Detectors (code-free), and eventually the
  addon mod with setpoint control (backlog #3) so scripts write thresholds
  instead of running the loop. Script death then degrades to static
  thresholds, not chaos, and steady-state script cost approaches zero.

## Contract / process

- **Sim-first gate:** policy changes gate on `tools/atm10-iterate.sh test`
  and ship with rationale (commit body or `docs/DECISIONS.md`). The sim
  discovers; the live pass confirms.
- **Codex Phase-2 graduation:** after a clean restart-night + ~a week of
  live ops, Codex takes main + day-to-day lead (contract, 05ba2f5).

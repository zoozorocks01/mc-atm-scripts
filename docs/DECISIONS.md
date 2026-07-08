# Design decisions (queue / craft-gate / mode policy)

Why this file exists: on 2026-07-07 the auto failure policy was revised five times
in one afternoon (`70e737d..4cdf3eb`), each commit a bare subject line. The end
state was right, but the *reasoning* lived nowhere — the next session (either
agent) could not tell settled policy from leftover scar tissue, and the stale
mid-series wording survived in comments and docs. This file is where policy
rationale lands so it stops being rediscovered.

**The rule** (also in `docs/COLLABORATION.md`): any change to craft-gating,
queue admission, failure handling, or mode/soak lifecycle ships with its
reasoning — a real commit body (root cause + chosen policy) or an entry here.
Five undocumented revisions of one policy is the failure mode this prevents.

Format per entry: what was happening, the policy chosen, where it is enforced,
and what gates it.

---

## 1. Auto-mode failure policy (settled 2026-07-07, backfilled)

**What was happening.** Live auto mode had two runaway modes: `autoApprove`
admitted every planner deficit at once (a big base floods the queue in one
cycle), and failed rows auto-retried after cooldown (a persistent failure —
missing pattern, missing inputs — re-fired forever, burning bridge calls and
filling the audit with noise). The 2026-07-07 series iterated through fail-stop
→ hold-everything → bounded admission → per-row quarantine before settling.

**Policy.**
- **Failed rows quarantine individually.** The runner always gets
  `holdFailed = true`: a row with an error never re-fires until an operator (or
  a manual retry path) explicitly retries or clears it — in every mode.
- **Admission is bounded.** `autoApprove` gets `maxNew = maxQueued =
  stockKeeper.maxCraftsPerCycle`: auto keeps at most a runnable backlog of that
  size, not the whole deficit list.
- **Failed rows do not consume runnable capacity.** The `maxQueued` count
  excludes rows with errors, so one quarantined failure cannot starve healthy
  work out of the bounded slots. (The mid-series revision that held *all* work
  on any failure was rejected as the always-on behavior — it froze unrelated
  quotas — and became the soak-only knob below.)
- **Hold-everything is reserved for unattended windows.** The runner's
  `holdWhenAnyFailed` knob halts every non-manual row while any failure exists.
  It is armed only during an agent soak (entry 2), where the goal is to prove
  trustworthiness, not to maximize throughput.

**Enforced in** `lib/atm10-craftrunner.lua` (`holdFailed`,
`holdWhenAnyFailed`), `lib/atm10-queue.lua` (`autoApprove` opts,
`failureCount`), manager `autoApprovePlans` + `processCraftQueue` deps.

**Gated by** sim scenarios `auto-admission-bounded`,
`auto-quarantines-failed-row`; smoke `AUTO-FAILSTOP-1`; `tests/run.lua` runner
unit tests.

## 2. Agent-driven bounded auto soak (2026-07-08)

**What was happening.** Auto mode could only be proven live with Zach as the
actuator (toggle auto on, watch, toggle it back), so every verification pass
cost a human round-trip — and production became the discovery mechanism for
failure modes (see the 2026-07-07 series). The simulator + soak scenarios now
discover; a bounded live soak confirms.

**Policy.** An agent asks a LIVE manager for a bounded unattended-auto window
over the file channel; the manager owns the entire lifecycle and always returns
to manual by itself.
- **Channel:** agent writes `.atm10-soak-request`
  (`{requestedAt, durationMs?, maxPerCycle?}`, manager-clock ms — use
  `tools/atm10-iterate.sh soak`). Manager replies via `.atm10-status` (`soak`
  block) and `.atm10-soak-report` (end **or** rejection, with the reason).
- **Start gates:** request fresh (60s TTL), base mode `manual`, no drain in
  progress, bridge not degraded, no failed rows in the queue. A soak is an
  excursion from a safe manual base — never a way to re-arm a misbehaving auto
  base. Boot deletes pre-boot request files (unknown age/intent).
- **Bounds:** duration clamped to 30s..15m (default 5m); `maxPerCycle` may only
  tighten the config cap, never widen it.
- **Fail-stop:** the runner runs with `holdWhenAnyFailed = true` — the first
  failed row anywhere halts all quota fire that same cycle, and the soak
  formally ends next cycle with reason `queue failure`.
- **Always reverts to manual.** End paths: first failure, operator mode change
  (tapping the mode chip kills it), deadline, manager restart (boot finds
  leftover `.atm10-soakstate`, reports `manager restart`, stays manual). The
  soak never touches the persisted mode override, so there is nothing to undo.

**Enforced in** `lib/atm10-control.lua` (`soakSpec`, `soakEndReason`), manager
(`ui.processSoak`, `effectiveMode`, boot cleanup, runner deps).

**Gated by** sim scenarios `soak-request-bounded-window`,
`soak-fail-stop-reverts`, `soak-restart-stays-manual`; `tests/run.lua` soak
unit tests. Live driver: `tools/atm10-iterate.sh soak [durationSec]
[maxPerCycle]`.

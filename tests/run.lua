-- Off-CC unit tests for the pure logic in the shared libs.
-- Run from the repo root:  lua tests/run.lua
-- Focus: the safety-critical control gate, the theme resolver, and the
-- status vocabulary. Display rendering and the RS Bridge are not covered here
-- (they need the real CC runtime / in-game checks).

package.path = "./lib/?.lua;./tests/?.lua;" .. package.path

local t = require("support") -- sets _G.colors, _G.fs before libs load
local status = require("atm10-status")
local control = require("atm10-control")
local palette = require("atm10-palette")
local draw = require("atm10-draw")
local stockplan = require("atm10-stockplan")
local cqueue = require("atm10-queue")
local craftrunner = require("atm10-craftrunner")
local managed = require("atm10-managed")
local balance = require("atm10-balance")
local suggest = require("atm10-suggest")
local presets = require("atm10-presets")
local console = require("atm10-console")
local power = require("atm10-power")
local health = require("atm10-health")
local pgive = require("atm10-pattern-give")

-- ---------------------------------------------------------------------------
print("monitor (HEALTH page derivation)")
-- Placed here near the top because run.lua's main chunk approaches Lua's 200-local
-- limit by the end. Own do-scope. Biting: a wrong stuck-timer, craftable split, or
-- decline threshold changes the counts/lists.
do
  local monitor = require("atm10-monitor")
  local NOW = 10000000
  local mq = {
    a = { state = "CRAFTING", craftingAt = NOW - 400000,  label = "Stuck One" }, -- 6.6m -> refill stuck
    b = { state = "CRAFTING", craftingAt = NOW - 60000,   label = "Fresh One" }, -- 1m   -> not stuck
    c = { state = "APPROVED", approvedAt = NOW - 1000,    label = "Waiting" },   -- not in-flight
    d = { state = "CRAFTING", craftingAt = NOW - 600000,  label = "Compress Warmup", kind = "compress" },
    e = { state = "CRAFTING", craftingAt = NOW - 1260000, label = "Compress Stuck", kind = "compress" },
  }
  local mres = {
    x = { ok = true,  at = NOW - 60000 },
    y = { ok = false, at = NOW - 120000, reason = "no" },
    z = { ok = true,  at = NOW - 9999999 }, -- too old -> excluded
  }
  local ch = monitor.craft(mq, mres, 12, NOW, { stuckMs = 300000, recentMs = 1800000 })
  t.eq(ch.inFlight, 4, "monitor.craft: 4 CRAFTING in-flight")
  t.eq(#ch.stuck, 2, "monitor.craft: refill uses 5m threshold; compress uses 20m threshold")
  t.eq(ch.stuck[1].label, "Compress Stuck", "monitor.craft: oldest stuck job sorts first")
  t.eq(ch.stuck[2].label, "Stuck One", "monitor.craft: names the refill stuck job")
  t.eq(ch.recentOk, 1, "monitor.craft: 1 recent ok")
  t.eq(ch.recentFail, 1, "monitor.craft: 1 recent fail")
  t.eq(ch.ratePerMin, 12, "monitor.craft: passes through crafts/min")

  local paceOk = monitor.pace({ loopMs = 1200, refreshMs = 5000, dataAgeMs = 0 }, NOW)
  t.eq(paceOk.status, "OK", "monitor.pace: low loop load is OK")
  t.eq(paceOk.loadPct, 24, "monitor.pace: computes scan load percentage")
  local paceSlow = monitor.pace({ loopMs = 9000, refreshMs = 5000, dataAgeMs = 0 }, NOW)
  t.eq(paceSlow.status, "SLOW", "monitor.pace: slow scan is SLOW")
  local paceStale = monitor.pace({ loopMs = 1000, refreshMs = 5000, dataAgeMs = 45000 }, NOW)
  t.eq(paceStale.status, "STALE", "monitor.pace: stale data outranks normal scan time")
  local paceErr = monitor.pace({ loopMs = 1000, refreshMs = 5000, dataAgeMs = 0, lastError = "scan failed" }, NOW)
  t.eq(paceErr.status, "ERROR", "monitor.pace: explicit error is ERROR")

  local trends = {
    ["ma:silver_dust"] = { label = "Silver Dust", t0 = NOW - 1200000, tN = NOW, a0 = 5000, aN = 1000, n = 6 }, -- -200/min, raw
    ["mc:inferium"]    = { label = "Inferium",    t0 = NOW - 1200000, tN = NOW, a0 = 9000, aN = 5000, n = 6 }, -- -200/min, craftable
    ["mx:flat"]        = { label = "Flat",        t0 = NOW - 1200000, tN = NOW, a0 = 1000, aN = 1000, n = 6 }, -- no decline
    ["my:tiny"]        = { label = "Tiny",        t0 = NOW - 1200000, tN = NOW, a0 = 1100, aN = 1000, n = 6 }, -- -5/min, below thresh
    -- net drain 2000 (perMin 100, passes) BUT swing 19000 >> 3*2000 -> transient spike, must be dropped
    ["mz:spiky"]       = { label = "Spiky",       t0 = NOW - 1200000, tN = NOW, a0 = 10000, aN = 8000, minA = 1000, maxA = 20000, n = 6 },
  }
  local dm = monitor.demand(trends, { ["mc:inferium"] = true }, { minPerMin = 20, minWindowMin = 10, minSamples = 4, top = 6 })
  t.eq(#dm.fallingBehind, 1, "monitor.demand: 1 falling-behind (craftable + draining)")
  t.eq(dm.fallingBehind[1].name, "mc:inferium", "monitor.demand: inferium falling behind")
  t.eq(#dm.sourceMore, 1, "monitor.demand: 1 source-more (raw input draining; spiky one excluded)")
  t.eq(dm.sourceMore[1].name, "ma:silver_dust", "monitor.demand: silver dust -> source more")
  t.check(dm.sourceMore[1].perMin >= 199 and dm.sourceMore[1].perMin <= 201, "monitor.demand: ~200/min drain")
end

-- control.unsettledJobs: safereboot's per-job settled check over recorded craftItem
-- ids -- closes the CALCULATION-phase hole (job invisible to getCraftingTasks but
-- AP still fires its events). Biting: settled/unsettled/blind classification.
do
  local function job(flags)
    local j = {}
    for _, m in ipairs({ "isDone", "isCanceled", "hasErrorOccurred", "isCalculationNotSuccessful" }) do
      j[m] = function() return flags[m] == true end
    end
    return j
  end
  local jobs = {
    [1] = job({}),                        -- live: calculating or crafting
    [2] = job({ isDone = true }),         -- settled: done
    [3] = job({ hasErrorOccurred = true }), -- settled: errored
  }
  local bridge = { getCraftingTask = function(id) return jobs[id] end } -- unknown id -> nil (purged)
  local out = { { id = 1 }, { id = 2 }, { id = 3 }, { id = 99 } }
  local live = control.unsettledJobs(bridge, out)
  t.eq(live.count, 1, "unsettledJobs: only the live job blocks (done/errored/purged settle)")
  t.eq(live.method, "getCraftingTask", "unsettledJobs: reports getCraftingTask as the check method")
  t.eq(control.unsettledJobs(bridge, {}).count, 0, "unsettledJobs: no recorded jobs -> 0")
  t.eq(control.unsettledJobs(bridge, nil).count, 0, "unsettledJobs: missing outstanding list -> 0 (old craftstate)")
  t.eq(control.unsettledJobs({}, out).method, "missing", "unsettledJobs: recorded jobs but no getCraftingTask API -> missing")
  t.eq(control.unsettledJobs(nil, out).method, "missing", "unsettledJobs: no bridge -> missing")
  local throwing = { getCraftingTask = function() error("boom") end }
  t.eq(control.unsettledJobs(throwing, { { id = 1 } }).count, 1, "unsettledJobs: bridge throw on lookup stays conservative")
  local methodless = { getCraftingTask = function() return {} end } -- job with NO status methods
  t.eq(control.unsettledJobs(methodless, { { id = 1 } }).count, 1, "unsettledJobs: unqueryable job state stays conservative (unsettled)")
end

-- control.drainRequestFresh: the aborted-drain staleness gate. safereboot/atm10-reload
-- renew the flag every poll; a flag whose requester died must go stale so the manager
-- resumes crafting. Biting: dropping the TTL check or the renewedAt preference flips these.
do
  t.eq(control.drainRequestFresh(nil, 1000), false, "drainFresh: no data is not fresh")
  t.eq(control.drainRequestFresh({}, 1000), false, "drainFresh: no timestamps is not fresh")
  t.eq(control.drainRequestFresh({ requestedAt = 500 }, 1000), true, "drainFresh: recent requestedAt-only (first write) is fresh")
  t.eq(control.drainRequestFresh({ requestedAt = 500 }, 70000), false, "drainFresh: unrenewed request goes stale past the TTL")
  t.eq(control.drainRequestFresh({ requestedAt = 500, renewedAt = 69000 }, 70000), true, "drainFresh: renewal keeps an old request alive")
  t.eq(control.drainRequestFresh({ requestedAt = 500, renewedAt = 500 }, 70000), false, "drainFresh: a dead requester's last renewal expires")
  t.eq(control.drainRequestFresh({ renewedAt = 90000 }, 70000), true, "drainFresh: future timestamp still fresh (clock skew never strands a live drain)")
  t.eq(control.drainRequestFresh({ renewedAt = 1000 }, 5000, 3000), false, "drainFresh: caller-supplied TTL is respected")
  t.eq(control.drainRequestFresh({ renewedAt = "junk" }, 1000), false, "drainFresh: non-numeric timestamps are not fresh")
end

-- control.activeCraftCount: the LIVE bridge query the hardened safereboot relies on.
-- Biting: wrong method preference / fallback / nil-handling changes count or method.
do
  local c, m = control.activeCraftCount({ getCraftingTasks = function() return { {}, {} } end })
  t.eq(c, 2, "activeCraftCount: getCraftingTasks list -> count 2")
  t.eq(m, "getCraftingTasks", "activeCraftCount: reports authoritative method")
  local c2 = control.activeCraftCount({ isItemCrafting = function(a) return a.name == "x" end }, { "x", "y" })
  t.eq(c2, 1, "activeCraftCount: isItemCrafting fallback counts only crafting names")
  local c3, m3 = control.activeCraftCount({})
  t.eq(c3, 0, "activeCraftCount: no craft-status method -> 0")
  t.eq(m3, "none", "activeCraftCount: reports 'none' when blind")
  local c4, m4 = control.activeCraftCount(nil)
  t.eq(c4, 0, "activeCraftCount: nil bridge -> 0")
  t.eq(m4, "no-bridge", "activeCraftCount: nil bridge -> 'no-bridge'")
  local snap = control.activeCraftSnapshot({
    getCraftingTasks = function()
      return {
        {
          bridge_id = 77,
          id = "live-task",
          crafted = 12,
          quantity = 64,
          completion = 0.25,
          resource = { name = "alltheores:zinc_block", displayName = "Zinc Block" },
        },
      }
    end,
  })
  t.eq(snap.count, 1, "activeCraftSnapshot: counts live AP task rows")
  t.eq(snap.method, "getCraftingTasks", "activeCraftSnapshot: records task-list method")
  t.eq(snap.byName["alltheores:zinc_block"].bridgeId, 77,
    "activeCraftSnapshot: indexes live AP bridge_id/resource shape")
  t.eq(snap.byName["alltheores:zinc_block"].progressPct, 25,
    "activeCraftSnapshot: converts fractional completion to percent")
  local snap2 = control.activeCraftSnapshot({ isItemCrafting = function(a) return a.name == "x" end }, { "x", "y" })
  t.eq(snap2.count, 1, "activeCraftSnapshot: fallback counts crafting names")
  t.check(snap2.byName.x ~= nil and snap2.byName.y == nil,
    "activeCraftSnapshot: fallback indexes only true isItemCrafting names")
  local unsettled = control.unsettledJobs({
    getCraftingTask = function() return { getDebugMessage = function() return "CALCULATION_STARTED" end } end,
  }, { { id = 77, name = "alltheores:zinc_ingot" } })
  t.eq(unsettled.count, 1, "unsettledJobs: present calculating AP job is unsafe")
  t.eq(unsettled.jobs[1].id, 77, "unsettledJobs: reports the unsafe AP job id")
  local done = control.unsettledJobs({
    getCraftingTask = function() return { isDone = function() return true end } end,
  }, { { id = 78 } })
  t.eq(done.count, 0, "unsettledJobs: done AP job is settled")
  local missing = control.unsettledJobs({ getCraftingTask = function() return nil end }, { { id = 79 } })
  t.eq(missing.count, 0, "unsettledJobs: NOT_FOUND/nil AP job is settled")
  local errored = control.unsettledJobs({ getCraftingTask = function() error("bridge read failed", 0) end }, { { id = 80 } })
  t.eq(errored.count, 1, "unsettledJobs: unexpected getCraftingTask error fails unsafe")
end

-- ---------------------------------------------------------------------------
print("status vocabulary")
t.eq(status.normalize("WOULD CRAFT"), status.WOULD, "WOULD CRAFT -> WOULD")
t.eq(status.normalize("NOT CRAFTABLE"), status.NO_RECIPE, "NOT CRAFTABLE -> NO_RECIPE")
t.eq(status.normalize("UNKNOWN-ID"), status.UNKNOWN_ID, "UNKNOWN-ID -> UNKNOWN_ID")
t.eq(status.normalize("ALREADY CRAFTING"), status.CRAFTING, "ALREADY CRAFTING -> CRAFTING")
t.eq(status.normalize("CYCLE CAP"), status.BLOCKED, "CYCLE CAP -> BLOCKED")
t.eq(status.normalize(123), status.UNKNOWN, "non-string -> UNKNOWN")
t.eq(status.normalize("would"), status.WOULD, "lowercase resolves via upper()")
t.check(status.color(status.OK) == colors.green, "OK color is green")
t.check(status.glyph("WOULD CRAFT") == ">", "WOULD glyph is >")
t.eq(status.label("UNKNOWN-ID"), "UNKNOWN-ID", "UNKNOWN-ID label stays operator-specific")
t.eq(status.worst({ "OK", "BLOCKED", "WOULD" }), status.BLOCKED, "worst picks BLOCKED")
t.eq(status.worst({ "OK", "NO_RECIPE", "BLOCKED" }), status.NO_RECIPE, "worst picks NO_RECIPE")
local tally = status.tally({ { action = "WOULD CRAFT" }, { action = "OK" }, { status = "OK" },
  { action = "UNKNOWN-ID" } })
t.eq(tally.WOULD, 1, "tally WOULD = 1")
t.eq(tally.OK, 2, "tally OK = 2")
t.eq(tally.UNKNOWN_ID, 1, "tally UNKNOWN_ID = 1")
-- power-side states (PR5 vocabulary): additive, existing entries unchanged
t.eq(status.normalize("STALE DATA"), status.STALE, "STALE DATA -> STALE")
t.eq(status.normalize("CRITICAL"), status.CRITICAL, "CRITICAL recognized")
t.eq(status.normalize("DRAINING"), status.DRAINING, "DRAINING recognized")
t.check(status.color(status.CRITICAL) == colors.red, "CRITICAL color red")
t.check(status.color(status.DRAINING) == colors.yellow, "DRAINING color yellow")
t.check(status.color(status.STALE) == colors.orange, "STALE color orange")
t.eq(status.worst({ "OK", "CRITICAL", "NO_RECIPE", "BLOCKED" }), status.CRITICAL, "CRITICAL is most severe")
t.eq(status.normalize("NOT CRAFTABLE"), status.NO_RECIPE, "existing vocab still intact after extension")

-- ---------------------------------------------------------------------------
print("control gate (safety)")
local function mkaction(over)
  local a = {
    id = "test", enabled = true, capability = control.CAPABILITY_AUTOCRAFT,
    armed = true, approved = true, execute = function() return true end,
  }
  for k, v in pairs(over or {}) do a[k] = v end
  return control.action(a)
end

local pAuto    = control.policy({ mode = "auto",    allowAutocraft = true })
local pDry     = control.policy({ mode = "dry-run", allowAutocraft = true })
local pMonitor = control.policy({ mode = "monitor", allowAutocraft = true })
local pManual  = control.policy({ mode = "manual",  allowAutocraft = true })
local pNoCap   = control.policy({ mode = "auto",    allowAutocraft = false })

-- dry-run can NEVER reach OK, even fully armed/approved/allowed with an executor
t.eq((control.executionState(mkaction(), pDry)), status.WOULD, "dry-run -> WOULD (never OK)")
t.check(control.canExecute(mkaction(), pDry) == false, "dry-run canExecute == false")
t.eq((control.executionState(mkaction(), pMonitor)), status.DISABLED, "monitor -> DISABLED")
t.eq((control.executionState(mkaction({ enabled = false }), pAuto)), status.DISABLED, "disabled action -> DISABLED")
t.eq((control.executionState(mkaction({ armed = false }), pAuto)), status.DISABLED, "not armed -> DISABLED")
t.eq((control.executionState(mkaction(), pNoCap)), status.BLOCKED, "capability not allowed -> BLOCKED")
-- built directly (a {execute=nil} literal can't override the default executor)
local noExec = control.action({ id = "t", enabled = true, capability = control.CAPABILITY_AUTOCRAFT, armed = true, approved = true })
t.eq((control.executionState(noExec, pAuto)), status.BLOCKED, "no executor -> BLOCKED")
t.eq((control.executionState(mkaction(), pAuto)), status.OK, "auto + armed + allowed + executor -> OK")
t.eq((control.executionState(mkaction({ approved = false }), pManual)), status.COOLDOWN, "manual unapproved -> COOLDOWN")
t.eq((control.executionState(mkaction({ approved = true }), pManual)), status.OK, "manual approved -> OK")

-- the executor must NOT run in dry-run, and MUST run only when OK
local called = false
local okDry = control.execute(mkaction({ execute = function() called = true; return true end }), pDry)
t.check(okDry == false, "execute() returns false in dry-run")
t.check(called == false, "executor is NOT called in dry-run")
called = false
control.execute(mkaction({ execute = function() called = true; return "done" end }), pAuto)
t.check(called == true, "executor IS called when OK")

-- authorize: sender allowlist + token
local pSecured = control.policy({ allowedSenders = { 7, 12 }, token = "secret" })
t.check((control.authorize(5, { token = "secret" }, pSecured)) == false, "unlisted sender rejected")
t.check((control.authorize(7, { token = "wrong" }, pSecured)) == false, "bad token rejected")
t.check((control.authorize(7, { token = "secret" }, pSecured)) == true, "listed sender + token accepted")
t.check((control.authorize(99, {}, control.policy({}))) == true, "open policy accepts any sender")

-- ---------------------------------------------------------------------------
print("control commands (CTRL-1 dispatch chokepoint)")
do -- scope the control-command test locals (Lua caps locals at 200 per function)
local ctrlPolicy = control.policy({ allowRedstone = true, token = "t0k" })
local actuatorCalls
local function mkActuator() actuatorCalls = {}; return function(cmd, spec) actuatorCalls[#actuatorCalls + 1] = { target = cmd.target, cap = spec.capability } end end
-- unknown action -> rejected, actuator untouched
local act1 = mkActuator()
local r1 = control.dispatch(control.command({ action = "no_such", target = "left", token = "t0k" }), ctrlPolicy, act1)
t.check(r1.ok == false and r1.reason == "unknown action", "dispatch rejects an unknown action")
t.eq(#actuatorCalls, 0, "unknown action does not call the actuator")
-- capability off -> rejected
local act2 = mkActuator()
local r2 = control.dispatch(control.command({ action = "redstone_toggle", target = "left", token = "t0k" }),
  control.policy({ allowRedstone = false, token = "t0k" }), act2)
t.check(r2.ok == false and r2.reason == "redstone not allowed", "dispatch rejects an action whose capability is off")
t.eq(#actuatorCalls, 0, "capability-off action does not call the actuator")
-- bad token -> rejected
local act3 = mkActuator()
local r3 = control.dispatch(control.command({ action = "redstone_toggle", target = "left", token = "WRONG" }), ctrlPolicy, act3)
t.check(r3.ok == false and r3.reason == "bad token", "dispatch rejects a bad token")
t.eq(#actuatorCalls, 0, "bad-token action does not call the actuator")
-- permitted -> actuator called exactly once with the right target
local act4 = mkActuator()
local r4 = control.dispatch(control.command({ action = "redstone_toggle", target = "right", token = "t0k" }), ctrlPolicy, act4)
t.check(r4.ok == true and r4.action == "redstone_toggle", "dispatch accepts a permitted, authorized command")
t.eq(#actuatorCalls, 1, "permitted command calls the actuator exactly once")
t.eq(actuatorCalls[1].target, "right", "actuator receives the command's target")
-- no actuator -> rejected (and reports it)
local r5 = control.dispatch(control.command({ action = "redstone_toggle", target = "left", token = "t0k" }), ctrlPolicy, nil)
t.check(r5.ok == false and r5.reason == "no actuator", "dispatch refuses when no actuator is injected")
-- open policy (no token) doesn't require a token on the command
local act6 = mkActuator()
local r6 = control.dispatch(control.command({ action = "redstone_set", target = "back", args = { level = 15 } }),
  control.policy({ allowRedstone = true }), act6)
t.check(r6.ok == true, "no-token policy accepts a command without a token")
t.eq(#actuatorCalls, 1, "token-less permitted command still actuates once")

-- ---------------------------------------------------------------------------
print("control channel (CTRL-2 authorize -> dispatch)")
local chanPolicy = control.policy({ allowRedstone = true, token = "tok", allowedSenders = { 7, 12 } })
-- allowlisted sender + good token -> authorized and dispatched (actuator once)
local cAct1 = mkActuator()
local cr1 = control.handleMessage(7, { action = "redstone_toggle", target = "left", token = "tok" }, chanPolicy, cAct1)
t.check(cr1.ok == true and cr1.action == "redstone_toggle", "allowlisted sender + good token dispatches")
t.eq(#actuatorCalls, 1, "valid control message actuates exactly once")
-- non-allowlisted sender -> dropped before dispatch (actuator never reached)
local cAct2 = mkActuator()
local cr2 = control.handleMessage(99, { action = "redstone_toggle", target = "left", token = "tok" }, chanPolicy, cAct2)
t.check(cr2.ok == false and cr2.reason == "sender not allowed", "non-allowlisted sender is dropped")
t.eq(#actuatorCalls, 0, "dropped sender never reaches the actuator")
-- bad token -> dropped before dispatch
local cAct3 = mkActuator()
local cr3 = control.handleMessage(7, { action = "redstone_toggle", target = "left", token = "NOPE" }, chanPolicy, cAct3)
t.check(cr3.ok == false and cr3.reason == "bad token", "bad token is dropped")
t.eq(#actuatorCalls, 0, "bad-token message never reaches the actuator")
-- unknown action from a valid sender -> authorized but dispatch rejects it
local cAct4 = mkActuator()
local cr4 = control.handleMessage(12, { action = "self_destruct", target = "left", token = "tok" }, chanPolicy, cAct4)
t.check(cr4.ok == false and cr4.reason == "unknown action", "valid sender, unknown action -> rejected by dispatch")
t.eq(#actuatorCalls, 0, "unknown action never actuates")

-- CTRL-3: the redstone actuator, driven through dispatch (gated by allowRedstone)
local rsCalls, rsState = {}, {}
local fakeRs = { setOutput = function(side, on) rsCalls[#rsCalls + 1] = { side = side, on = on } end }
local rsActuator = control.redstoneActuator(fakeRs, rsState)
-- capability off -> dispatch rejects, setOutput never called
control.dispatch(control.command({ action = "redstone_toggle", target = "left" }), control.policy({ allowRedstone = false }), rsActuator)
t.eq(#rsCalls, 0, "redstone toggle blocked when allowRedstone is false (no setOutput)")
-- allowed -> toggle ON
control.dispatch(control.command({ action = "redstone_toggle", target = "left" }), control.policy({ allowRedstone = true }), rsActuator)
t.eq(#rsCalls, 1, "allowed toggle drives setOutput exactly once")
t.check(rsCalls[1].side == "left" and rsCalls[1].on == true, "toggle turns the configured side ON")
-- toggle again -> OFF (state tracked per side)
control.dispatch(control.command({ action = "redstone_toggle", target = "left" }), control.policy({ allowRedstone = true }), rsActuator)
t.check(rsCalls[2].on == false, "second toggle on the same side turns it OFF")
-- redstone_set on a different side
control.dispatch(control.command({ action = "redstone_set", target = "back", args = { on = true } }), control.policy({ allowRedstone = true }), rsActuator)
t.check(rsCalls[3].side == "back" and rsCalls[3].on == true, "redstone_set on drives the configured side ON")

-- A1: craft_request command -- gated on the autocraft capability + token, dispatched
-- to a host actuator. Same chokepoint as redstone (default-deny otherwise).
local cqPolicy = control.policy({ allowAutocraft = true, token = "ck" })
-- allowAutocraft=false -> denied "autocraft not allowed" (proves the capability gate)
local cq1 = mkActuator()
local cqr1 = control.dispatch(control.command({ action = "craft_request", target = "mek:steel", args = { count = 5 }, token = "ck" }),
  control.policy({ allowAutocraft = false, token = "ck" }), cq1)
t.check(cqr1.ok == false and cqr1.reason == "autocraft not allowed", "craft_request denied when autocraft is off")
t.eq(#actuatorCalls, 0, "denied craft_request never reaches the actuator")
-- bad token -> denied
local cq2 = mkActuator()
local cqr2 = control.dispatch(control.command({ action = "craft_request", target = "mek:steel", args = { count = 5 }, token = "WRONG" }), cqPolicy, cq2)
t.check(cqr2.ok == false and cqr2.reason == "bad token", "craft_request denied on a bad token")
t.eq(#actuatorCalls, 0, "bad-token craft_request never reaches the actuator")
-- allowed + good token + actuator spy -> ok, action craft_request, actuator once with target+count
local cqCount
local cq3 = (function() actuatorCalls = {}; cqCount = nil; return function(cmd) actuatorCalls[#actuatorCalls + 1] = cmd; cqCount = cmd.args and cmd.args.count end end)()
local cqr3 = control.dispatch(control.command({ action = "craft_request", target = "mek:steel", args = { count = 64, force = true }, token = "ck" }), cqPolicy, cq3)
t.check(cqr3.ok == true and cqr3.action == "craft_request", "craft_request accepted with capability + token")
t.eq(#actuatorCalls, 1, "accepted craft_request actuates exactly once")
t.eq(actuatorCalls[1].target, "mek:steel", "craft_request actuator gets the item target")
t.eq(cqCount, 64, "craft_request actuator gets args.count")
-- handleMessage drops a non-allowlisted sender before dispatch (actuator never called)
local cq4Pol = control.policy({ allowAutocraft = true, token = "ck", allowedSenders = { 7 } })
local cq4 = mkActuator()
local cqr4 = control.handleMessage(99, { action = "craft_request", target = "mek:steel", args = { count = 5 }, token = "ck" }, cq4Pol, cq4)
t.check(cqr4.ok == false and cqr4.reason == "sender not allowed", "craft_request from a non-allowlisted sender is dropped")
t.eq(#actuatorCalls, 0, "dropped craft_request sender never reaches the actuator")
end -- end control-command test scope

-- ---------------------------------------------------------------------------
print("reboot safety (drain guard against the AP detach crash)")
local DRAIN = control.DEFAULT_DRAIN_MS
-- nothing crafting + no recent craft -> safe
local rsClean = control.rebootSafety({ now = 1000000, lastCraftAt = nil, crafting = 0, drainMs = DRAIN })
t.check(rsClean.safe == true, "no crafts + no history -> safe")
-- something in flight -> never safe, regardless of time
local rsBusy = control.rebootSafety({ now = 1000000, lastCraftAt = 0, crafting = 2, drainMs = DRAIN })
t.check(rsBusy.safe == false, "crafts in flight -> not safe")
t.eq(rsBusy.crafting, 2, "reports the in-flight count")
-- recent craft within the drain window -> not safe + reports a countdown
local rsDraining = control.rebootSafety({ now = 5000, lastCraftAt = 0, crafting = 0, drainMs = DRAIN })
t.check(rsDraining.safe == false, "recent craft within drain window -> not safe")
t.eq(rsDraining.secondsLeft, math.ceil((DRAIN - 5000) / 1000), "countdown = remaining drain seconds")
-- past the drain window -> safe again
local rsDrained = control.rebootSafety({ now = DRAIN + 1, lastCraftAt = 0, crafting = 0, drainMs = DRAIN })
t.check(rsDrained.safe == true, "past drain window -> safe")
-- a custom shorter window is honored
local rsShort = control.rebootSafety({ now = 10000, lastCraftAt = 0, crafting = 0, drainMs = 5000 })
t.check(rsShort.safe == true, "elapsed beyond custom drainMs -> safe")

-- ---------------------------------------------------------------------------
print("craft action (queue -> control gate)")
local entry = { name = "mek:alloy", label = "Infused Alloy", request = 128 }

-- craftAction maps a queue entry onto a well-formed autocraft action
local ca = control.craftAction(entry, { execute = function() end })
t.eq(ca.capability, control.CAPABILITY_AUTOCRAFT, "craftAction capability = autocraft")
t.eq(ca.target, "mek:alloy", "craftAction target = entry name")
t.eq(ca.amount, 128, "craftAction amount = request size")
t.check(ca.approved == true, "queued entry is approved by default (the queue IS approval)")
t.check(ca.enabled == true and ca.armed == true, "queued craft defaults enabled + armed")

local function craftSpy() local h = { n = 0 }; return h, function() h.n = h.n + 1; return true end end
local pCraftManual = control.policy({ mode = "manual", allowAutocraft = true })
local pCraftDry    = control.policy({ mode = "dry-run", allowAutocraft = true })
local pCraftNoCap  = control.policy({ mode = "manual", allowAutocraft = false })

-- dry-run never executes, even fully approved/armed/allowed
local h1, e1 = craftSpy()
t.check(control.execute(control.craftAction(entry, { execute = e1 }), pCraftDry) == false, "craft in dry-run -> false")
t.eq(h1.n, 0, "craft executor NOT called in dry-run")

-- manual + approved + armed + enabled + allowAutocraft + executor -> fires once
local h2, e2 = craftSpy()
control.execute(control.craftAction(entry, { execute = e2 }), pCraftManual)
t.eq(h2.n, 1, "craft executor called exactly once when every gate passes")

-- capability off -> blocked, no call
local h3, e3 = craftSpy()
t.check(control.execute(control.craftAction(entry, { execute = e3 }), pCraftNoCap) == false, "craft blocked when allowAutocraft false")
t.eq(h3.n, 0, "craft executor NOT called when capability off")

-- unapproved in manual (e.g. not yet tapped) -> waits, no call
local h4, e4 = craftSpy()
control.execute(control.craftAction(entry, { approved = false, execute = e4 }), pCraftManual)
t.eq(h4.n, 0, "craft executor NOT called while awaiting approval")

-- ---------------------------------------------------------------------------
print("palette theme resolution")
t.eq(palette.defaultTheme, "controlRoom", "default theme is controlRoom")
t.clearFiles()
t.eq(palette.resolveTheme("amber"), "amber", "valid override wins")
t.eq(palette.resolveTheme("nonsense"), "controlRoom", "invalid override + no file -> default")
t.setFile("atm10-theme", "green\n")
t.eq(palette.resolveTheme(nil), "green", "file value is used")
t.eq(palette.resolveTheme("nonsense"), "green", "invalid override falls through to file")
t.setFile("atm10-theme", "# a comment\nbadname\n-- lua comment\namber\n")
t.eq(palette.resolveTheme(nil), "amber", "comments and invalid lines skipped")
t.setFile("atm10-theme", "# only comments here\n")
t.eq(palette.resolveTheme(nil), "controlRoom", "comment-only file -> default")
t.clearFiles()
t.eq(palette.resolveTheme(nil), "controlRoom", "missing file -> default")

local okNil = palette.apply(nil)
t.check(okNil == false, "apply(nil target) -> false")
local applied = {}
local target = { setPaletteColour = function(slot) applied[slot] = true end }
local okApply, count, resolved = palette.apply(target, "amber")
t.check(okApply == true, "apply ok on a real target")
t.eq(resolved, "amber", "apply returns the resolved theme name")
t.check(count and count > 0, "apply set at least one palette slot")

-- ---------------------------------------------------------------------------
print("draw primitives")
-- fit: pad when short, truncate with "~" when long, handle tiny/zero widths
t.eq(draw.fit("ab", 5), "ab   ", "fit pads short text to width")
t.eq(draw.fit("abcdef", 4), "abc~", "fit truncates long text with ~")
t.eq(draw.fit("abc", 3), "abc", "fit exact width unchanged")
t.eq(draw.fit("abcd", 1), "a", "fit width<=1 hard-truncates, no ~")
t.eq(draw.fit(nil, 3), "   ", "fit nil text -> spaces")
t.eq(draw.fit("xy", 0), "", "fit width 0 -> empty")
t.eq(#draw.fit("anything", 7), 7, "fit output is always exactly width")

-- bracket: fixed-width [###---] gauge, clamped 0..100
t.eq(draw.bracket(0, 12), "[----------]", "bracket 0% empty")
t.eq(draw.bracket(100, 12), "[##########]", "bracket 100% full")
t.eq(draw.bracket(50, 12), "[#####-----]", "bracket 50% half")
t.eq(#draw.bracket(50, 12), 12, "bracket length == width")
t.eq(draw.bracket(-10, 12), "[----------]", "bracket clamps negative to 0")
t.eq(draw.bracket(150, 12), "[##########]", "bracket clamps >100 to 100")
t.eq(#draw.bracket(50, 2), 3, "bracket enforces min width 3")

-- barText and percentColor
t.eq(draw.barText(50, 10), "#####-----", "barText 50%")
t.eq(draw.barText(100, 10), "##########", "barText 100%")
t.check(draw.percentColor(10) == colors.red, "percentColor <15 -> red")
t.check(draw.percentColor(20) == colors.orange, "percentColor <35 -> orange")
t.check(draw.percentColor(50) == colors.yellow, "percentColor <65 -> yellow")
t.check(draw.percentColor(80) == colors.green, "percentColor >=65 -> green")

-- ---------------------------------------------------------------------------
print("stock planner (dry-run classification)")
local emptyLedger = { requests = {} }
local function SK(items, extra)
  local s = { enabled = true, cooldownSeconds = 300, maxCraftsPerCycle = 2, maxRequest = 4096, items = items }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

-- disabled keeper plans nothing (and never consults the ledger)
t.eq(#stockplan.plan({ stockKeeper = { enabled = false } }), 0, "disabled keeper -> no plans")

-- enabled with no ledger -> single BLOCKED row (fail closed)
local blocked = stockplan.plan({ stockKeeper = SK({ { name = "x", target = 10 } }), ledger = nil, ledgerError = "corrupt" })
t.eq(#blocked, 1, "nil ledger -> one row")
t.eq(blocked[1].action, "BLOCKED", "nil ledger -> BLOCKED (no crafting attempted)")
t.eq(blocked[1].reason, "corrupt", "BLOCKED carries the ledger error")

-- at/above target -> OK
local okP = stockplan.plan({ stockKeeper = SK({ { name = "g", target = 100 } }), ledger = emptyLedger,
  resolve = function() return 150, true, false end })
t.eq(okP[1].action, "OK", "amount >= target -> OK")

-- below target, not craftable -> NOT CRAFTABLE
local ncP = stockplan.plan({ stockKeeper = SK({ { name = "x", target = 100 } }), ledger = emptyLedger,
  resolve = function() return 0, false, false end })
t.eq(ncP[1].action, "NOT CRAFTABLE", "no recipe -> NOT CRAFTABLE")

-- below target, absent from the live item grid -> UNKNOWN-ID, not missing pattern
t.eq((stockplan.plan({ stockKeeper = SK({ { name = "missing:item", target = 100 } }), ledger = emptyLedger,
  resolve = function() return 0, false, false, false end })[1]).action,
  "UNKNOWN-ID", "missing live-grid ID -> UNKNOWN-ID")
t.eq((stockplan.plan({ stockKeeper = SK({ { name = "missing:item", target = 100 } }), ledger = emptyLedger,
  resolve = function() return 0, false, false, false end })[1]).reason,
  "not present in live RS item grid", "UNKNOWN-ID carries operator reason")

-- below target, absent from stored getItems rows but craftable -> WOULD CRAFT.
-- Live RS can omit zero-stock outputs from getItems while isCraftable/getCraftableItems
-- still proves the output ID and recipe exist.
_G.__zeroStoredCraftable = stockplan.plan({ stockKeeper = SK({ { name = "zero:item", target = 100, craftTo = 256 } }),
  ledger = emptyLedger, resolve = function() return 0, true, false, false end })
t.eq(_G.__zeroStoredCraftable[1].action, "WOULD CRAFT", "zero-stock craftable item is not UNKNOWN-ID")
t.eq(_G.__zeroStoredCraftable[1].request, 256, "zero-stock craftable request fills to craftTo")
_G.__zeroStoredCraftable = nil

-- below target, watch/manual route -> explicit BLOCKED reason, never a craft request
do
  local watchP = stockplan.plan({ stockKeeper = SK({
      { name = "mi:plate", label = "MI Plate", target = 100, craftTo = 200,
        craftMode = "watch", blockReason = "MI assembler route; do not RS autocraft" },
    }), ledger = emptyLedger, resolve = function() return 0, true, false end })
  t.eq(watchP[1].action, "BLOCKED", "watch-only target -> BLOCKED")
  t.eq(watchP[1].reason, "MI assembler route; do not RS autocraft", "watch-only target explains the route")
end

-- below target, craftable, already crafting -> ALREADY CRAFTING
local acP = stockplan.plan({ stockKeeper = SK({ { name = "x", target = 100 } }), ledger = emptyLedger,
  resolve = function() return 0, true, true end })
t.eq(acP[1].action, "ALREADY CRAFTING", "in-flight craft -> ALREADY CRAFTING")

-- below target, craftable, idle, no record -> WOULD CRAFT, request = craftTo - amount
local wcP = stockplan.plan({ stockKeeper = SK({ { name = "x", target = 100, craftTo = 256 } }), ledger = emptyLedger,
  resolve = function() return 40, true, false end })
t.eq(wcP[1].action, "WOULD CRAFT", "deficit -> WOULD CRAFT")
t.eq(wcP[1].request, 216, "request = craftTo - amount (256-40)")
t.eq(wcP[1].name, "x", "plan row carries the registry name (for approve/reconcile)")
t.check(wcP[1].capped == false, "not capped below maxRequest")
t.eq(wcP[1].category, "Stock Keeper", "items-only config falls back to Stock Keeper category")

-- exact numbers: refill to exactly the configured floor (no auto-band, no rounding)
local bandP = stockplan.plan({ stockKeeper = SK({ { name = "x", target = 100, craftTo = 100 } }),
  ledger = emptyLedger, resolve = function() return 99, true, false end })
t.eq(bandP[1].action, "WOULD CRAFT", "below the floor plans a refill")
t.eq(bandP[1].craftTo, 100, "craftTo is exactly the configured number (no auto-band)")
t.eq(bandP[1].configuredCraftTo, 100, "configured craftTo preserved on the row")
t.eq(bandP[1].request, 1, "request is the exact deficit to the floor")
t.check(bandP[1].banded == false, "no auto-band is applied")
local deepP = stockplan.plan({ stockKeeper = SK({ { name = "x", target = 100, craftTo = 100 } }),
  ledger = emptyLedger, resolve = function() return 40, true, false end })
t.eq(deepP[1].request, 60, "a larger deficit refills the full gap to the floor")

-- a refill band must not fight an overflow ceiling
local guardBand = stockplan.plan({ stockKeeper = SK({
    { name = "x", target = 100, craftTo = 200, ceiling = 150, into = { name = "block" } },
  }), ledger = emptyLedger, resolve = function() return 90, true, false end })
t.eq(guardBand[1].craftTo, 149, "craftTo is lowered below the ceiling")
t.eq(guardBand[1].request, 59, "request uses the adjusted craftTo")
t.check(guardBand[1].adjusted == true, "row marks the adjustment")
local badBand = stockplan.plan({ stockKeeper = SK({
    { name = "x", target = 100, craftTo = 100, ceiling = 100, into = { name = "block" } },
  }), ledger = emptyLedger, resolve = function() return 50, true, false end })
t.eq(badBand[1].action, "BLOCKED", "ceiling at/below target blocks instead of thrashing")
t.eq(badBand[1].reason, "ceiling must be greater than target", "blocked row explains the band problem")

-- request capped at maxRequest
local capP = stockplan.plan({ stockKeeper = SK({ { name = "x", target = 100, craftTo = 10000, maxRequest = 500 } }), ledger = emptyLedger,
  resolve = function() return 0, true, false end })
t.eq(capP[1].request, 500, "request capped to maxRequest")
t.check(capP[1].capped == true, "capped flag set")

-- recent ledger record within cooldown -> ON COOLDOWN with secondsLeft
local cdP = stockplan.plan({ stockKeeper = SK({ { name = "x", target = 100, craftTo = 200 } }),
  now = 100000, ledger = { requests = { x = { requestedAt = 40000 } } },
  resolve = function() return 0, true, false end })
t.eq(cdP[1].action, "ON COOLDOWN", "recent request -> ON COOLDOWN (no duplicate craft)")
t.eq(cdP[1].secondsLeft, 240, "secondsLeft = ceil((300000-60000)/1000)")

-- expired cooldown -> WOULD CRAFT again
local cdOld = stockplan.plan({ stockKeeper = SK({ { name = "x", target = 100, craftTo = 200 } }),
  now = 1000000, ledger = { requests = { x = { requestedAt = 600000 } } },
  resolve = function() return 0, true, false end })
t.eq(cdOld[1].action, "WOULD CRAFT", "expired cooldown -> WOULD CRAFT")

-- cycle cap: 3 deficits, cap 2 -> third is CYCLE CAP
local cyc = stockplan.plan({ stockKeeper = SK({
    { name = "a", target = 10, craftTo = 20 },
    { name = "b", target = 10, craftTo = 20 },
    { name = "c", target = 10, craftTo = 20 },
  }, { maxCraftsPerCycle = 2 }), ledger = emptyLedger,
  resolve = function() return 0, true, false end })
t.eq(cyc[1].action, "WOULD CRAFT", "1st within cycle cap")
t.eq(cyc[2].action, "WOULD CRAFT", "2nd within cycle cap")
t.eq(cyc[3].action, "CYCLE CAP", "3rd exceeds cycle cap")
local urgentCap = stockplan.plan({ stockKeeper = SK({
    { name = "low", target = 100, craftTo = 150 },
    { name = "urgent", target = 100, craftTo = 150 },
    { name = "mid", target = 100, craftTo = 150 },
  }, { maxCraftsPerCycle = 2 }), ledger = emptyLedger,
  resolve = function(name)
    if name == "low" then return 90, true, false end
    if name == "urgent" then return 10, true, false end
    return 50, true, false
  end })
t.eq(urgentCap[1].action, "CYCLE CAP", "least-deficient row loses the planner cycle cap")
t.eq(urgentCap[2].action, "WOULD CRAFT", "most-deficient row survives the planner cycle cap")
t.eq(urgentCap[3].action, "WOULD CRAFT", "next-most-deficient row survives the planner cycle cap")

-- compression-pair floor quotas below target on BOTH sides must not fight by
-- uncompressing/compressing the same material back and forth.
do
  local pairP = stockplan.plan({ stockKeeper = SK({
      { name = "ore:zinc_ingot", label = "Zinc Ingot", target = 1000, craftTo = 1000,
        into = { name = "ore:zinc_block", label = "Zinc Block" }, ratio = 9 },
      { name = "ore:zinc_block", label = "Zinc Block", target = 128, craftTo = 128 },
    }, { maxCraftsPerCycle = 2 }), ledger = emptyLedger,
    resolve = function(name)
      if name == "ore:zinc_ingot" then return 77, true, false end
      if name == "ore:zinc_block" then return 205, true, false end
      return 0, true, false
    end })
  t.eq(pairP[1].action, "WOULD CRAFT", "compression pair: source may refill from dense surplus")
  t.eq(pairP[2].action, "OK", "compression pair: dense side above target is still OK")
  pairP = stockplan.plan({ stockKeeper = SK({
      { name = "ore:zinc_ingot", label = "Zinc Ingot", target = 1000, craftTo = 1000,
        into = { name = "ore:zinc_block", label = "Zinc Block" }, ratio = 9 },
      { name = "ore:zinc_block", label = "Zinc Block", target = 1024, craftTo = 1024 },
    }, { maxCraftsPerCycle = 2 }), ledger = emptyLedger,
    resolve = function(name)
      if name == "ore:zinc_ingot" then return 77, true, false end
      if name == "ore:zinc_block" then return 205, true, false end
      return 0, true, false
    end })
  t.eq(pairP[1].action, "BLOCKED", "compression pair: source side blocked when both sides are low")
  t.eq(pairP[2].action, "BLOCKED", "compression pair: dense side blocked when both sides are low")
  t.check(pairP[1].reason:find("compression pair low", 1, true) ~= nil,
    "compression pair: blocked reason explains the pair conflict")
  t.eq(stockplan.compressionPairHold(SK({
      { name = "ore:zinc_ingot", label = "Zinc Ingot", target = 1000, craftTo = 1000,
        into = { name = "ore:zinc_block", label = "Zinc Block" }, ratio = 9 },
      { name = "ore:zinc_block", label = "Zinc Block", target = 1024, craftTo = 1024 },
    }), function(name) return name == "ore:zinc_ingot" and 77 or 205 end, "ore:zinc_block"),
    "compression pair low: Zinc Ingot and Zinc Block",
    "compression pair: runner hold helper returns the same explanatory reason")
end

do
  local planState = stockplan.compactState({
    { action = "OK", name = "ok", label = "OK", amount = 10, target = 5 },
    { action = "WOULD CRAFT", name = "craft1", label = "Craft 1", request = 32, priority = 0.9 },
    { action = "BLOCKED", name = "blocked", label = "Blocked", reason = "missing pattern" },
    { action = "WOULD CRAFT", name = "craft2", label = "Craft 2", request = 64, priority = 0.2 },
  }, { limit = 2 })
  t.eq(planState.total, 4, "compactState counts every plan row")
  t.eq(planState.counts["WOULD CRAFT"], 2, "compactState counts actions by name")
  t.eq(planState.wouldCraftCount, 2, "compactState counts WOULD CRAFT rows")
  t.eq(planState.wouldCraftAmount, 96, "compactState sums WOULD CRAFT request amount")
  t.eq(planState.blockedCount, 1, "compactState counts blocked/problem rows")
  t.eq(#planState.rows, 2, "compactState caps persisted non-OK detail rows")
  t.eq(planState.omitted, 1, "compactState reports omitted non-OK detail rows")
  t.eq(planState.rows[2].reason, "missing pattern", "compactState preserves blocked reason")
  t.eq(stockplan.compactState({
    { action = "UNKNOWN-ID", name = "ghost:item", label = "Ghost", reason = "not present in live RS item grid" },
  }).unknownIdCount, 1, "compactState counts UNKNOWN-ID rows separately")
end

-- ---------------------------------------------------------------------------
print("craft queue (manual mode, inert)")
local q = cqueue.new()
t.eq(cqueue.count(q), 0, "new queue is empty")

q = cqueue.approve(q, { name = "x", label = "Item X", request = 64 }, 10)
t.eq(cqueue.count(q), 1, "approve adds an entry")
t.check(cqueue.has(q, "x"), "approved item present")
t.eq(q.entries.x.state, cqueue.APPROVED, "entry marked APPROVED")
t.eq(q.entries.x.request, 64, "entry carries request size")

q = cqueue.approve(q, { name = "x", request = 128 }, 20) -- dedupe + refresh
t.eq(cqueue.count(q), 1, "re-approving same item dedupes")
t.eq(q.entries.x.request, 128, "re-approve refreshes the request")
t.eq(cqueue.failureCount(q), 0, "failureCount is zero without errors")
q.entries.x.error = "craft failed"
t.eq(cqueue.failureCount(q), 1, "failureCount counts errored entries")
q.entries.x.error = nil

q = cqueue.approve(q, { label = "no name" }, 30) -- missing name -> no-op
t.eq(cqueue.count(q), 1, "approve without a name is a no-op")

q = cqueue.approve(q, { name = "y", request = 16 }, 40)
local listed = cqueue.list(q)
t.eq(listed[1].name, "y", "list is newest-approval first")
local pqOrder = cqueue.new()
pqOrder = cqueue.approve(pqOrder, { name = "old-urgent", request = 1, priority = 0.9 }, 10)
pqOrder = cqueue.approve(pqOrder, { name = "new-low", request = 1, priority = 0.1 }, 20)
t.eq(cqueue.list(pqOrder)[1].name, "new-low", "default queue list stays newest first")
t.eq(cqueue.list(pqOrder, { priority = true })[1].name, "old-urgent",
  "priority queue list puts urgent approved entries first")

-- get: read-only lookup used by auto-approve to branch on entry state
t.eq(cqueue.get(q, "x").state, cqueue.APPROVED, "get returns the entry")
t.eq(cqueue.get(q, "missing"), nil, "get returns nil for absent key")
t.eq(cqueue.get(q, nil), nil, "get(nil) is nil")

-- autoApprove: auto mode enqueues craftable deficits with a skip/re-arm guard
local aq = cqueue.new()
local autoPlans = {
  { action = "WOULD CRAFT", name = "iron", label = "Iron", request = 100 },
  { action = "OK", name = "gold", request = 50 },             -- satisfied, skip
  { action = "NOT CRAFTABLE", name = "tin", request = 50 },   -- no pattern, skip
  { action = "ON COOLDOWN", name = "lead", request = 50 },    -- backing off, skip
  { action = "WOULD CRAFT", name = "zinc", request = 0 },     -- nothing to craft, skip
  { action = "WOULD CRAFT", name = "copper", label = "Copper", key = "compress:copper", kind = "compress", request = 9 },
}
local _, an1 = cqueue.autoApprove(aq, autoPlans, 100)
t.eq(an1, 2, "autoApprove approves only WOULD CRAFT rows with a positive request")
t.check(cqueue.has(aq, "iron"), "autoApprove enqueued the refill deficit")
t.check(cqueue.has(aq, "compress:copper"), "autoApprove enqueued the overflow deficit under its compress key")
t.eq(cqueue.get(aq, "compress:copper").kind, "compress", "queue entry preserves the compress row kind (needed by the future void/discard path)")
t.eq(cqueue.has(aq, "gold"), false, "autoApprove skipped the OK row")
t.eq(cqueue.has(aq, "zinc"), false, "autoApprove skipped the zero-request row")

local _, an2 = cqueue.autoApprove(aq, autoPlans, 200)
t.eq(an2, 0, "autoApprove skips entries already APPROVED and waiting")
t.eq(cqueue.get(aq, "iron").approvedAt, 100, "skip leaves the original timestamp untouched")
local _, an2b = cqueue.autoApprove(aq, {
  { action = "WOULD CRAFT", name = "iron", label = "Iron", request = 200, priority = 0.9 },
}, 250)
t.eq(an2b, 0, "refreshing an APPROVED auto row does not count as a new approval")
t.eq(cqueue.get(aq, "iron").approvedAt, 100, "refresh keeps the original approval time")
t.eq(cqueue.get(aq, "iron").request, 200, "refresh updates the planned request size")
t.eq(cqueue.get(aq, "iron").priority, 0.9, "refresh updates urgency for runner ordering")

cqueue.markCrafting(aq, "iron", 150)
local _, an3 = cqueue.autoApprove(aq, autoPlans, 300)
t.eq(an3, 1, "autoApprove re-arms a CRAFTING entry that is WOULD CRAFT again (next batch)")
t.eq(cqueue.get(aq, "iron").state, cqueue.APPROVED, "re-armed entry is APPROVED again")

local _, an4 = cqueue.autoApprove(aq, nil, 400)
t.eq(an4, 0, "autoApprove(nil plans) is a no-op")

do
  local limitedAutoPlans = {
    { action = "WOULD CRAFT", name = "auto:a", label = "A", request = 10 },
    { action = "WOULD CRAFT", name = "auto:b", label = "B", request = 10 },
    { action = "WOULD CRAFT", name = "auto:c", label = "C", request = 10 },
  }
  local lq = cqueue.new()
  local _, ln1 = cqueue.autoApprove(lq, limitedAutoPlans, 500, { maxNew = 1, maxQueued = 2 })
  t.eq(ln1, 1, "autoApprove maxNew admits only one absent row per call")
  t.eq(cqueue.count(lq), 1, "autoApprove maxNew leaves later absent rows out of the queue")
  local _, ln2 = cqueue.autoApprove(lq, limitedAutoPlans, 600, { maxNew = 2, maxQueued = 2 })
  t.eq(ln2, 1, "autoApprove maxQueued admits only up to the configured non-manual backlog")
  t.eq(cqueue.count(lq), 2, "autoApprove maxQueued keeps the backlog bounded")
  local _, ln3 = cqueue.autoApprove(lq, limitedAutoPlans, 700, { maxNew = 2, maxQueued = 2 })
  t.eq(ln3, 0, "autoApprove maxQueued blocks additional absent rows once backlog is full")
  t.eq(cqueue.has(lq, "auto:c"), false, "autoApprove maxQueued did not enqueue the third deficit")
  local _, ln4 = cqueue.autoApprove(lq, {
    { action = "WOULD CRAFT", name = "auto:a", label = "A2", request = 20, priority = 0.8 },
    { action = "WOULD CRAFT", name = "auto:c", label = "C", request = 10 },
  }, 800, { maxNew = 2, maxQueued = 2 })
  t.eq(ln4, 0, "autoApprove refreshes existing rows at cap without counting a new approval")
  t.eq(cqueue.get(lq, "auto:a").request, 20, "autoApprove refresh at cap updates existing request")
  t.eq(cqueue.get(lq, "auto:a").priority, 0.8, "autoApprove refresh at cap updates existing priority")

  local fq = cqueue.new()
  cqueue.approve(fq, { name = "auto:failed", label = "Failed", request = 10 }, 900)
  cqueue.markError(fq, "auto:failed", 901, "craft failed")
  local _, fn = cqueue.autoApprove(fq, limitedAutoPlans, 1000, { maxNew = 2, maxQueued = 2 })
  t.eq(fn, 2, "autoApprove maxQueued ignores failed quarantined rows for runnable capacity")
  t.check(cqueue.has(fq, "auto:a"), "autoApprove admitted first healthy row despite failed row")
  t.check(cqueue.has(fq, "auto:b"), "autoApprove admitted second healthy row despite failed row")
  t.eq(cqueue.get(fq, "auto:failed").error, "craft failed", "autoApprove left failed row quarantined")
end

q = cqueue.cancel(q, "y")
t.check(cqueue.has(q, "y") == false, "cancel removes an entry")
t.eq(cqueue.count(q), 1, "cancel decrements count")

-- reconcile: drop items whose stock is now satisfied
q = cqueue.approve(q, { name = "z", request = 8 }, 50)
local _, removed = cqueue.reconcile(q, { x = true })
t.eq(removed, 1, "reconcile removes satisfied items")
t.check(cqueue.has(q, "x") == false, "satisfied item dropped")
t.check(cqueue.has(q, "z"), "unsatisfied item kept")

-- prune: age out stale approvals
local pq = cqueue.approve(cqueue.new(), { name = "old", request = 1 }, 0)
pq = cqueue.approve(pq, { name = "new", request = 1 }, 900)
local _, pruned = cqueue.prune(pq, 1000, 500)
t.eq(pruned, 1, "prune removes entries older than maxAge")
t.check(cqueue.has(pq, "old") == false, "stale entry pruned")
t.check(cqueue.has(pq, "new"), "fresh entry kept")
local _, noPrune = cqueue.prune(pq, 1000000, 0)
t.eq(noPrune, 0, "maxAge<=0 disables pruning")

t.eq(cqueue.count(cqueue.normalize("garbage")), 0, "normalize coerces garbage to empty")

-- keyed identity: a refill and a compress that craft the SAME item don't alias
local kq = cqueue.new()
kq = cqueue.approve(kq, { name = "iron_ingot", request = 100 }, 1)                              -- refill, key=name
kq = cqueue.approve(kq, { name = "iron_ingot", key = "compress:iron_dust", request = 50 }, 2)   -- compress -> ingot
t.eq(cqueue.count(kq), 2, "refill + compress of the same item are two distinct entries")
t.check(cqueue.has(kq, "iron_ingot"), "refill entry present under its name key")
t.check(cqueue.has(kq, "compress:iron_dust"), "compress entry present under its compress key")
-- reconcile by the refill's name must NOT drop the compress entry
local _, kremoved = cqueue.reconcile(kq, { iron_ingot = true })
t.eq(kremoved, 1, "satisfied iron_ingot drops only the refill entry")
t.check(cqueue.has(kq, "compress:iron_dust"), "compress entry survives the refill being satisfied")
t.check(cqueue.has(kq, "iron_ingot") == false, "refill entry removed")

-- state transitions used by the craft runner
local sq = cqueue.approve(cqueue.new(), { name = "s", request = 4 }, 10)
cqueue.markCrafting(sq, "s", 20, 2)
t.eq(sq.entries.s.state, cqueue.CRAFTING, "markCrafting sets CRAFTING state")
t.eq(sq.entries.s.craftingAt, 20, "markCrafting stamps craftingAt")
t.eq(sq.entries.s.inflightRequest, 2, "markCrafting stores the in-flight batch amount")
cqueue.markError(sq, "s", 30, "boom")
t.eq(sq.entries.s.error, "boom", "markError records the reason")
t.eq(sq.entries.s.triedAt, 30, "markError stamps triedAt for backoff")
_G.__jobQ = cqueue.approve(cqueue.new(), { name = "jobbed", request = 16 }, 31)
cqueue.markCrafting(_G.__jobQ, "jobbed", 32, 8, 4242)
t.eq(select(1, cqueue.findByJobId(_G.__jobQ, "4242")), "jobbed", "findByJobId matches AP job ids")
cqueue.markJobStarted(_G.__jobQ, 4242, 33)
t.eq(_G.__jobQ.entries.jobbed.craftingStartedAt, 33, "markJobStarted records AP CRAFTING_STARTED")
cqueue.completeJobId(_G.__jobQ, 4242)
t.check(cqueue.has(_G.__jobQ, "jobbed") == false, "completeJobId drops the completed queue entry")
_G.__jobFailQ = cqueue.approve(cqueue.new(), { name = "failed", request = 16 }, 34)
cqueue.markCrafting(_G.__jobFailQ, "failed", 35, 8, "job-9")
_, _G.__failedOriginal = cqueue.failJobId(_G.__jobFailQ, "job-9", 36, "MISSING_ITEMS")
t.eq(_G.__jobFailQ.entries.failed.state, cqueue.APPROVED, "failJobId returns failed AP jobs to APPROVED")
t.eq(_G.__jobFailQ.entries.failed.error, "MISSING_ITEMS", "failJobId stores the AP failure reason")
t.eq(_G.__jobFailQ.entries.failed.jobId, nil, "failJobId clears the completed AP job id")
t.eq(_G.__jobFailQ.entries.failed.inflightRequest, nil, "failJobId clears live inflight request")
t.eq(_G.__failedOriginal.inflightRequest, 8, "failJobId returns original entry for accurate audit amount")
_G.__jobProgressQ = cqueue.approve(cqueue.new(), { name = "progress", amount = 100, request = 4096 }, 37)
cqueue.markCrafting(_G.__jobProgressQ, "progress", 38, 32, "job-10")
_, _G.__jobProgressEntry, _, _G.__jobProgressMade, _G.__jobProgressDone =
  cqueue.progressJobId(_G.__jobProgressQ, "job-10", { progress = 132 }, 39)
t.check(_G.__jobProgressEntry ~= nil, "progressJobId: stock gain turns terminal AP failure into progress")
t.eq(_G.__jobProgressMade, 32, "progressJobId: progress is capped to the in-flight batch")
t.eq(_G.__jobProgressDone, false, "progressJobId: partial progress does not complete the full row")
t.eq(_G.__jobProgressQ.entries.progress.request, 4064, "progressJobId: partial progress reduces remaining request")
t.eq(_G.__jobProgressQ.entries.progress.amount, 132, "progressJobId: partial progress refreshes stock baseline")
t.eq(_G.__jobProgressQ.entries.progress.error, nil, "progressJobId: partial progress clears the failure state")
_G.__jobCompleteQ = cqueue.approve(cqueue.new(), { name = "complete", amount = 10, request = 32 }, 40)
cqueue.markCrafting(_G.__jobCompleteQ, "complete", 41, 32, "job-11")
_, _G.__jobCompleteEntry, _, _G.__jobCompleteMade, _G.__jobCompleteDone =
  cqueue.progressJobId(_G.__jobCompleteQ, "job-11", { complete = 42 }, 42)
t.check(_G.__jobCompleteEntry ~= nil, "progressJobId: full batch progress is detected")
t.eq(_G.__jobCompleteMade, 32, "progressJobId: full batch made amount is reported")
t.eq(_G.__jobCompleteDone, true, "progressJobId: full batch progress can complete the row")
t.check(cqueue.has(_G.__jobCompleteQ, "complete") == false, "progressJobId: completed row is dropped")
cqueue.markCrafting(sq, "absent", 40) -- no-op on a missing entry
t.check(cqueue.has(sq, "absent") == false, "markCrafting on a missing entry is a no-op")
_G.__staleQ = cqueue.new()
cqueue.approve(_G.__staleQ, { name = "stuck", request = 8 }, 1)
cqueue.markCrafting(_G.__staleQ, "stuck", 10)
t.eq(select(2, cqueue.failInactiveCrafting(_G.__staleQ, {}, 20, 20, "no active RS task")), 0,
  "failInactiveCrafting: grace period keeps fresh CRAFTING rows")
t.eq(select(2, cqueue.failInactiveCrafting(_G.__staleQ, {}, 31, 20, "no active RS task")), 1,
  "failInactiveCrafting: stale inactive CRAFTING row is marked")
t.eq(_G.__staleQ.entries.stuck.state, cqueue.APPROVED,
  "failInactiveCrafting: stale inactive row returns to APPROVED")
t.eq(_G.__staleQ.entries.stuck.error, "no active RS task",
  "failInactiveCrafting: stale inactive row records retryable reason")
_G.__activeQ = cqueue.new()
cqueue.approve(_G.__activeQ, { name = "active", request = 8 }, 1)
cqueue.markCrafting(_G.__activeQ, "active", 10)
t.eq(select(2, cqueue.failInactiveCrafting(_G.__activeQ, { active = true }, 100, 20, "no active RS task")), 0,
  "failInactiveCrafting: active RS task stays CRAFTING")
t.eq(_G.__activeQ.entries.active.state, cqueue.CRAFTING,
  "failInactiveCrafting: active task entry is unchanged")
_G.__partialQ = cqueue.new()
cqueue.approve(_G.__partialQ, { name = "partial", amount = 0, request = 128 }, 1)
cqueue.markCrafting(_G.__partialQ, "partial", 10, 64)
_, _G.__partialStale, _G.__partialProgress = cqueue.reconcileInactiveCrafting(_G.__partialQ, {},
  { partial = 64 }, 31, 20, "no active RS task")
t.eq(_G.__partialStale, 0, "reconcileInactiveCrafting: stock progress is not stale")
t.eq(_G.__partialProgress, 1, "reconcileInactiveCrafting: inactive row with stock progress is counted")
t.eq(_G.__partialQ.entries.partial.state, cqueue.APPROVED,
  "reconcileInactiveCrafting: partial progress returns row to APPROVED")
t.eq(_G.__partialQ.entries.partial.request, 64,
  "reconcileInactiveCrafting: partial progress reduces the remaining request")
t.eq(_G.__partialQ.entries.partial.amount, 64,
  "reconcileInactiveCrafting: partial progress refreshes the stock baseline")
t.eq(_G.__partialQ.entries.partial.error, nil,
  "reconcileInactiveCrafting: partial progress clears stale error state")
_G.__silentQ = cqueue.new()
cqueue.approve(_G.__silentQ, { name = "silent", amount = 0, request = 128 }, 1)
cqueue.markCrafting(_G.__silentQ, "silent", 10, 64)
_, _G.__silentStale, _G.__silentProgress = cqueue.reconcileInactiveCrafting(_G.__silentQ, {},
  { silent = 0 }, 31, 20, "no active RS task")
t.eq(_G.__silentStale, 1, "reconcileInactiveCrafting: no active task and no stock progress is stale")
t.eq(_G.__silentProgress, 0, "reconcileInactiveCrafting: silent reject has no progress")
t.eq(_G.__silentQ.entries.silent.error, "no active RS task",
  "reconcileInactiveCrafting: silent reject records retryable reason")
_G.__staleQ, _G.__activeQ, _G.__partialQ, _G.__silentQ = nil, nil, nil, nil
_G.__jobProgressQ, _G.__jobProgressEntry, _G.__jobProgressMade, _G.__jobProgressDone = nil, nil, nil, nil
_G.__jobCompleteQ, _G.__jobCompleteEntry, _G.__jobCompleteMade, _G.__jobCompleteDone = nil, nil, nil, nil
_G.__partialStale, _G.__partialProgress, _G.__silentStale, _G.__silentProgress = nil, nil, nil, nil

-- per-item last-craft results (QUICK-5): record ok/reason/timestamp, bounded
local res = {}
cqueue.recordResult(res, "iron", true, nil, 100)
t.check(res.iron.ok == true and res.iron.at == 100 and res.iron.reason == nil, "recordResult stores an OK outcome")
cqueue.recordResult(res, "iron", false, "bridge offline", 200)
t.check(res.iron.ok == false and res.iron.reason == "bridge offline" and res.iron.at == 200, "recordResult overwrites with the latest (failed) outcome + reason")
cqueue.recordResult(res, "gold", false, nil, 150)
t.eq(res.gold.reason, "rejected", "recordResult defaults a missing reason")
-- pruneResults caps to the newest N by `at` (drop-oldest)
local rp = {}
for i = 1, 10 do rp["i" .. i] = { ok = true, at = i } end -- i1 oldest, i10 newest
local _, rpRemoved = cqueue.pruneResults(rp, 4)
local rpN = 0; for _ in pairs(rp) do rpN = rpN + 1 end
t.eq(rpN, 4, "pruneResults caps to max (10 -> 4)")
t.eq(rpRemoved, 6, "pruneResults reports the dropped count")
t.check(rp.i1 == nil and rp.i10 ~= nil, "pruneResults drops the OLDEST, keeps the newest")
t.eq(select(2, cqueue.pruneResults({ a = { at = 1 } }, 0)), 0, "pruneResults with max<=0 disables the cap")
-- prune-on-LOAD shape: loadCraftResults bounds the map by calling pruneResults and
-- returning only the (mutated) map via `(cqueue.pruneResults(data, max))`. Pin that
-- parenthesized single-return so a 300-entry oversized file is bounded on load.
local rpLoad = {}
for i = 1, 300 do rpLoad["x" .. i] = { ok = true, at = i } end
local loaded = (cqueue.pruneResults(rpLoad, 150)) -- parens drop the count, as the loader does
local loadedN = 0; for _ in pairs(loaded) do loadedN = loadedN + 1 end
t.eq(loadedN, 150, "prune-on-load bounds an oversized craft-results map (300 -> 150)")
t.check(loaded.x300 ~= nil and loaded.x1 == nil, "prune-on-load keeps newest, drops oldest")

-- chronological craft audit: append compact events, cap to the newest tail
do
  local audit = {}
  cqueue.recordAudit(audit, {
    at = 100, kind = "requested", key = "compress:iron", name = "iron_ingot",
    request = 64, ok = true, stockAtScan = 12, activeCraftMethod = "getCraftingTasks",
    activeCraftCount = 1, activeNow = false, queueDepth = 3,
  })
  t.eq(#audit, 1, "recordAudit appends one event")
  t.eq(audit[1].amount, 64, "recordAudit normalizes request/amount")
  t.eq(audit[1].stockAtScan, 12, "recordAudit keeps stockAtScan for live debugging")
  t.eq(audit[1].activeCraftMethod, "getCraftingTasks", "recordAudit keeps active-task method")
  local auditMany = {}
  for i = 1, 10 do cqueue.recordAudit(auditMany, { at = i, kind = "failed", name = "item" .. i }) end
  local _, auditRemoved = cqueue.pruneAudit(auditMany, 4)
  t.eq(#auditMany, 4, "pruneAudit caps to max (10 -> 4)")
  t.eq(auditRemoved, 6, "pruneAudit reports dropped count")
  t.eq(auditMany[1].name, "item7", "pruneAudit preserves chronological order of retained tail")
  t.eq(select(2, cqueue.pruneAudit({ { at = 1 } }, 0)), 0, "pruneAudit max<=0 disables the cap")
end

-- ---------------------------------------------------------------------------
print("manual jobs (queue): enqueue/recordMade/jobComplete/field-roundtrip")
do
-- enqueueJob makes a kind=MANUAL entry keyed "manual:<name>" that does NOT alias a
-- same-name quota. BITE: default the key to name and count drops to 1 / the quota is
-- overwritten.
local mq = cqueue.approve(cqueue.new(), { name = "mek:steel", request = 10, priority = 0.5 }, 1) -- a quota
local _, mkey = cqueue.enqueueJob(mq, { name = "mek:steel", label = "Steel", requested = 64 }, 5)
t.eq(mkey, "manual:mek:steel", "enqueueJob keys a job manual:<name>")
t.eq(cqueue.count(mq), 2, "a job does not alias a same-name quota (both entries present)")
t.check(mq.entries["mek:steel"] ~= nil and mq.entries["mek:steel"].kind ~= cqueue.MANUAL, "the quota entry is untouched")
local mjob = mq.entries["manual:mek:steel"]
t.eq(mjob.kind, cqueue.MANUAL, "job entry is kind=MANUAL")
t.eq(mjob.requested, 64, "job carries the immutable target N")
t.eq(mjob.made, 0, "job starts with made=0")
t.eq(mjob.request, 64, "job's first-fire batch is the full remaining (requested-made)")
t.eq(mjob.state, cqueue.APPROVED, "job is APPROVED on enqueue")
t.check(cqueue.isManual(mjob) == true, "isManual recognizes the job")
t.check(cqueue.isManual(mq.entries["mek:steel"]) == false, "isManual rejects a quota entry")

-- recordMade accumulates; jobComplete flips exactly at made>=requested (not >). BITE:
-- jobComplete using > would leave made=N as incomplete.
cqueue.recordMade(mq, "manual:mek:steel", 30, 10)
t.eq(mq.entries["manual:mek:steel"].made, 30, "recordMade accumulates made")
t.check(cqueue.jobComplete(mq, "manual:mek:steel") == false, "jobComplete false while made < requested")
cqueue.recordMade(mq, "manual:mek:steel", 33, 11)
t.eq(mq.entries["manual:mek:steel"].made, 63, "recordMade keeps accumulating")
t.check(cqueue.jobComplete(mq, "manual:mek:steel") == false, "jobComplete still false at made=63 < 64")
cqueue.recordMade(mq, "manual:mek:steel", 1, 12)
t.check(cqueue.jobComplete(mq, "manual:mek:steel") == true, "jobComplete flips true exactly at made==requested")
cqueue.recordMade(mq, "mek:steel", 99, 13) -- no-op on a non-manual entry
t.check(mq.entries["mek:steel"].made == nil or mq.entries["mek:steel"].made == 0, "recordMade is a no-op on a quota entry")

-- copyPlanFields preserves made/requested across a re-approve (the manager refreshes
-- request each cycle via approve). BITE: drop `dest.made = ... or dest.made` and made
-- resets to 0 on re-approve.
local rj = cqueue.new()
cqueue.enqueueJob(rj, { name = "x", requested = 50 }, 1)
cqueue.recordMade(rj, "manual:x", 20, 2)
cqueue.approve(rj, { key = "manual:x", name = "x", kind = cqueue.MANUAL, requested = 50, request = 30, priority = 0.2 }, 3)
t.eq(rj.entries["manual:x"].made, 20, "re-approve preserves made (not reset to 0)")
t.eq(rj.entries["manual:x"].requested, 50, "re-approve preserves requested")

-- dropJob removes the entry and returns it for the completion flash
local dj = cqueue.new()
cqueue.enqueueJob(dj, { name = "d", label = "Dee", requested = 4 }, 1)
local _, dropped = cqueue.dropJob(dj, "manual:d")
t.check(cqueue.has(dj, "manual:d") == false, "dropJob removes the entry")
t.eq(dropped.name, "d", "dropJob returns the dropped entry")

-- force flag round-trips
local fj = cqueue.new()
cqueue.enqueueJob(fj, { name = "f", requested = 5, force = true }, 1)
t.check(fj.entries["manual:f"].force == true, "enqueueJob carries the force flag")
end

-- ---------------------------------------------------------------------------
print("craft runner (gated execution)")
local function mkQ(items)
  local q = cqueue.new()
  for i, e in ipairs(items) do q = cqueue.approve(q, e, i) end
  return q
end
local pManualCraft = control.policy({ mode = "manual", allowAutocraft = true })

-- manual + approved + capability: crafts once, transitions to CRAFTING, records
-- the ledger, and is NOT re-requested on the next pass
local crafted, recorded = {}, {}
local q = mkQ({ { name = "x", label = "X", request = 64 } })
local deps = {
  policy = pManualCraft, mode = "manual", now = 1000, cooldownMs = 300000,
  isCrafting = function() return false end,
  craft = function(name, amt) crafted[#crafted + 1] = { name, amt }; return true end,
  recordRequest = function(name, amt, now) recorded[#recorded + 1] = { name, amt, now } end,
}
craftrunner.run(q, deps)
t.eq(#crafted, 1, "approved entry crafts exactly once")
t.eq(crafted[1][1], "x", "crafted the right item")
t.eq(crafted[1][2], 64, "crafted the requested amount")
t.eq(#recorded, 1, "ledger recorded on a successful request")
t.eq(q.entries.x.state, cqueue.CRAFTING, "entry transitions APPROVED -> CRAFTING")
deps.now = 2000
craftrunner.run(q, deps)
t.eq(#crafted, 1, "a CRAFTING entry is never re-requested")

-- dry-run: gate closed -> bridge never called, entry stays APPROVED
local c2 = {}
local qd = mkQ({ { name = "y", request = 16 } })
craftrunner.run(qd, { policy = control.policy({ mode = "dry-run", allowAutocraft = true }),
  mode = "dry-run", now = 1, isCrafting = function() return false end,
  craft = function() c2[#c2 + 1] = true; return true end })
t.eq(#c2, 0, "dry-run never calls the bridge")
t.eq(qd.entries.y.state, cqueue.APPROVED, "dry-run leaves the entry APPROVED")

-- capability off: blocked, no craft
local c3 = {}
craftrunner.run(mkQ({ { name = "z", request = 8 } }),
  { policy = control.policy({ mode = "manual", allowAutocraft = false }),
    mode = "manual", now = 1, isCrafting = function() return false end,
    craft = function() c3[#c3 + 1] = true; return true end })
t.eq(#c3, 0, "allowAutocraft=false blocks the bridge call")

-- RS already crafting it: adopt CRAFTING with no bridge call
local c4 = {}
local qa = mkQ({ { name = "w", request = 4 } })
craftrunner.run(qa, { policy = pManualCraft, mode = "manual", now = 5,
  isCrafting = function() return true end,
  craft = function() c4[#c4 + 1] = true; return true end })
t.eq(#c4, 0, "no craft request when RS is already crafting the item")
t.eq(qa.entries.w.state, cqueue.CRAFTING, "adopts CRAFTING for an in-flight item")

-- bridge rejects in manual mode: stays APPROVED, records error, and waits for
-- explicit operator retry instead of re-firing after cooldown.
local tries = 0
local qf = mkQ({ { name = "f", request = 32 } })
local depsF = { policy = pManualCraft, mode = "manual", now = 1000, cooldownMs = 300000,
  isCrafting = function() return false end,
  craft = function() tries = tries + 1; return false, "missing ingredients" end }
craftrunner.run(qf, depsF)
t.eq(tries, 1, "failed craft is attempted once")
t.eq(qf.entries.f.state, cqueue.APPROVED, "a failed craft stays APPROVED for retry")
t.eq(qf.entries.f.error, "missing ingredients", "failure reason is recorded")
t.eq(cqueue.retryRemainingMs(qf.entries.f, 1000 + 100000, 300000), 200000,
  "retryRemainingMs reports the failed-entry backoff window")
t.eq(cqueue.retryLabel(qf.entries.f, 1000 + 295000, 300000), "retry 5s",
  "retryLabel surfaces a short countdown")
t.eq(cqueue.retryLabel(qf.entries.f, 1000 + 1000, 300000), "retry 5m",
  "retryLabel rounds longer waits up to minutes")
depsF.now = 1000 + 100000
craftrunner.run(qf, depsF)
t.eq(tries, 1, "no retry within the backoff cooldown")
depsF.now = 1000 + 400000
craftrunner.run(qf, depsF)
t.eq(tries, 1, "manual failed approval does not retry after cooldown without operator action")
qf = cqueue.retryFailed(qf, 1000 + 401000)
depsF.now = 1000 + 402000
craftrunner.run(qf, depsF)
t.eq(tries, 2, "manual failed approval retries after RETRY FAILED clears the error")

tries = 0
qf = mkQ({ { name = "fa", request = 32 } })
depsF = { policy = control.policy({ mode = "auto", allowAutocraft = true }), mode = "auto",
  now = 2000, cooldownMs = 300000,
  isCrafting = function() return false end,
  craft = function() tries = tries + 1; return false, "missing ingredients" end }
craftrunner.run(qf, depsF)
depsF.now = 2000 + 400000
craftrunner.run(qf, depsF)
t.eq(tries, 2, "auto failed approval still retries after cooldown")

qf = mkQ({ { name = "f", request = 32 } })
tries = 0
depsF = { policy = control.policy({ mode = "auto", allowAutocraft = true }), mode = "auto",
  now = 2500, cooldownMs = 300000, holdFailed = true,
  isCrafting = function() return false end,
  craft = function() tries = tries + 1; return false, "craft failed" end }
craftrunner.run(qf, depsF)
depsF.now = 2500 + 400000
_G.__failStopSummary = craftrunner.run(qf, depsF)
t.eq(tries, 1, "holdFailed stops auto retry after cooldown")
t.eq(#_G.__failStopSummary.held, 1, "holdFailed surfaces the held failed row")
_G.__failStopSummary = nil

qf = mkQ({ { name = "bad", request = 32 }, { name = "good", request = 32 } })
qf.entries.bad.error = "craft failed"
tries = 0
depsF = { policy = control.policy({ mode = "auto", allowAutocraft = true }), mode = "auto",
  now = 2600, cooldownMs = 300000, holdFailed = true, holdWhenAnyFailed = true,
  isCrafting = function() return false end,
  craft = function() tries = tries + 1; return true end }
_G.__failStopSummary = craftrunner.run(qf, depsF)
t.eq(tries, 0, "holdWhenAnyFailed stops healthy quota rows while failures remain")
t.eq(#_G.__failStopSummary.held, 2, "holdWhenAnyFailed surfaces both held rows")
_G.__failStopSummary = nil

tries = 0
qf = mkQ({ { name = "hard", request = 32 } })
depsF = { policy = control.policy({ mode = "auto", allowAutocraft = true }), mode = "auto",
  now = 3000, cooldownMs = 300000,
  isCrafting = function() return false end,
  craft = function() tries = tries + 1; return false, "UNKNOWN_ERROR" end }
craftrunner.run(qf, depsF)
depsF.now = 3000 + 400000
_G.__hardSummary = craftrunner.run(qf, depsF)
t.eq(tries, 1, "auto hard AP failure does not retry after cooldown")
t.eq(#_G.__hardSummary.held, 1, "auto hard AP failure is surfaced as held")
t.eq(_G.__hardSummary.held[1].reason, "UNKNOWN_ERROR", "auto hard AP failure preserves the terminal reason")
_G.__hardSummary = nil
qf = mkQ({ { name = "ra", request = 1 }, { name = "rb", request = 1 } })
cqueue.markError(qf, "ra", 20, "bridge offline")
qf, tries = cqueue.retryFailed(qf, 30)
t.eq(tries, 1, "retryFailed counts failed approvals reset for immediate retry")
t.eq(qf.entries.ra.error, nil, "retryFailed clears the failure reason")
t.eq(qf.entries.ra.triedAt, nil, "retryFailed clears the backoff timestamp")
t.eq(qf.entries.ra.approvedAt, 30, "retryFailed refreshes approval age for reset entries")
t.eq(qf.entries.rb.approvedAt, 2, "retryFailed leaves healthy approvals alone")

do
  local qh = mkQ({ { name = "ore:zinc_block", request = 32 } })
  local hSummary = craftrunner.run(qh, { policy = pManualCraft, mode = "manual", now = 1,
    holdReason = function() return "compression pair low: Zinc Ingot and Zinc Block" end,
    isCrafting = function() return false end,
    craft = function() error("held row must not reach craft", 0) end })
  t.eq(#hSummary.held, 1, "runner: held queue row is surfaced in summary.held")
  t.eq(qh.entries["ore:zinc_block"].state, cqueue.APPROVED, "runner: held queue row stays approved")
  t.eq(qh.entries["ore:zinc_block"].error, "compression pair low: Zinc Ingot and Zinc Block",
    "runner: held queue row records the explanatory reason")
end

-- maxPerCycle caps NEW bridge requests per run; the rest stay APPROVED
local fired = {}
local qcap = cqueue.new()
qcap = cqueue.approve(qcap, { name = "low", request = 1, priority = 0.1 }, 30)
qcap = cqueue.approve(qcap, { name = "urgent", request = 1, priority = 0.9 }, 10)
qcap = cqueue.approve(qcap, { name = "mid", request = 1, priority = 0.5 }, 20)
craftrunner.run(qcap, { policy = pManualCraft, mode = "manual", now = 1, maxPerCycle = 2,
  isCrafting = function() return false end,
  craft = function(name) fired[#fired + 1] = name; return true end })
t.eq(#fired, 2, "maxPerCycle=2 fires only two requests this cycle")
t.eq(fired[1], "urgent", "runner fires the most-deficient approved item first")
t.eq(fired[2], "mid", "runner uses priority before approval age under the cap")
local approvedLeft = 0
for _, e in pairs(qcap.entries) do if e.state == cqueue.APPROVED then approvedLeft = approvedLeft + 1 end end
t.eq(approvedLeft, 1, "the third entry stays APPROVED for next cycle")

-- two entries with distinct keys but the SAME crafted item fire craft() once/run
local dq = cqueue.new()
dq = cqueue.approve(dq, { name = "copper_ingot", key = "compress:copper_dust", request = 10 }, 1)
dq = cqueue.approve(dq, { name = "copper_ingot", key = "compress:copper_nugget", request = 5 }, 2)
local madeCopper = 0
craftrunner.run(dq, { policy = pManualCraft, mode = "manual", now = 1,
  isCrafting = function() return false end,
  craft = function() madeCopper = madeCopper + 1; return true end })
t.eq(madeCopper, 1, "same crafted item across two keys fires only one bridge request per run")
local craftingCount = 0
for _, e in pairs(dq.entries) do if e.state == cqueue.CRAFTING then craftingCount = craftingCount + 1 end end
t.eq(craftingCount, 2, "both same-item entries move to CRAFTING (one fired, one adopted)")

-- ---------------------------------------------------------------------------
print("CRAFT-5 fireOrder: reserved compress floor + round-robin refill categories")
do -- scope these locals: tests/run.lua's main chunk is near Lua's 200-local cap
local fo = craftrunner.fireOrder
local function names(order)
  local out = {}
  for _, e in ipairs(order) do out[#out + 1] = e.name end
  return table.concat(out, ",")
end

-- single lane (no category) degrades to pure priority order (constraints 3 & 5)
t.eq(names(fo({ { name = "low", priority = 0.1 }, { name = "urgent", priority = 0.9 }, { name = "mid", priority = 0.5 } }, { total = 2 })),
  "urgent,mid,low", "fireOrder: single lane => pure priority order")

-- overflow absent => refills first, surplus compress LAST (default is a pure reorder)
t.eq(names(fo({ { name = "cmp", kind = "compress", priority = 0.99 }, { name = "r1", priority = 0.5 }, { name = "r2", priority = 0.4 } }, { total = 2 })),
  "r1,r2,cmp", "fireOrder: overflow absent => refills first, surplus compress last")

-- ANTI-STARVATION: surplus compress must NOT steal refill slots (the key regression)
local af = fo({
  { name = "cmpA", kind = "compress", category = "Overflow", priority = 0.9 },
  { name = "cmpB", kind = "compress", category = "Overflow", priority = 0.8 },
  { name = "cmpC", kind = "compress", category = "Overflow", priority = 0.7 },
  { name = "R1", category = "Tapped", priority = 0.95 },
  { name = "R2", category = "Tapped", priority = 0.6 },
  { name = "R3", category = "Tapped", priority = 0.5 },
}, { total = 4, overflow = 1 })
t.eq(names(af), "cmpA,R1,R2,R3,cmpB,cmpC",
  "fireOrder: order = reserved compress, refills RR, surplus compress last (refills not starved)")

-- cross-category round-robin (preset path), reserved compress first
t.eq(names(fo({
  { name = "a1", category = "Alloys", priority = 0.9 }, { name = "a2", category = "Alloys", priority = 0.4 },
  { name = "e1", category = "Essence", priority = 0.8 }, { name = "e2", category = "Essence", priority = 0.35 },
  { name = "cmp1", kind = "compress", category = "Overflow", priority = 0.5 },
}, { total = 5, overflow = 1 })), "cmp1,a1,e1,a2,e2", "fireOrder: round-robin across categories, reserved compress first")

-- lane normalization: nil category collapses into one lane, never split from a rival lane
t.eq(names(fo({ { name = "x1", priority = 0.95 }, { name = "x2", priority = 0.8 }, { name = "t1", category = "Tapped", priority = 0.85 } }, { total = 2 })),
  "x1,t1,x2", "fireOrder: nil-category collapses to one lane (not split from Tapped)")

-- clamp safety: overflow > total clamps the reserve to total
t.eq(names(fo({ { name = "c1", kind = "compress", priority = 0.9 }, { name = "c2", kind = "compress", priority = 0.8 },
  { name = "c3", kind = "compress", priority = 0.7 }, { name = "r1", priority = 0.95 }, { name = "r2", priority = 0.6 } }, { total = 2, overflow = 5 })),
  "c1,c2,r1,r2,c3", "fireOrder: overflow>total clamps reserve to total")

-- clamp safety: negative -> 0, non-integer floors
t.eq(fo({ { name = "c", kind = "compress", priority = 0.9 }, { name = "r", priority = 0.1 } }, { total = 2, overflow = -1 })[1].name,
  "r", "fireOrder: overflow -1 => reserve 0 (refills lead)")
t.eq(fo({ { name = "c", kind = "compress", priority = 0.9 }, { name = "r", priority = 0.1 } }, { total = 2, overflow = 1.5 })[1].name,
  "c", "fireOrder: overflow 1.5 floors to reserve 1 (compress leads)")

-- unlimited total keeps every entry (matches the math.huge planning path)
t.eq(#fo({ { name = "c1", kind = "compress", priority = 0.9 }, { name = "c2", kind = "compress", priority = 0.5 },
  { name = "c3", kind = "compress", priority = 0.3 }, { name = "r1", priority = 0.8 }, { name = "r2", priority = 0.4 } }, { overflow = 2 }),
  5, "fireOrder: unlimited total keeps every entry")

-- determinism: identical output regardless of input array order; stable tiebreak by label/name
local detA = { { name = "aaa", category = "L1", priority = 0.5, approvedAt = 1 }, { name = "bbb", category = "L2", priority = 0.5, approvedAt = 1 } }
local detB = { { name = "bbb", category = "L2", priority = 0.5, approvedAt = 1 }, { name = "aaa", category = "L1", priority = 0.5, approvedAt = 1 } }
t.eq(names(fo(detA, { total = 2 })), names(fo(detB, { total = 2 })), "fireOrder: deterministic regardless of input order")
t.eq(names(fo(detA, { total = 2 })), "aaa,bbb", "fireOrder: equal-key lanes tiebreak by category label asc")

-- two compress rows into the SAME into-item (balance.lua emits them keyed, priority unset) must
-- order deterministically by `key`, not by table.sort's unstable handling of equivalent entries
local sameA = { { name = "iron_ingot", key = "compress:b", kind = "compress" }, { name = "iron_ingot", key = "compress:a", kind = "compress" } }
local sameB = { { name = "iron_ingot", key = "compress:a", kind = "compress" }, { name = "iron_ingot", key = "compress:b", kind = "compress" } }
t.eq(fo(sameA, { total = 1 })[1].key, fo(sameB, { total = 1 })[1].key, "fireOrder: same-name compress rows pick the same leader regardless of input order")
t.eq(fo(sameA, { total = 1 })[1].key, "compress:a", "fireOrder: same-name compress rows tiebreak by key asc")

-- regression: `kind` must survive the approve -> queue path so a single-tapped compress row stays
-- compress and the reserve floor protects it (the manager's approve() once dropped kind)
local kq = cqueue.approve(cqueue.new(), { name = "minecraft:iron_ingot", key = "compress:iron_dust", kind = "compress", request = 9, priority = 0.2 }, 1)
t.eq(kq.entries["compress:iron_dust"].kind, "compress", "approve preserves kind (compress survives to the queue)")
t.eq(fo({ kq.entries["compress:iron_dust"], { name = "minecraft:gold_ingot", priority = 0.9 } }, { total = 1, overflow = 1 })[1].kind,
  "compress", "fireOrder reserves the compress entry ahead of a higher-priority refill when overflow >= 1")

print("CRAFT-5 runner.run: budgets enforced at fire time without wasting capacity")
local function runFired(entries, opts)
  local q = cqueue.new()
  for _, e in ipairs(entries) do
    if e.request == nil then e.request = 1 end
    q = cqueue.approve(q, e, e.approvedAt or 1)
  end
  local f = {}
  local crafting = opts.crafting or {}
  craftrunner.run(q, { policy = pManualCraft, mode = "manual", now = 1000,
    maxPerCycle = opts.maxPerCycle, overflowReserve = opts.overflowReserve,
    isCrafting = function(name) return crafting[name] == true end,
    craft = function(name) f[#f + 1] = name; return true end })
  return f, q
end

local function runFiredAmounts(entries, opts)
  opts = opts or {}
  local q = cqueue.new()
  for _, e in ipairs(entries) do q = cqueue.approve(q, e, e.approvedAt or 1) end
  local f = {}
  local summary = craftrunner.run(q, { policy = pManualCraft, mode = "manual", now = 1000,
    maxPerCycle = opts.maxPerCycle, maxBridgeRequest = opts.maxBridgeRequest,
    overflowReserve = opts.overflowReserve,
    isCrafting = function(name) return (opts.crafting or {})[name] == true end,
    craft = function(name, amount) f[#f + 1] = { name = name, amount = amount }; return true end })
  return f, summary, q
end

_G.__batchFired, _G.__batchSummary, _G.__batchQ = runFiredAmounts({
  { name = "big", request = 1024, priority = 1 },
}, { maxPerCycle = 8, maxBridgeRequest = 64 })
t.eq(_G.__batchFired[1].amount, 64, "runner: maxBridgeRequest caps one bridge craftItem call")
t.eq(_G.__batchSummary.requested[1].amount, 64, "runner: requested summary records the capped bridge amount")
t.eq(_G.__batchQ.entries.big.state, cqueue.CRAFTING, "runner: capped stock request still transitions to CRAFTING")
t.eq(_G.__batchQ.entries.big.inflightRequest, 64, "runner: capped stock request records its in-flight batch")
_G.__batchFired, _G.__batchSummary, _G.__batchQ = nil, nil, nil

-- no idle waste: all-refill uses the whole cap, reserve never blocks a refillable slot
t.eq(#runFired({ { name = "r1", priority = 0.9 }, { name = "r2", priority = 0.8 }, { name = "r3", priority = 0.7 }, { name = "r4", priority = 0.6 } },
  { maxPerCycle = 8, overflowReserve = 2 }), 4, "runner: all-refill uses the cap; reserve never blocks a refillable slot")

-- no idle waste: all-compress borrows the idle refill reserve
t.eq(#runFired({ { name = "c1", kind = "compress", priority = 0.9 }, { name = "c2", kind = "compress", priority = 0.8 }, { name = "c3", kind = "compress", priority = 0.7 } },
  { maxPerCycle = 8, overflowReserve = 1 }), 3, "runner: all-compress borrows idle refill capacity to use the whole cap")

-- compress floor honored under a refill flood (low-priority reserved compress still leads)
local f5 = runFired({ { name = "cmp", kind = "compress", priority = 0.01 }, { name = "r1", priority = 0.9 },
  { name = "r2", priority = 0.8 }, { name = "r3", priority = 0.7 }, { name = "r4", priority = 0.6 }, { name = "r5", priority = 0.5 } },
  { maxPerCycle = 3, overflowReserve = 1 })
t.eq(#f5, 3, "runner: fires exactly maxPerCycle under a flood")
t.check(f5[1] == "cmp", "runner: low-priority reserved compress still leads under a refill flood")

-- reserved compress already-crafting frees its slot for refills (no waste, no mis-accounting)
local f9, q9 = runFired({ { name = "c1", kind = "compress", priority = 0.9 }, { name = "c2", kind = "compress", priority = 0.8 },
  { name = "r1", priority = 0.7 }, { name = "r2", priority = 0.6 }, { name = "r3", priority = 0.5 } },
  { maxPerCycle = 2, overflowReserve = 1, crafting = { c1 = true } })
t.eq(table.concat(f9, ","), "r1,r2", "runner: a reserved compress that RS already crafts frees its slot for refills")
t.eq(q9.entries.c1.state, cqueue.CRAFTING, "runner: c1 adopted CRAFTING with no bridge call")
t.eq(q9.entries.r3.state, cqueue.APPROVED, "runner: r3 stays APPROVED for next cycle")

-- many categories, total < #categories: round-robin picks highest-priority heads first
local f11, q11 = runFired({ { name = "a1", category = "Alpha", priority = 0.5 }, { name = "b1", category = "Beta", priority = 0.9 }, { name = "g1", category = "Gamma", priority = 0.7 } },
  { maxPerCycle = 2 })
t.eq(table.concat(f11, ","), "b1,g1", "runner: round-robin fires highest-priority lane heads first under a tight cap")
t.eq(q11.entries.a1.state, cqueue.APPROVED, "runner: lowest-priority category waits a cycle (priority rotates as deficit grows)")
end

-- ---------------------------------------------------------------------------
print("manual jobs (runner): lead lane, reserved floor, cooldown bypass, reserve, completion")
do
local fo = craftrunner.fireOrder
local function names(order)
  local out = {}
  for _, e in ipairs(order) do out[#out + 1] = e.name end
  return table.concat(out, ",")
end

-- fireOrder LEADS with a manual entry even at lower priority than a refill. BITE:
-- remove the manual lane (manual falls into refills) and order[1] becomes the refill.
local mjob = { name = "M", kind = cqueue.MANUAL, priority = 0, requested = 5, made = 0 }
t.eq(fo({ { name = "R", priority = 9 }, mjob }, { total = 5, manual = 1 })[1].name, "M",
  "fireOrder: manual leads despite lower priority than a refill")

-- reserved manual floor: under a cap of 1 with a 3-refill flood, the reserved manual
-- slot still leads. BITE: drop the reserved-manual block / reserveM=0 and a refill leads.
local floodOrder = fo({
  { name = "r1", priority = 0.9 }, { name = "r2", priority = 0.8 }, { name = "r3", priority = 0.7 },
  { name = "MJ", kind = cqueue.MANUAL, priority = 0.01, requested = 1, made = 0 },
}, { total = 1, manual = 1 })
t.eq(floodOrder[1].name, "MJ", "fireOrder: reserved-manual floor beats a refill flood under cap=1")

-- with manual=0 the job still LEADS refills (only the guaranteed floor differs)
t.eq(fo({ { name = "rr", priority = 0.9 }, { name = "mm", kind = cqueue.MANUAL, priority = 0.1, requested = 2 } },
  { total = 5, manual = 0 })[1].name, "mm", "fireOrder: manual leads refills even with manual budget 0")

-- helper: run runner.run over a queue built from entries (manual jobs preserved)
local function runJobs(entries, opts)
  opts = opts or {}
  local q = cqueue.new()
  for _, e in ipairs(entries) do
    if e.kind == cqueue.MANUAL then
      local _, jk = cqueue.enqueueJob(q, e, e.approvedAt or 1)
      -- triedAt isn't a job field enqueueJob carries; set it directly so a cooldown
      -- bypass test can model a job that "failed last cycle" and must retry now.
      if e.triedAt and jk then q.entries[jk].triedAt = e.triedAt end
    else
      cqueue.approve(q, e, e.approvedAt or 1)
      if e.triedAt then q.entries[e.key or e.name].triedAt = e.triedAt end
    end
  end
  local fired = {}
  local summary = craftrunner.run(q, {
    policy = pManualCraft, mode = "manual", now = opts.now or 1000,
    cooldownMs = opts.cooldownMs or 0,
    maxPerCycle = opts.maxPerCycle, manualReserve = opts.manualReserve,
    isCrafting = function(n) return (opts.crafting or {})[n] == true end,
    resolve = opts.resolve,
    craft = function(n, amt) fired[#fired + 1] = { name = n, amount = amt }; return true end,
  })
  return fired, summary, q
end

-- COOLDOWN BYPASS: a manual entry with a fresh triedAt STILL fires while an identical
-- quota entry (same fresh triedAt) is skipped. BITE: remove the `not manualJob` guard
-- and the manual entry is skipped -> no manual in summary.requested.
local cbFired, cbSummary = runJobs({
  { name = "qc", request = 7, priority = 0.9, triedAt = 1000, approvedAt = 1 }, -- quota, on cooldown
  { name = "mj", kind = cqueue.MANUAL, requested = 3, triedAt = 1000, approvedAt = 1 },
}, { now = 1000, cooldownMs = 300000, manualReserve = 1, maxPerCycle = 8 })
local cbNames = {}
for _, f in ipairs(cbFired) do cbNames[f.name] = f.amount end
-- the manual entry's triedAt is set by enqueueJob? no -- enqueueJob doesn't set triedAt;
-- inject it directly to model a job that failed last cycle but must retry now.
t.check(cbNames["mj"] ~= nil, "runner: manual job fires despite a fresh cooldown (bypass)")
local cbQuotaFired = false
for _, r in ipairs(cbSummary.requested) do if r.name == "qc" then cbQuotaFired = true end end
t.check(cbQuotaFired == false, "runner: an identical quota entry on cooldown is skipped")

-- craftFrom RESERVE respected (default): request=100, reserve leaves 40 -> fires 40,
-- made=40, NOT complete. BITE: drop the runner-side clamp and it fires 100.
local crFired, crSummary, crQ = runJobs({
  { name = "alloy", kind = cqueue.MANUAL, requested = 100, craftFrom = { name = "dust", reserve = 10, ratio = 1 } },
}, { resolve = function(nm) return nm == "dust" and 50 or 0 end, manualReserve = 1, maxPerCycle = 8 })
t.eq(crFired[1].amount, 40, "runner: manual fire clamped to craftFrom reserve (50-10=40)")
t.eq(crQ.entries["manual:alloy"].made, 40, "runner: made tracks the clamped fire amount")
t.check(cqueue.jobComplete(crQ, "manual:alloy") == false, "runner: partially-fired job is not complete")
t.eq(#crSummary.completed, 0, "runner: a clamped partial fire does not complete")

-- force=true bypasses the clamp entirely -> fires the full 100
local fFired = runJobs({
  { name = "alloy", kind = cqueue.MANUAL, requested = 100, force = true, craftFrom = { name = "dust", reserve = 10, ratio = 1 } },
}, { resolve = function() return 50 end, manualReserve = 1, maxPerCycle = 8 })
t.eq(fFired[1].amount, 100, "runner: force=true bypasses the craftFrom reserve clamp")

-- input below the reserve -> SOFT skip into summary.held, entry stays APPROVED, nothing
-- fired. BITE: drop the soft-skip/reserve gate and it would fire.
local hFired, hSummary, hQ = runJobs({
  { name = "alloy", kind = cqueue.MANUAL, requested = 100, craftFrom = { name = "dust", reserve = 10, ratio = 1 } },
}, { resolve = function() return 5 end, manualReserve = 1, maxPerCycle = 8 })
t.eq(#hFired, 0, "runner: a below-reserve job fires nothing")
t.eq(#hSummary.requested, 0, "runner: a held job is not in summary.requested")
t.eq(#hSummary.held, 1, "runner: a held job is surfaced in summary.held")
t.check(hSummary.held[1].reason:find("reserve", 1, true) ~= nil, "runner: held reason names the reserve")
t.eq(hQ.entries["manual:alloy"].state, cqueue.APPROVED, "runner: a held job stays APPROVED")

-- COMPLETION: full N in one run -> summary.completed populated + jobComplete true. BITE:
-- jobComplete using > leaves completed empty.
local doneFired, doneSummary, doneQ = runJobs({
  { name = "widget", kind = cqueue.MANUAL, requested = 10 },
}, { resolve = function() return 1e9 end, manualReserve = 1, maxPerCycle = 8 })
t.eq(doneFired[1].amount, 10, "runner: an unconstrained job fires its full N in one shot")
t.eq(#doneSummary.completed, 1, "runner: a fully-fired job is in summary.completed")
t.eq(doneSummary.completed[1].name, "widget", "runner: completed carries the item name")
t.check(cqueue.jobComplete(doneQ, "manual:widget") == true, "runner: jobComplete true after a full fire")
end

-- ---------------------------------------------------------------------------
print("managed quotas (tap-to-manage store)")
local ms = managed.new()
t.eq(managed.count(ms), 0, "new store is empty")

managed.set(ms, { name = "mek:steel", label = "Steel", target = 256, craftTo = 512 }, 100)
t.eq(managed.count(ms), 1, "set adds a quota")
t.eq(managed.get(ms, "mek:steel").target, 256, "quota stores target")
t.eq(managed.get(ms, "mek:steel").craftTo, 512, "quota stores craftTo")

managed.set(ms, { name = "mek:steel", label = "Steel", target = 300, craftTo = 600 }, 200)
t.eq(managed.count(ms), 1, "re-setting the same item dedupes")
t.eq(managed.get(ms, "mek:steel").target, 300, "re-set updates target")

-- clamps: craftTo never below target (or below 1); negatives floored to 0
managed.set(ms, { name = "x", label = "X", target = 50, craftTo = 10 }, 1)
t.eq(managed.get(ms, "x").craftTo, 50, "craftTo clamped up to target")
managed.set(ms, { name = "y", target = -5, craftTo = -5 }, 1)
t.eq(managed.get(ms, "y").target, 0, "negative target floored to 0")
t.check(managed.get(ms, "y").craftTo >= 1, "craftTo floored to at least 1")

managed.set(ms, { label = "no name" }, 1) -- missing name -> no-op
t.eq(managed.count(ms), 3, "set without a name is a no-op")

managed.remove(ms, "x")
t.check(managed.has(ms, "x") == false, "remove drops the quota")

-- CRAFT-3: countNotInGrid -- hoisted PLAN counter. ms now holds mek:steel + y.
local nigStore = managed.new()
managed.set(nigStore, { name = "mek:steel", target = 1, craftTo = 1 }, 1)
managed.set(nigStore, { name = "ghost:item", target = 1, craftTo = 1 }, 1)
managed.set(nigStore, { name = "also:missing", target = 1, craftTo = 1 }, 1)
t.eq(managed.countNotInGrid(nigStore, { ["mek:steel"] = {} }), 2,
  "countNotInGrid counts quotas absent from the live grid")
t.eq(managed.countNotInGrid(nigStore, { ["mek:steel"] = {}, ["ghost:item"] = {}, ["also:missing"] = {} }), 0,
  "countNotInGrid is 0 when every quota is in the grid")
t.eq(managed.countNotInGrid(nigStore, nil), 3, "nil grid -> every quota counts as missing")
t.eq(managed.countNotInGrid(managed.new(), { ["x"] = {} }), 0, "empty store -> 0 missing")
t.eq(#managed.missingFromGrid({
  { name = "mek:steel", label = "Steel", category = "Base" },
  { name = "ghost:item", label = "Ghost", category = "Base" },
  { name = "ghost:item", label = "Ghost duplicate", category = "Tapped" },
}, { ["mek:steel"] = true }), 1, "missingFromGrid dedups quota-like rows absent from live grid")
t.eq(managed.missingFromGrid({
  { name = "mek:steel", label = "Steel", category = "Base" },
  { name = "ghost:item", label = "Ghost", category = "Base" },
}, { ["mek:steel"] = true })[1].name, "ghost:item", "missingFromGrid returns the absent registry ID")

-- toCategory feeds the planner; empty store -> nil
t.eq(managed.toCategory(managed.new()), nil, "empty store -> no category")
local cat = managed.toCategory(ms)
t.eq(cat.label, "Tapped", "managed category is labelled Tapped")
t.check(#cat.items >= 1, "managed category carries its items")
-- the merged category plans like any other stock-keeper category
local merged = stockplan.plan({ stockKeeper = { enabled = true, categories = { cat } },
  ledger = { requests = {} }, resolve = function() return 0, true, false end })
t.check(#merged >= 1, "managed quotas produce plan rows")
t.eq(merged[1].action, "WOULD CRAFT", "a below-target managed quota plans a craft")

-- managed store preserves watch-only route metadata for presets/tapped entries.
do
  local wm = managed.new()
  managed.set(wm, { name = "mi:plate", label = "MI Plate", target = 10, craftTo = 20,
    craftMode = "watch", blockReason = "MI assembler route; do not RS autocraft" }, 123)
  local wcat = managed.toCategory(wm)
  t.eq(wcat.items[1].craftMode, "watch", "managed.toCategory preserves craftMode")
  t.eq(wcat.items[1].blockReason, "MI assembler route; do not RS autocraft", "managed.toCategory preserves blockReason")
  local wplan = stockplan.plan({ stockKeeper = { enabled = true, categories = { wcat } },
    ledger = { requests = {} }, resolve = function() return 0, true, false end })
  t.eq(wplan[1].action, "BLOCKED", "managed watch-only quota blocks instead of crafting")
  t.eq(wplan[1].reason, "MI assembler route; do not RS autocraft", "managed watch-only row carries reason")
end

-- patternsNeeded (CRAFT-4): non-craftable quotas, grouped/sorted into a worklist
do
  local pItems = {
    { name = "mekanism:alloy_infused", label = "Infused Alloy", category = "Mekanism" },
    { name = "minecraft:glass", label = "Glass", category = "Base" },
    { name = "alltheores:steel_ingot", label = "Steel", category = "Base" },
  }
  local craftable = { ["minecraft:glass"] = true } -- only glass has a pattern
  local need = managed.patternsNeeded(pItems, function(n) return craftable[n] == true end)
  t.eq(#need, 2, "patternsNeeded lists only the non-craftable quotas")
  t.eq(need[1].category, "Base", "sorted by category first (Base before Mekanism)")
  t.eq(need[1].label, "Steel", "Base/Steel listed (glass is craftable, excluded)")
  t.eq(need[2].name, "mekanism:alloy_infused", "Mekanism item sorts last")
  pItems[#pItems + 1] = {
    name = "modern_industrialization:motor",
    label = "Motor",
    category = "Modern Industrialization",
    craftMode = "watch",
    blockReason = "MI assembler route; do not RS autocraft",
  }
  need = managed.patternsNeeded(pItems, function(n) return craftable[n] == true end)
  t.eq(#need, 2, "patternsNeeded excludes watch-only/manual-route quotas")
  t.check(managed.isWatchOnly(pItems[#pItems]) == true, "isWatchOnly detects craftMode watch")
  t.eq(#managed.patternsNeeded(pItems, function() return true end), 0, "all craftable -> empty worklist")
  t.eq(#managed.patternsNeeded(nil, nil), 0, "nil-safe")
  -- dedup: same item from config + tapped appears once, keeping the FIRST (config) entry
  local dup = {
    { name = "alltheores:steel_ingot", label = "Steel", category = "Base" },   -- config: first
    { name = "alltheores:steel_ingot", label = "Steel Ingot", category = "Tapped" }, -- tapped: dropped
  }
  local dn = managed.patternsNeeded(dup, function() return false end)
  t.eq(#dn, 1, "patternsNeeded dedups the same item across categories")
  t.eq(dn[1].category, "Base", "dedup keeps the first (config) occurrence, not Tapped")
end

-- overflow config merges with (does not wipe) the floor quota
local os2 = managed.new()
managed.set(os2, { name = "iron", label = "Iron", target = 100, craftTo = 200,
  ceiling = 1000, into = { name = "iron_block", label = "Iron Block" }, ratio = 9 }, 1)
local ie = managed.get(os2, "iron")
t.eq(ie.ceiling, 1000, "overflow ceiling stored")
t.eq(ie.into.name, "iron_block", "overflow into-item stored")
t.eq(ie.ratio, 9, "overflow ratio stored")
managed.set(os2, { name = "iron", label = "Iron", target = 150, craftTo = 250 }, 2) -- floor edit only
t.eq(managed.get(os2, "iron").target, 150, "floor edit updates target")
t.eq(managed.get(os2, "iron").ceiling, 1000, "floor edit preserves the overflow config")
t.eq(#managed.overflowItems(os2), 1, "overflowItems lists configured items")
managed.set(os2, { name = "guard", label = "Guard", target = 100, craftTo = 200,
  ceiling = 150, into = { name = "guard_block" }, ratio = 9 }, 3)
t.eq(managed.get(os2, "guard").craftTo, 149, "managed set lowers craftTo below a compress ceiling")
t.check(managed.get(os2, "guard").adjusted ~= nil, "managed set records the ceiling adjustment")
managed.set(os2, { name = "bad", label = "Bad", target = 100, craftTo = 100,
  ceiling = 100, into = { name = "bad_block" }, ratio = 9 }, 4)
t.eq(managed.get(os2, "bad").invalid, "ceiling must be greater than target",
  "managed set marks an impossible ceiling/floor band invalid")
local guardCat = managed.toCategory(os2)
local sawGuardCeiling = false
for _, e in ipairs(guardCat.items) do
  if e.name == "guard" and e.ceiling == 150 and e.into and e.into.name == "guard_block" then
    sawGuardCeiling = true
  end
end
t.check(sawGuardCeiling, "managed category carries overflow metadata to the stock planner")
managed.clearOverflow(os2, "iron")
t.eq(managed.get(os2, "iron").ceiling, nil, "clearOverflow drops the ceiling")
t.eq(#managed.overflowItems(os2), 1, "clearOverflow removes only the selected valid overflow item")

-- profile settings (smart-mode flag) persist on the store
local ss = managed.new()
t.eq(managed.getSetting(ss, "smartMode"), nil, "no settings by default")
managed.setSetting(ss, "smartMode", true)
t.eq(managed.getSetting(ss, "smartMode"), true, "setSetting/getSetting round-trips")
t.check(managed.normalize(ss).settings ~= nil, "normalize preserves settings")

-- ---------------------------------------------------------------------------
print("smart-mode suggestions (consumption trends)")
-- record builds per-item trend stats across snapshots
local hist = {}
suggest.record(hist, { { name = "steel", label = "Steel", amount = 1000 } }, 0)
suggest.record(hist, { { name = "steel", label = "Steel", amount = 200 } }, 120000)
t.eq(hist.steel.a0, 1000, "record keeps the first amount")
t.eq(hist.steel.aN, 200, "record tracks the latest amount")
t.eq(hist.steel.minA, 200, "record tracks the minimum seen")

-- a declining unmanaged item -> a quota suggestion
local sg = suggest.analyze(hist, { managed = {}, minDrain = 64, minWindowMs = 60000 })
t.eq(#sg, 1, "declining unmanaged item -> one suggestion")
t.eq(sg[1].name, "steel", "suggestion names the draining item")
t.check(sg[1].target >= 0 and sg[1].craftTo > sg[1].target, "suggestion proposes a sane quota")

do
  -- S8: if the caller knows an unmanaged drainer has no RS pattern, suggest setup work instead of a quota
  local np = suggest.analyze(hist, { managed = {}, patternless = { steel = true }, minDrain = 64, minWindowMs = 60000 })
  t.eq(#np, 1, "S8: patternless unmanaged drainer -> one advisory")
  t.eq(np[1].kind, "needpattern", "S8: patternless drainer is tagged NEEDS PATTERN")
  t.eq(np[1].seeded, false, "S8: needpattern does not seed the quota editor")
  t.eq(np[1].target, nil, "S8: needpattern has no quota target")
  t.eq(np[1].craftTo, nil, "S8: needpattern has no craftTo")
  t.eq(suggest.analyze(hist, { managed = {}, patternless = { copper = true }, minDrain = 64, minWindowMs = 60000 })[1].kind,
    "quota", "S8: unrelated patternless entries do not change quota suggestions")
  t.eq(#suggest.analyze(hist, { managed = { steel = true }, patternless = { steel = true },
    minDrain = 64, minWindowMs = 60000 }), 0, "S8: managed patternless items stay suppressed")
end

-- managed or dismissed items are not suggested
t.eq(#suggest.analyze(hist, { managed = { steel = true } }), 0, "managed item not suggested")
t.eq(#suggest.analyze(hist, { dismissed = { steel = true } }), 0, "dismissed item not suggested")

-- stable items and too-short windows produce nothing
local stable = {}
suggest.record(stable, { { name = "x", amount = 500 } }, 0)
suggest.record(stable, { { name = "x", amount = 500 } }, 120000)
t.eq(#suggest.analyze(stable, {}), 0, "stable item -> no suggestion")
local quick = { y = { label = "Y", t0 = 0, a0 = 1000, tN = 1000, aN = 0, minA = 0 } }
t.eq(#suggest.analyze(quick, {}), 0, "decline inside too-short window -> none")

-- CAP: an unmanaged item that keeps ACCUMULATING -> suggest a compress ceiling
local grow = { cobble = { label = "Cobble", t0 = 0, a0 = 1000, tN = 120000, aN = 5000, minA = 1000 } }
local gs = suggest.analyze(grow, { managed = {} })
t.eq(#gs, 1, "accumulating item -> one suggestion")
t.eq(gs[1].kind, "cap", "growth suggestion is a cap/ceiling")
t.check(gs[1].ceiling and gs[1].ceiling > 0, "cap suggestion seeds a ceiling")

-- RAISE: a managed item stuck below target while still draining -> raise craftTo
local low = { steel = { label = "Steel", t0 = 0, a0 = 200, tN = 120000, aN = 100, minA = 100 } }
local rs2 = suggest.analyze(low, { quotas = { steel = { target = 256, craftTo = 300 } } })
t.eq(#rs2, 1, "managed item below target + draining -> one suggestion")
t.eq(rs2[1].kind, "raise", "it is a raise suggestion")
t.check(rs2[1].craftTo > 300, "raise proposes a higher craftTo")
-- a managed item comfortably above target gets no raise
local ok2 = { steel = { label = "Steel", t0 = 0, a0 = 900, tN = 120000, aN = 800, minA = 800 } }
t.eq(#suggest.analyze(ok2, { quotas = { steel = { target = 256, craftTo = 300 } } }), 0,
  "managed item above target -> no raise suggestion")

-- prune: bound the persisted history (drop stale, restart long windows, cap size)
local ph = {
  fresh = { label = "Fresh", t0 = 0, a0 = 100, tN = 1000000, aN = 50, minA = 50, n = 5 },
  stale = { label = "Stale", t0 = 0, a0 = 100, tN = 1000, aN = 50, minA = 50, n = 5 },
}
local _, pruned = suggest.prune(ph, 1000000, { maxAgeMs = 100000 })
t.eq(pruned, 1, "prune drops an entry not seen within maxAgeMs")
t.check(ph.fresh ~= nil and ph.stale == nil, "prune keeps the freshly-seen entry, drops the stale one")

-- maxWindowMs restarts an over-long window in place (keeps the entry, resets t0/a0)
local pw = { long = { label = "Long", t0 = 0, a0 = 100, tN = 500000, aN = 30, minA = 20, n = 50 } }
suggest.prune(pw, 500000, { maxWindowMs = 100000 })
t.eq(pw.long.t0, 500000, "prune restarts an over-long window at the latest sample")
t.eq(pw.long.a0, 30, "restarted window adopts the latest amount as the new baseline")
t.eq(pw.long.n, 1, "restarted window resets the sample count")

-- maxEntries caps the table, dropping the least-recently-seen (tN tiebreak when n equal)
local pc = {
  a = { tN = 10 }, b = { tN = 30 }, c = { tN = 20 },
}
local _, capRemoved = suggest.prune(pc, 100, { maxEntries = 2 })
t.eq(capRemoved, 1, "prune drops down to maxEntries")
t.check(pc.a == nil and pc.b ~= nil and pc.c ~= nil, "prune keeps the most-recently-seen entries")

-- maxEntries prefers the most-SAMPLED entries (n) over mere recency, so a busy item
-- isn't evicted by a just-seen static one (bounds the CC-disk file by real signal)
local pn = {
  busy = { tN = 5, n = 100 },   -- old but heavily sampled -> keep
  blip = { tN = 99, n = 1 },    -- just seen once -> drop
  mid  = { tN = 50, n = 40 },   -- keep
}
suggest.prune(pn, 100, { maxEntries = 2 })
t.check(pn.busy ~= nil and pn.mid ~= nil and pn.blip == nil, "prune keeps high-sample entries, evicts a one-off blip")

-- prune-on-LOAD shape: loadTrends bounds the table on load via
-- `(suggest.prune(data, now, {maxEntries=TREND_MAX_ENTRIES, ...}))`, so a trend
-- file already over the 800-entry cap is bounded at boot, not only on the first
-- throttled save. Pin that the parenthesized single-return bounds 1000 -> 800.
local pl = {}
for i = 1, 1000 do pl["t" .. i] = { tN = i, n = i } end -- t1000 most-sampled
local plLoaded = (suggest.prune(pl, 2000, { maxEntries = 800 }))
local plN = 0; for _ in pairs(plLoaded) do plN = plN + 1 end
t.eq(plN, 800, "prune-on-load bounds an oversized trend table (1000 -> 800)")
t.check(plLoaded.t1000 ~= nil and plLoaded.t1 == nil, "prune-on-load keeps high-sample entries, drops thin ones")

-- pruneDismissed: bound the operator's dismissed set (cap drops oldest, TTL ages out)
-- STAB-4 acceptance: inserting cap+50 dismissals leaves the saved set <= cap.
local big = {}
for i = 1, 450 do big["item" .. i] = i end -- ts == i, so item1 is oldest, item450 newest
local capped, capRem = suggest.pruneDismissed(big, 1000, { maxEntries = 400, maxAgeMs = 0 })
local cappedN = 0; for _ in pairs(capped) do cappedN = cappedN + 1 end
t.eq(cappedN, 400, "pruneDismissed caps the set at maxEntries (450 -> 400)")
t.eq(capRem, 50, "pruneDismissed reports the 50 dropped")
t.check(capped["item1"] == nil and capped["item450"] ~= nil, "pruneDismissed drops the OLDEST, keeps the newest")

-- TTL: an entry older than maxAgeMs is aged out (re-surfaces as a suggestion again)
local aged = suggest.pruneDismissed({ old = 100, fresh = 9000 }, 10000, { maxAgeMs = 5000 })
t.check(aged.old == nil and aged.fresh ~= nil, "pruneDismissed ages out entries past maxAgeMs")

-- legacy boolean `true` values are normalized to a timestamp (now), not dropped
local legacy = suggest.pruneDismissed({ a = true }, 777, { maxAgeMs = 5000, maxEntries = 400 })
t.eq(legacy.a, 777, "pruneDismissed upgrades a legacy boolean dismissal to a timestamp")

-- ---------------------------------------------------------------------------
print("CRAFT-6 smart suggestions: cooldown buffer + compress chains + re-surface")
do -- scope these locals (200-local cap); inner block still reads outer hist/grow/sg
-- (A) craftTo buffers perMin * cooldownSeconds/60; default 300 reproduces the legacy *5
-- hist: steel 1000 -> 200 over 2m => decline 800, perMin 400, minA/target 200
t.eq(suggest.analyze(hist, { managed = {} })[1].craftTo, 2200,
  "CRAFT-6: default cooldown 300 reproduces the legacy *5 buffer (200 + 2000)")
t.eq(suggest.analyze(hist, { managed = {}, cooldownSeconds = 600 })[1].craftTo, 4200,
  "CRAFT-6: craftTo buffers perMin * cooldownSeconds/60 (600s doubles the buffer)")
t.check(suggest.analyze(hist, { managed = {} })[1].perMin and suggest.analyze(hist, { managed = {} })[1].perMin > 0,
  "CRAFT-6: a suggestion exposes perMin (so the manager can capture a baseline at dismissal)")

-- (B) compress chain is opt-in: off by default the climbing item stays a cap; on, it promotes
t.eq(suggest.analyze(grow, { managed = {} })[1].kind, "cap",
  "CRAFT-6: compressChains absent -> a growing item is still a cap (backward compatible)")
local cc = suggest.analyze(grow, { managed = {}, compressChains = true })
t.eq(cc[1].kind, "compress", "CRAFT-6: compressChains on -> a band-climbing item becomes compress")
t.eq(cc[1].target, 1000, "CRAFT-6: compress seeds the band floor (minA) as the keep-stock target")
t.check(cc[1].ceiling > cc[1].target, "CRAFT-6: compress ceiling is strictly above the target")
t.check(cc[1].target < cc[1].craftTo and cc[1].craftTo < cc[1].ceiling,
  "CRAFT-6: compress refill floor sits below the cap (target < craftTo < ceiling)")
t.eq(cc[1].ratio, 1, "CRAFT-6: compress seeds a generic ratio default")
t.check(cc[1].into == nil, "CRAFT-6: compress leaves `into` nil (operator picks it; no item heuristics)")
-- grew but did not climb past a stable band (aN - minA < minDrain) -> stays cap even when opted in
local osc = { z = { label = "Z", t0 = 0, a0 = 1000, tN = 120000, aN = 1100, minA = 1090 } }
t.eq(suggest.analyze(osc, { managed = {}, compressChains = true })[1].kind, "cap",
  "CRAFT-6: growth without a band climb stays cap even with compressChains on")

-- (C) re-surface a dismissed item only when drain materially accelerates past its baseline
t.eq(#suggest.analyze(hist, { dismissed = { steel = { ts = 0, baseline = 400 } } }), 0,
  "CRAFT-6: dismissed item with steady drain (perMin ~ baseline) stays suppressed")
local rsv = suggest.analyze(hist, { dismissed = { steel = { ts = 0, baseline = 100 } } })
t.eq(#rsv, 1, "CRAFT-6: dismissed item re-surfaces when perMin >= 2x baseline")
t.eq(rsv[1].name, "steel", "CRAFT-6: the re-surfaced suggestion names the accelerating item")
t.eq(#suggest.analyze(hist, { dismissed = { steel = { ts = 0, baseline = 100 } }, resurfaceFactor = 5 }), 0,
  "CRAFT-6: resurfaceFactor raises the acceleration bar (400 < 5x100)")
t.eq(#suggest.analyze(hist, { dismissed = { steel = 0 } }), 0,
  "CRAFT-6: a legacy numeric dismissal (no baseline) never re-surfaces")
t.eq(#suggest.analyze(hist, { dismissed = { steel = true } }), 0,
  "CRAFT-6: a legacy boolean dismissal never re-surfaces")

-- pruneDismissed preserves a rich {ts,baseline} value through aging, and still ages by ts
local rich = suggest.pruneDismissed({ a = { ts = 9000, baseline = 250 } }, 10000, { maxAgeMs = 5000 })
t.eq(type(rich.a), "table", "CRAFT-6: pruneDismissed preserves the rich {ts,baseline} shape")
t.eq(rich.a.baseline, 250, "CRAFT-6: pruneDismissed keeps the baseline through a prune")
t.check(suggest.pruneDismissed({ a = { ts = 100, baseline = 250 } }, 10000, { maxAgeMs = 5000 }).a == nil,
  "CRAFT-6: pruneDismissed still ages out a rich entry by its ts")
end

-- ---------------------------------------------------------------------------
print("CONF-1 confidence-weighted ranking (evidence quality, not raw decline)")
do
  -- Two unmanaged drainers with EQUAL net decline (800), but very different evidence:
  --  thin: seen twice 90s apart (n=2, span just over minWindow)
  --  solid: seen 50 times over a long span (n=50, span = 4*minWindow = idealWindow)
  -- Confidence weighting must rank the well-observed one ABOVE the thin one despite the
  -- identical decline, while neither is zeroed (thin still appears as a suggestion).
  local cw = {
    thin  = { label = "Thin",  t0 = 0, a0 = 1000, tN = 90000,  aN = 200, minA = 200, n = 2 },
    solid = { label = "Solid", t0 = 0, a0 = 1000, tN = 240000, aN = 200, minA = 200, n = 50 },
  }
  local r = suggest.analyze(cw, { managed = {}, minDrain = 64, minWindowMs = 60000 })
  t.eq(#r, 2, "CONF-1: both equal-decline drainers are suggested (thin is demoted, not erased)")
  t.eq(r[1].name, "solid", "CONF-1: the well-observed drainer outranks the thin one at equal decline")
  t.eq(r[2].name, "thin", "CONF-1: the thin-evidence drainer is still present, just ranked lower")
  t.check(r[1].conf and r[2].conf and r[1].conf > r[2].conf, "CONF-1: conf is exposed and higher for solid evidence")
  -- BITE: without confidence weighting the tiebreak is name order (solid < thin already),
  -- so prove the weighting is doing work by making the THIN item win on raw decline. Give
  -- thin a LARGER raw decline (900) that confidence weighting pulls below solid's 800.
  local cw2 = {
    thin  = { label = "Thin",  t0 = 0, a0 = 1000, tN = 90000,  aN = 100, minA = 100, n = 2 },  -- decline 900
    solid = { label = "Solid", t0 = 0, a0 = 1000, tN = 240000, aN = 200, minA = 200, n = 50 }, -- decline 800
  }
  local r2 = suggest.analyze(cw2, { managed = {}, minDrain = 64, minWindowMs = 60000 })
  t.eq(r2[1].name, "solid",
    "CONF-1 BITE: a thin item with LARGER raw decline still ranks below a solid one (weighting bites)")
  -- determinism: same input -> same order
  local r3 = suggest.analyze(cw2, { managed = {}, minDrain = 64, minWindowMs = 60000 })
  t.eq(r3[1].name, r2[1].name, "CONF-1: ranking is deterministic across runs")
end

-- ---------------------------------------------------------------------------
print("CONF-2 maxA tracking + spiky-vs-steady detection")
do
  -- record() now tracks the running maximum so analyze can see intra-window shape.
  local mh = {}
  suggest.record(mh, { { name = "k", label = "K", amount = 1000 } }, 0)
  suggest.record(mh, { { name = "k", label = "K", amount = 1200 } }, 60000)
  suggest.record(mh, { { name = "k", label = "K", amount = 200 } }, 120000)
  t.eq(mh.k.maxA, 1200, "CONF-2: record tracks the running maximum (maxA)")
  t.eq(mh.k.minA, 200, "CONF-2: record still tracks the minimum (minA)")
  -- pre-maxA persisted entry: maxA absent -> ceilings/spiky fall back to aN (backward compat)
  local legacyCap = { c = { label = "C", t0 = 0, a0 = 1000, tN = 120000, aN = 5000, minA = 1000 } }
  local lc = suggest.analyze(legacyCap, { managed = {} })
  t.eq(lc[1].kind, "cap", "CONF-2: a legacy entry (no maxA) still analyzes")
  t.eq(lc[1].ceiling, 5000, "CONF-2: legacy cap ceiling falls back to aN when maxA absent")

  -- CAP ceiling is seeded from the observed PEAK, not the (lower) last sample:
  -- climbs to 6000 then settles to 5000 -> ceiling must sit >= 6000, not 5000.
  local peak = { p = { label = "P", t0 = 0, a0 = 1000, tN = 120000, aN = 5000, minA = 1000, maxA = 6000 } }
  local pc = suggest.analyze(peak, { managed = {} })
  t.eq(pc[1].kind, "cap", "CONF-2: a net-growth item is a cap")
  t.check(pc[1].ceiling >= 6000, "CONF-2: cap ceiling is seeded from the peak (maxA), not the last sample")

  -- SPIKY: a self-replenishing item (refills then dips at the last sample) shows the same
  -- endpoint decline as a steady drainer, but a large swing relative to net move -> spiky,
  -- damped confidence. Steady monotone drainer of equal net decline is NOT spiky.
  local spikyH = { s = { label = "S", t0 = 0, a0 = 1000, tN = 120000, aN = 800, minA = 100, maxA = 1200, n = 30 } }
  local steadyH = { d = { label = "D", t0 = 0, a0 = 1000, tN = 120000, aN = 800, minA = 800, maxA = 1000, n = 30 } }
  t.eq(suggest.analyze(spikyH, { managed = {}, minDrain = 64 })[1].spiky, true,
    "CONF-2: a large-swing self-replenishing item is tagged spiky")
  t.eq(suggest.analyze(steadyH, { managed = {}, minDrain = 64 })[1].spiky, false,
    "CONF-2: a monotone drainer of equal net decline is NOT spiky")
  -- BITE: spiky damping demotes the spiky item below the steady one despite EQUAL net
  -- decline (200) and equal sample evidence (n=30). Without the spiky damp they'd tie on
  -- _rank and fall to the name tiebreak (d < s, so steady wins anyway) -- so make the SPIKY
  -- item win the name tiebreak (rename steady to 'z') and prove damping still ranks it below.
  local both = {
    aa = { label = "Spiky",  t0 = 0, a0 = 1000, tN = 120000, aN = 800, minA = 100, maxA = 1200, n = 30 },
    zz = { label = "Steady", t0 = 0, a0 = 1000, tN = 120000, aN = 800, minA = 800, maxA = 1000, n = 30 },
  }
  local br = suggest.analyze(both, { managed = {}, minDrain = 64 })
  t.eq(br[1].name, "zz",
    "CONF-2 BITE: spiky damping ranks a self-replenishing item below a steady drainer of equal decline")
end

-- ---------------------------------------------------------------------------
print("CONF-4 invariants: one suggestion per name + truncation keeps highest-conf")
do
  -- INVARIANT 1: each item takes exactly one branch -> at most one suggestion per name.
  -- A history with a mix of draining / growing / managed-below-target items must never
  -- emit two rows for the same name (guards future branch additions like needpattern).
  local mix = {
    drain = { label = "Drain", t0 = 0, a0 = 1000, tN = 120000, aN = 200, minA = 200, maxA = 1000, n = 20 },
    grow  = { label = "Grow",  t0 = 0, a0 = 1000, tN = 120000, aN = 5000, minA = 1000, maxA = 5000, n = 20 },
    okmgd = { label = "OkMgd", t0 = 0, a0 = 900,  tN = 120000, aN = 800,  minA = 800,  maxA = 900,  n = 20 },
  }
  local sg = suggest.analyze(mix, { managed = {}, quotas = { okmgd = { target = 256, craftTo = 300 } },
    patternless = { drain = true }, minDrain = 64 })
  local seen = {}
  for _, s in ipairs(sg) do
    t.check(not seen[s.name], "CONF-4: item '" .. s.name .. "' appears at most once")
    seen[s.name] = true
  end
  t.check(seen.drain, "CONF-4: patternless branch still emits exactly one row for the drainer")

  -- INVARIANT 2: when truncating to max, the KEPT set is the highest-ranked. Build many
  -- equal-decline drainers with varying evidence; with max=2 the two kept must be the two
  -- with the strongest confidence (most samples + longest span), not arbitrary tail items.
  -- Spans stay below idealWindow (4*60000=240000) so spanConf is strictly monotone in i and
  -- no two items tie on _rank: it1 (n=3, span=30000) is thinnest, it6 (n=8, span=180000) richest.
  local many = {}
  for i = 1, 6 do
    many["it" .. i] = { label = "It" .. i, t0 = 0, a0 = 1000, tN = 30000 * i, aN = 200, minA = 200, maxA = 1000, n = 2 + i }
  end
  -- max=3 keeps the three full-confidence items (it4/it5/it6, conf saturates at 1) and drops
  -- the thinner-evidence tail (it1/it2/it3) even though all share the same net decline (800).
  local capped = suggest.analyze(many, { managed = {}, minDrain = 64, minWindowMs = 30000, max = 3 })
  t.eq(#capped, 3, "CONF-4: truncation respects max")
  local keptNames = {}; for _, s in ipairs(capped) do keptNames[s.name] = true end
  t.check(keptNames["it4"] and keptNames["it5"] and keptNames["it6"],
    "CONF-4: truncation keeps the full-confidence drainers, not the thin tail")
  t.check(not keptNames["it1"] and not keptNames["it2"],
    "CONF-4 BITE: the thinnest-evidence drainers are dropped (would survive without conf weighting)")
end

-- ---------------------------------------------------------------------------
print("CONF-3 confLabel bucketing (lo/med/hi for the SMART row)")
do
  t.eq(suggest.confLabel(0.0), "lo", "CONF-3: 0 -> lo")
  t.eq(suggest.confLabel(0.32), "lo", "CONF-3: just below 0.33 -> lo")
  t.eq(suggest.confLabel(0.33), "med", "CONF-3: 0.33 boundary -> med")
  t.eq(suggest.confLabel(0.5), "med", "CONF-3: mid -> med")
  t.eq(suggest.confLabel(0.66), "hi", "CONF-3: 0.66 boundary -> hi")
  t.eq(suggest.confLabel(1.0), "hi", "CONF-3: 1 -> hi")
  t.eq(suggest.confLabel(nil), nil, "CONF-3: nil -> nil (caller hides it)")
  t.eq(suggest.confLabel("x"), nil, "CONF-3: non-number -> nil")
end

-- ---------------------------------------------------------------------------
print("A3 bridge-degraded counter (pure health helper)")
do
  -- N-1 consecutive failures stay healthy; the Nth crosses the threshold.
  local st = {}
  local d2, c2
  local d1, c1 = health.bridgeDegraded(st, false, 3)
  t.check(d1 == false, "A3: 1 failure of 3 not degraded")
  t.eq(c1, 1, "A3: count 1 after first failure")
  d2, c2 = health.bridgeDegraded(st, false, 3)
  t.check(d2 == false, "A3: 2 failures of 3 not degraded (N-1)")
  t.eq(c2, 2, "A3: count 2 after second failure")
  local d3, c3 = health.bridgeDegraded(st, false, 3)
  t.check(d3 == true, "A3: Nth (3rd) failure is degraded")
  t.eq(c3, 3, "A3: count 3 at threshold")

  -- a success resets the count and clears degraded.
  local d4, c4 = health.bridgeDegraded(st, true, 3)
  t.check(d4 == false, "A3: success clears degraded")
  t.eq(c4, 0, "A3: success resets count to 0")

  -- counts are monotonic across failures until a reset.
  local st2 = {}
  for i = 1, 5 do
    local _, c = health.bridgeDegraded(st2, false, 3)
    t.eq(c, i, "A3: monotonic failure count = " .. i)
  end
  local stayDeg, stayC = health.bridgeDegraded(st2, false, 3)
  t.check(stayDeg == true, "A3: stays degraded past threshold")
  t.eq(stayC, 6, "A3: count keeps climbing while failing")

  -- default threshold is 3 when none supplied.
  local st3 = {}
  health.bridgeDegraded(st3, false)
  health.bridgeDegraded(st3, false)
  local dDef = health.bridgeDegraded(st3, false)
  t.check(dDef == true, "A3: default threshold (3) degrades on 3rd failure")

  -- only ok==true counts as success; falsy values are failures.
  local st4 = {}
  local _, cNil = health.bridgeDegraded(st4, nil, 3)
  t.eq(cNil, 1, "A3: nil treated as failure")
  local _, cFalse = health.bridgeDegraded(st4, false, 3)
  t.eq(cFalse, 2, "A3: false treated as failure")

end

-- ---------------------------------------------------------------------------
-- gateCrafts: the pure fire/hold decision the manager wires in, with RECOVERY
-- HYSTERESIS. threshold=3 consecutive failures to hold; recover=2 consecutive clean
-- reads to resume. The critical property the earlier no-op got wrong: a degraded
-- bridge's FIRST clean read must still HOLD -- firing resumes only after `recover`
-- clean reads, covering the dangerous re-attach window. Own do-scope so the locals
-- above are freed first (run.lua main chunk is near Lua's 200-local cap).
print("A3 gateCrafts recovery hysteresis (pure)")
do
  local a, hold, f, c -- reused scratch (allowFire, holding, fails, cleanStreak)
  -- a never-failed bridge fires immediately (steady state).
  a = health.gateCrafts({}, true, 3, 2)
  t.check(a == true, "A3: clean bridge fires from the start (no spurious hold)")
  -- below the failure threshold, still firing.
  a, hold, f = health.gateCrafts({}, false, 3, 2)
  t.check(a == true and hold == false and f == 1, "A3: gate allows fire below failure threshold")
  -- 3 consecutive failures -> held.
  local h = {}
  health.gateCrafts(h, false, 3, 2)
  health.gateCrafts(h, false, 3, 2)
  a, hold, f = health.gateCrafts(h, false, 3, 2)
  t.check(a == false and hold == true and f == 3, "A3: gate HOLDS crafts at the failure threshold")
  -- the FIRST clean read after a degraded window must STILL hold (the no-op bug
  -- resumed here). cleanStreak=1 < recover=2.
  a, hold, f, c = health.gateCrafts(h, true, 3, 2)
  t.check(a == false and hold == true and c == 1,
    "A3: gate STILL HOLDS on the first clean read after degraded (hysteresis)")
  -- the SECOND consecutive clean read resumes firing (recover=2 reached).
  a, hold, f, c = health.gateCrafts(h, true, 3, 2)
  t.check(a == true and hold == false and c == 2,
    "A3: gate RESUMES after recover consecutive clean reads")
  -- a failure mid-recovery resets the clean streak (must re-earn the full recover).
  local r = {}
  for _ = 1, 3 do health.gateCrafts(r, false, 3, 2) end -- held
  health.gateCrafts(r, true, 3, 2)                       -- cleanStreak 1 (held)
  health.gateCrafts(r, false, 3, 2)                      -- failure resets streak
  a, hold, f, c = health.gateCrafts(r, true, 3, 2)
  t.check(a == false and hold == true and c == 1,
    "A3: a failure mid-recovery resets the clean streak (re-earn recover)")
  -- default recover is 2 when none supplied.
  local d = {}
  for _ = 1, 3 do health.gateCrafts(d, false) end -- held (default threshold 3)
  a = health.gateCrafts(d, true)                  -- 1 clean (held, default recover 2)
  hold = health.gateCrafts(d, true)               -- 2 clean (resume); reuse `hold` as scratch
  t.check(a == false and hold == true, "A3: default recover (2) clean reads to resume")
end

-- ---------------------------------------------------------------------------
-- .tmp-orphan sweep: crash-recovery for atomicWrite leftovers (own do-scope).
print("atomicWrite .tmp sweep (health.sweepTmps)")
do
  local store = {
    ["a"] = "A", ["a.tmp"] = "Anew",  -- orphan: main exists -> discard the tmp
    ["b.tmp"] = "Bnew",               -- main missing -> recover (move tmp -> b)
    ["c"] = "C",                      -- no tmp -> untouched
  }
  local fakeFs = {
    exists = function(p) return store[p] ~= nil end,
    delete = function(p) store[p] = nil end,
    move = function(s, d) store[d] = store[s]; store[s] = nil end,
  }
  local disc, rec = health.sweepTmps(fakeFs, { "a", "b", "c" })
  t.check(disc == 1 and rec == 1, "sweepTmps: 1 discarded + 1 recovered")
  t.check(store["a"] == "A" and store["a.tmp"] == nil, "sweepTmps: orphan tmp discarded, main file kept intact")
  t.check(store["b"] == "Bnew" and store["b.tmp"] == nil, "sweepTmps: tmp recovered to main when main was missing")
  t.check(store["c"] == "C", "sweepTmps: a file with no .tmp is left untouched")
  t.check((select(1, health.sweepTmps(nil, {}))) == 0, "sweepTmps: nil fs is a guarded no-op")
end

-- ---------------------------------------------------------------------------
-- operatingTier: the one high-level switch that resolves to mode + capability flags.
-- Own do-scope + one reused scratch local (run.lua main chunk is near Lua's cap).
print("operating tiers (control.applyTier)")
do
  local c -- reused scratch
  c = control.applyTier({ operatingTier = "viewer" })
  t.check(c.mode == control.MODE_MONITOR and c.allowAutocraft == false and c.stockKeeper.enabled == false,
    "tier viewer -> monitor mode, no autocraft, planner off")
  c = control.applyTier({ operatingTier = "manual" })
  t.check(c.mode == control.MODE_MANUAL and c.allowAutocraft == true and c.stockKeeper.enabled == true,
    "tier manual -> manual mode, autocraft on, planner on")
  c = control.applyTier({ operatingTier = "auto" })
  t.check(c.mode == control.MODE_AUTO and c.allowAutocraft == true and c.stockKeeper.enabled == true,
    "tier auto -> auto mode, autocraft on, planner on")
  -- unset tier: raw mode/flags preserved, no stockKeeper invented (backward compatible).
  c = control.applyTier({ mode = "dry-run", allowAutocraft = false })
  t.check(c.mode == "dry-run" and c.allowAutocraft == false and c.stockKeeper == nil,
    "no operatingTier -> config untouched (backward compatible)")
  -- unknown tier ignored (keeps raw mode).
  c = control.applyTier({ operatingTier = "turbo", mode = "manual" })
  t.check(c.mode == "manual", "unknown tier ignored (keeps raw mode)")
  -- tier sets stockKeeper.enabled but PRESERVES other stockKeeper fields.
  c = control.applyTier({ operatingTier = "auto", stockKeeper = { cooldownSeconds = 99 } })
  t.check(c.stockKeeper.cooldownSeconds == 99 and c.stockKeeper.enabled == true,
    "tier preserves other stockKeeper fields, only sets .enabled")
end

-- ---------------------------------------------------------------------------
-- Input reserve (craftFrom): keep a dust buffer; only smelt the surplus into ingots.
print("input reserve (craftFrom dust buffer)")
do
  local function planWith(dustAmt, ingotAmt, ratio)
    return stockplan.plan({
      stockKeeper = {
        enabled = true, cooldownSeconds = 300, maxCraftsPerCycle = 99, maxRequest = 1000000,
        categories = { { label = "Metals", items = {
          { name = "iron_ingot", label = "Iron Ingot", target = 5000, craftTo = 5000,
            craftFrom = { name = "iron_dust", reserve = 1000, ratio = ratio or 1 } },
        } } },
      },
      now = 0,
      ledger = { requests = {} },
      resolve = function(name)
        if name == "iron_ingot" then return ingotAmt, true, false end
        if name == "iron_dust" then return dustAmt, false, false end
        return 0, false, false
      end,
    })[1]
  end
  -- ample dust: full request (need 5000; headroom 10000-1000=9000 >= 5000) -- control row
  local p = planWith(10000, 0)
  t.check(p.action == "WOULD CRAFT" and p.request == 5000, "reserve: ample dust -> full craft request")
  -- limited dust: request capped to (dust - reserve)
  p = planWith(1500, 0)
  t.check(p.action == "WOULD CRAFT" and p.request == 500 and p.reserveCapped == true,
    "reserve: limited dust -> request capped to (dust - reserve)")
  -- dust exactly at reserve: fully held -> RESERVED (not a craft)
  p = planWith(1000, 0)
  t.check(p.action == "RESERVED", "reserve: dust at the reserve floor -> RESERVED (no craft)")
  -- dust below reserve: still RESERVED, never dips in
  p = planWith(800, 0)
  t.check(p.action == "RESERVED", "reserve: dust below reserve -> RESERVED")
  -- ratio > 1: input headroom divided by ratio (5000-1000)/2 = 2000
  p = planWith(5000, 0, 2)
  t.check(p.action == "WOULD CRAFT" and p.request == 2000, "reserve: ratio>1 divides input headroom")
  -- RESERVED maps to a real status (renderer won't choke)
  t.check(status.normalize("RESERVED") == status.RESERVED and status.severity("RESERVED") == 2,
    "reserve: RESERVED normalizes + has a severity")
end

-- ---------------------------------------------------------------------------
print("overflow balancer (compress above ceiling)")
local function ovItem(over) local i = { name = "dust", label = "Steel Dust",
  ceiling = 1000, into = { name = "ingot", label = "Steel Ingot" }, ratio = 1 }
  for k, v in pairs(over or {}) do i[k] = v end; return i end

-- below ceiling -> no compress row
t.eq(#balance.plan({ items = { ovItem() }, resolve = function() return 500, true, false end }), 0,
  "no overflow row while below the ceiling")

-- above ceiling, into craftable -> WOULD CRAFT, request = floor(surplus/ratio)
local br = balance.plan({ items = { ovItem({ ratio = 1 }) }, ledger = { requests = {} },
  resolve = function(name) if name == "dust" then return 1600, true, false end return 0, true, false end })
t.eq(br[1].action, "WOULD CRAFT", "surplus over ceiling -> WOULD CRAFT the denser item")
t.eq(br[1].name, "ingot", "compress row crafts the into-item")
t.eq(br[1].request, 600, "request = surplus / ratio (1600-1000)/1")
t.eq(br[1].category, "Overflow", "compress rows are categorised Overflow")

-- ratio 9 (ingots -> blocks)
local br9 = balance.plan({ items = { ovItem({ name = "ingot", into = { name = "block" }, ceiling = 1000, ratio = 9 } ) },
  ledger = { requests = {} }, resolve = function() return 1900, true, false end })
t.eq(br9[1].request, 100, "ratio 9: (1900-1000)/9 = 100 blocks")

-- into not craftable / already crafting
t.eq((balance.plan({ items = { ovItem() }, resolve = function(n) if n == "dust" then return 2000, true, false end return 0, false, false end })[1]).action,
  "NOT CRAFTABLE", "uncraftable into-item -> NOT CRAFTABLE")
t.eq((balance.plan({ items = { ovItem() }, resolve = function(n) if n == "dust" then return 2000, true, false, true end return 0, false, false, false end })[1]).action,
  "UNKNOWN-ID", "missing into-item -> UNKNOWN-ID")
t.eq((balance.plan({ items = { ovItem() }, resolve = function(n) if n == "dust" then return 2000, true, false end return 0, true, true end })[1]).action,
  "ALREADY CRAFTING", "in-flight into-item -> ALREADY CRAFTING")

-- cooldown keyed by the into item (shared with refills)
local brc = balance.plan({ items = { ovItem() }, now = 100000, cooldownSeconds = 300,
  ledger = { requests = { ingot = { requestedAt = 40000 } } },
  resolve = function(n) if n == "dust" then return 2000, true, false end return 0, true, false end })
t.eq(brc[1].action, "ON COOLDOWN", "recent into-item request -> ON COOLDOWN")

-- maxRequest cap
local brm = balance.plan({ items = { ovItem({ maxRequest = 50 }) }, ledger = { requests = {} },
  resolve = function(n) if n == "dust" then return 5000, true, false end return 0, true, false end })
t.eq(brm[1].request, 50, "compress request capped to maxRequest")
t.check(brm[1].capped == true, "capped flag set on compress row")

-- ---------------------------------------------------------------------------
print("quota presets (Zoozo bundles)")
local plist = presets.list()
t.check(#plist >= 4, "at least the four stage presets exist")
t.eq(plist[1].id, "early", "first preset is early game")
t.check(plist[1].count > 0, "presets carry items")
t.eq(presets.get("nope"), nil, "unknown preset id -> nil")

-- apply merges a preset's quotas into the managed store
local pstore = managed.new()
local _, n = presets.apply(pstore, "early", 1000)
t.eq(n, #presets.get("early").items, "apply writes every preset item")
t.eq(managed.count(pstore), n, "store holds the applied quotas")
local first = presets.get("early").items[1]
t.eq(managed.get(pstore, first.name).target, first.target, "applied quota carries the preset target")

-- applying a second preset adds its items without dropping the first
presets.apply(pstore, "mid", 2000)
t.check(managed.count(pstore) > n, "a second preset adds more quotas")
t.check(managed.has(pstore, first.name), "earlier preset quotas survive a later apply")

-- unknown preset is a no-op
local before = managed.count(pstore)
local _, n0 = presets.apply(pstore, "nope", 3000)
t.eq(n0, 0, "applying an unknown preset writes nothing")
t.eq(managed.count(pstore), before, "store unchanged by an unknown preset")

-- the named personal profile is opt-in and carries the compress chain
local zg = presets.get("zoozo-late-game")
t.check(zg ~= nil, "zoozo-late-game profile exists")
t.check(zg.personal == true, "it is flagged personal (opt-in, not a generic default)")
t.check(presets.settings("zoozo-late-game").smartMode == true, "profile reserves smartMode on")
t.check(presets.settings("early").smartMode == nil, "generic presets do NOT enable smart mode")
local zstore = managed.new()
presets.apply(zstore, "zoozo-late-game", 1)
local zincDust = managed.get(zstore, "alltheores:zinc_dust")
t.check(zincDust ~= nil and zincDust.ceiling ~= nil, "applying the profile sets a compress ceiling")
t.eq(zincDust.into.name, "alltheores:zinc_ingot", "compress chain flows through apply into the store")
t.check(#managed.overflowItems(zstore) >= 1, "profile produces overflow-managed items")

-- metadata backfill updates old managed stores without clobbering tuned quotas
do
  local old = managed.new()
  managed.set(old, {
    name = "modern_industrialization:advanced_motor",
    label = "Advanced Motor",
    target = 777,
    craftTo = 888,
  }, 1)
  local _, filled = presets.backfillMetadata(old, "zoozo-late-game")
  local motor = managed.get(old, "modern_industrialization:advanced_motor")
  t.eq(filled, 1, "metadata backfill updates matching old rows")
  t.eq(motor.target, 777, "metadata backfill preserves target")
  t.eq(motor.craftTo, 888, "metadata backfill preserves craftTo")
  t.eq(motor.craftMode, "watch", "metadata backfill adds craftMode")
  t.eq(motor.blockReason, "machine/assembler route; do not RS autocraft",
    "metadata backfill adds blockReason")
  local _, filledAgain = presets.backfillMetadata(old, "zoozo-late-game")
  t.eq(filledAgain, 0, "metadata backfill is idempotent")
  local countBefore = managed.count(old)
  local _, missingFill = presets.backfillMetadata(old, "missing")
  t.eq(missingFill, 0, "metadata backfill unknown preset writes nothing")
  t.eq(managed.count(old), countBefore, "metadata backfill unknown preset leaves store unchanged")
end

-- ---------------------------------------------------------------------------
print("console hit-testing")
local strip = console.tabs({ "PLAN", "QUEUE" }, 2)
t.eq(strip.text, "[PLAN] [QUEUE]", "tab strip renders as [PLAN] [QUEUE]")
t.eq(console.tabHit(strip, 3, 2), 1, "tap inside [PLAN] -> page 1")
t.eq(console.tabHit(strip, 10, 2), 2, "tap inside [QUEUE] -> page 2")
t.eq(console.tabHit(strip, 7, 2), nil, "tap the gap between tabs -> nil")
t.eq(console.tabHit(strip, 3, 3), nil, "tap the wrong row -> nil")
-- the short 5-tab strip (used when the full one overflows) fits a narrow monitor
local shortStrip = console.tabs({ "PLAN", "QUE", "BRWS", "PRE", "SMRT" }, 2)
t.check(shortStrip.tabs[#shortStrip.tabs].x2 <= 34, "short tab strip fits a ~34-col monitor (SMART reachable)")
local hitRows = { { y = 5, entry = "a" }, { y = 6, entry = "b" } }
t.eq(console.rowHit(hitRows, 6), "b", "rowHit returns the entry at that y")
t.eq(console.rowHit(hitRows, 9), nil, "rowHit miss -> nil")
-- forgiving taps: tolerance snaps a near-miss to the nearest target (the finicky-tap fix).
local tolRows = { { y = 5, entry = "a" }, { y = 8, entry = "b" } }
t.eq(console.rowHit(tolRows, 6), nil, "rowHit tol 0 (default): a 1-off tap still misses")
t.eq(console.rowHit(tolRows, 6, 1), "a", "rowHit tol 1: 1-off snaps to the nearest row (5)")
t.eq(console.rowHit(tolRows, 9, 1), "b", "rowHit tol 1: 1-off snaps to the nearest row (8)")
t.eq(console.rowHit(tolRows, 12, 1), nil, "rowHit tol 1: beyond tolerance -> nil")
t.eq(console.tabHit(strip, 3, 3), nil, "tabHit tol 0: a 1-off row misses")
t.eq(console.tabHit(strip, 3, 3, 1), 1, "tabHit tol 1: a 1-off row still hits the tab")
t.eq(console.tabHit(strip, 3, 5, 1), nil, "tabHit tol 1: 3 rows off is still beyond tolerance")

-- display profile resolver (viewer screens), mirrors the theme resolver
t.clearFiles()
t.eq(console.resolveProfile(nil), "view", "missing file -> default view profile")
t.eq(console.resolveProfile("autocraft"), "autocraft", "valid override wins")
t.eq(console.resolveProfile("nonsense"), "view", "invalid override + no file -> default")
t.setFile("atm10-display", "alerts\n")
t.eq(console.resolveProfile(nil), "alerts", "file value is used")
t.setFile("atm10-display", "# comment\nbadname\nautocraft\n")
t.eq(console.resolveProfile(nil), "autocraft", "comments + invalid lines skipped")
t.clearFiles()

-- paginate: clamp, slice, and handle empty / overflow pages
local p1 = console.paginate(25, 10, 1)
t.eq(p1.pages, 3, "25 items / 10 per page -> 3 pages")
t.eq(p1.from, 1, "page 1 starts at 1")
t.eq(p1.to, 10, "page 1 ends at 10")
local p3 = console.paginate(25, 10, 3)
t.eq(p3.from, 21, "page 3 starts at 21")
t.eq(p3.to, 25, "page 3 ends at the last item")
t.eq(console.paginate(25, 10, 9).page, 3, "overflow page clamps to last page")
t.eq(console.paginate(25, 10, 0).page, 1, "page < 1 clamps to 1")
local pe = console.paginate(0, 10, 1)
t.eq(pe.pages, 1, "empty list still has 1 page")
t.check(pe.from > pe.to, "empty list yields an empty render range")

-- buttonRow: layout + hit-testing for the quota editor
local row = console.buttonRow({ { label = "-1", key = "t:-1" }, { label = "+1", key = "t:1" }, { label = "SAVE", key = "save" } }, 5, 1)
t.eq(#row.buttons, 3, "button row lays out every spec")
t.eq(row.buttons[1].text, "[-1]", "button label is bracketed")
t.eq(console.buttonHit(row, 2, 5), "t:-1", "tap inside first button -> its key")
t.eq(console.buttonHit(row, row.buttons[3].x1, 5), "save", "tap SAVE -> save key")
t.eq(console.buttonHit(row, 1, 6), nil, "tap the wrong row -> nil")
t.eq(console.buttonHit(row, 999, 5), nil, "tap past the buttons -> nil")

-- autoRotateDue (E1): recent touches pause auto-rotation on dashboard pages
local autoPages = { PLAN = true, QUEUE = true, HEALTH = true }
t.eq(console.autoRotateDue("PLAN", autoPages, 1000, nil, 7000, 5), true,
  "autoRotateDue: auto page rotates once page age exceeds threshold")
t.eq(console.autoRotateDue("PLAN", autoPages, 1000, 6500, 7000, 5), false,
  "autoRotateDue: recent touch pauses rotation even when page is old")
t.eq(console.autoRotateDue("BROWSE", autoPages, 1000, nil, 7000, 5), false,
  "autoRotateDue: manual page never rotates")
t.eq(console.autoRotateDue("PLAN", autoPages, 1000, nil, 7000, 0), false,
  "autoRotateDue: PAGE_SECONDS=0 disables rotation")

-- boundedSlice (VIEW-1): payload entry count stays <= cap regardless of grid size
do
  local grid = {}
  for i = 1, 5900 do grid[i] = { name = "minecraft:item" .. i, amount = i } end
  t.eq(#console.boundedSlice(grid, 150), 150, "boundedSlice caps a 5900-item grid to the view limit")
  t.eq(#console.boundedSlice(grid, 8), 8, "boundedSlice keeps the 8-item header summary cap")
  t.eq(#console.boundedSlice({ 1, 2, 3 }, 150), 3, "boundedSlice returns all when grid < limit")
  t.eq(#console.boundedSlice(nil, 10), 0, "boundedSlice tolerates a nil list")
  t.eq(console.boundedSlice(grid, 5)[5].name, "minecraft:item5", "boundedSlice preserves order + element shape")
end

-- sortItems / sort cycle (VIEW-3)
do
  local function items() return {
    { name = "Zinc", amount = 10, id = "alltheores:zinc" },
    { name = "apple", amount = 50, id = "minecraft:apple" },
    { name = "Iron", amount = 30, id = "minecraft:iron" },
  } end
  local q = console.sortItems(items(), "qty")
  t.eq(q[1].name, "apple", "qty sort: highest amount first")
  t.eq(q[3].name, "Zinc", "qty sort: lowest amount last")
  local az = console.sortItems(items(), "az")
  t.eq(az[1].name, "apple", "az sort: case-insensitive name asc")
  t.eq(az[3].name, "Zinc", "az sort: Zinc last")
  local md = console.sortItems(items(), "mod")
  t.eq(md[1].id, "alltheores:zinc", "mod sort: alltheores namespace first")
  t.check(md[2].id:find("minecraft", 1, true) and md[3].id:find("minecraft", 1, true), "mod sort: minecraft items grouped after")
  t.eq(console.nextSort("qty"), "az", "nextSort cycles qty -> az")
  t.eq(console.nextSort("mod"), "qty", "nextSort wraps mod -> qty")
  t.eq(console.sortLabel("az"), "A-Z", "sortLabel maps az")
  local original = items()
  local copied = console.sortedItems(original, "qty")
  t.eq(copied[1].name, "apple", "sortedItems returns a sorted copy")
  t.eq(original[1].name, "Zinc", "sortedItems leaves original order untouched")
  t.check(copied ~= original, "sortedItems returns a new table")
end

-- A2 request-panel helpers (filter / quantity / job-row / token)
do
  local function items()
    return {
      { name = "Zinc Ingot", id = "alltheores:zinc_ingot", amount = 100 },
      { name = "Iron Ingot", id = "minecraft:iron_ingot", amount = 200 },
      { name = "Copper Ingot", id = "alltheores:copper_ingot", amount = 50 },
    }
  end

  -- filterItems: substring over name AND id; empty query unchanged; no mutation
  local src = items()
  local all = console.filterItems(src, "")
  t.eq(#all, 3, "filterItems: empty query returns all")
  t.check(all ~= src, "filterItems: returns a new array (no aliasing)")
  t.eq(#console.filterItems(items(), "zinc"), 1, "filterItems: matches display name (case-insensitive)")
  t.eq(console.filterItems(items(), "zinc")[1].id, "alltheores:zinc_ingot", "filterItems: returns the matching entry")
  t.eq(#console.filterItems(items(), "minecraft:"), 1, "filterItems: matches registry id substring")
  t.eq(#console.filterItems(items(), "alltheores:"), 2, "filterItems: id-namespace matches both alltheores rows")
  t.eq(#console.filterItems(items(), "nonsuch"), 0, "filterItems: no match -> empty")
  local pre = items()
  console.filterItems(pre, "iron")
  t.eq(#pre, 3, "filterItems: does NOT mutate the input list")

  -- stepQuantity: clamps >=1, applies delta, saturates at max, non-numeric -> min
  t.eq(console.stepQuantity(5, 8), 13, "stepQuantity: +8")
  t.eq(console.stepQuantity(5, -64), 1, "stepQuantity: clamps to min 1")
  t.eq(console.stepQuantity(1, -1), 1, "stepQuantity: never below 1")
  t.eq(console.stepQuantity(99998, 64), 99999, "stepQuantity: saturates at default max")
  t.eq(console.stepQuantity(50, 0, { max = 64 }), 50, "stepQuantity: opts.max honored (in range)")
  t.eq(console.stepQuantity(50, 64, { max = 64 }), 64, "stepQuantity: opts.max caps")
  t.eq(console.stepQuantity("oops", 8), 9, "stepQuantity: non-numeric current snaps to min then steps")

  -- quantityButtonRow / quantitySteps: keys + biting hit-test
  local qr = console.quantityButtonRow(64, 5, 1)
  t.eq(console.buttonHit(qr, qr.buttons[1].x1, 5), "dec:1024", "quantityButtonRow: first button is -1024")
  local submitBtn
  for _, b in ipairs(qr.buttons) do if b.key == "submit" then submitBtn = b end end
  t.check(submitBtn ~= nil, "quantityButtonRow: has a SUBMIT button")
  t.eq(console.buttonHit(qr, submitBtn.x1, 5), "submit", "quantityButtonRow: tap SUBMIT x -> submit (BITING)")
  t.eq(console.buttonHit(qr, submitBtn.x2 + 1, 5), nil, "quantityButtonRow: one column past SUBMIT -> nil (BITING)")
  local incBtn
  for _, b in ipairs(qr.buttons) do if b.key == "inc:64" then incBtn = b end end
  t.eq(console.buttonHit(qr, incBtn.x1, 5), "inc:64", "quantityButtonRow: +64 button hits inc:64")

  -- requestStatusLabel + jobRowFormat: distinct text/colorKey per state, fits width
  local approved = console.jobRowFormat({ label = "Zinc", request = 64, state = "APPROVED" }, 40)
  local crafting = console.jobRowFormat({ label = "Zinc", request = 64, state = "CRAFTING" }, 40)
  local errored = console.jobRowFormat({ label = "Zinc", request = 64, error = "no recipe" }, 40)
  t.eq(approved.colorKey, "queued", "jobRowFormat: APPROVED -> queued colorKey")
  t.eq(crafting.colorKey, "crafting", "jobRowFormat: CRAFTING -> crafting colorKey")
  t.eq(errored.colorKey, "error", "jobRowFormat: error entry -> error colorKey")
  t.check(approved.text ~= crafting.text, "jobRowFormat: APPROVED and CRAFTING render distinct text")
  t.check(errored.text:find("FAILED", 1, true) ~= nil, "jobRowFormat: error row surfaces FAILED + reason")
  t.check(errored.text:find("no recipe", 1, true) ~= nil, "jobRowFormat: error row carries the reason")
  t.check(#console.jobRowFormat({ label = string.rep("x", 200), request = 1 }, 30).text <= 30, "jobRowFormat: fits width")
  t.eq(console.requestStatusLabel({ requested = 64, made = 16, state = "CRAFTING" }), "crafting 16/64",
    "requestStatusLabel: manual made/requested in CRAFTING")
  t.eq(console.requestStatusLabel({ requested = 64, made = 64 }), "done", "requestStatusLabel: made>=requested -> done")
  t.eq(console.requestStatusLabel({ requested = 64, made = 0, state = "APPROVED" }), "queued 0/64",
    "requestStatusLabel: queued progress")

  -- resolveControlToken: reads + trims; missing file -> nil
  local realFs = _G.fs
  _G.fs = {
    exists = function(p) return p == console.controlTokenFile end,
    open = function() return { readAll = function() return "# my token file\n  s3cret-token  \n" end, close = function() end } end,
  }
  t.eq(console.resolveControlToken(), "s3cret-token", "resolveControlToken: trims comments + whitespace")
  _G.fs = { exists = function() return false end }
  t.eq(console.resolveControlToken(), nil, "resolveControlToken: missing file -> nil")
  _G.fs = realFs
end

-- trend (VIEW-5): direction + per-min rate, graceful on missing history
do
  local h = {
    drain  = { t0 = 0, a0 = 1000, tN = 120000, aN = 400 }, -- -600 / 2min = -300/m
    grow   = { t0 = 0, a0 = 100,  tN = 60000,  aN = 700 }, -- +600 / 1min = +600/m
    stable = { t0 = 0, a0 = 500,  tN = 120000, aN = 500 }, -- 0/m
  }
  local d = suggest.trend(h, "drain")
  t.eq(d.dir, "down", "trend: declining item -> down")
  t.eq(math.floor(d.perMin), -300, "trend: per-min drain rate")
  t.eq(suggest.trend(h, "grow").dir, "up", "trend: growing item -> up")
  t.eq(suggest.trend(h, "stable").dir, "flat", "trend: stable item -> flat")
  t.eq(suggest.trend(h, "missing"), nil, "trend: unseen item -> nil (hidden, never errors)")
  t.eq(suggest.trend(nil, "x"), nil, "trend: nil history -> nil")
end

-- ---------------------------------------------------------------------------
print("draw double-buffer (UI-1)")
do
  local buf = draw.newBuffer(10, 3)
  t.eq(#buf.rows, 3, "newBuffer makes height rows")
  t.eq(buf.rows[1].text, "          ", "newBuffer rows start blank (width spaces)")
  t.eq(#buf.rows[1].fg, 10, "newBuffer fg run matches width")
  draw.bufferWrite(buf, 3, 2, "HI", colors.red, colors.white)
  t.eq(buf.rows[2].text, "  HI      ", "bufferWrite places text at x")
  t.eq(buf.rows[2].fg:sub(3, 4), "ee", "bufferWrite sets fg on the written cells (red=e)")
  t.eq(buf.rows[2].bg:sub(3, 4), "00", "bufferWrite sets bg on the written cells (white=0)")
  draw.bufferWrite(buf, 9, 1, "ABCDE", colors.white, colors.black)
  t.eq(buf.rows[1].text, "        AB", "bufferWrite clips at the right edge")
  -- renderBuffer: blit only changed rows; same-as-previous -> no writes
  local writes = {}
  local target = { getSize = function() return 10, 3 end, setCursorPos = function() end,
    blit = function(txt) writes[#writes + 1] = txt end }
  draw.renderBuffer(target, buf, nil)
  t.eq(#writes, 3, "renderBuffer with no previous blits every row")
  writes = {}
  draw.renderBuffer(target, buf, buf)
  t.eq(#writes, 0, "renderBuffer skips unchanged rows (diff)")

  local panel = draw.newBuffer(18, 5)
  draw.box(panel, 2, 1, 16, 3, "Power", colors.cyan, colors.black)
  t.eq(panel.rows[1].text:sub(2, 2), "+", "box writes its left corner into a render buffer")
  t.eq(panel.rows[1].text:sub(17, 17), "+", "box writes its right corner into a render buffer")
  t.check(panel.rows[1].text:find("POWER", 1, true) ~= nil, "box writes its title into a render buffer")
  draw.gauge(panel, 3, 4, 10, 50, colors.yellow)
  t.eq(panel.rows[4].text:sub(3, 12), "[####----]", "gauge writes into a render buffer")
  t.eq(panel.rows[4].fg:sub(3, 12), "4444444444", "gauge preserves the requested color in buffer cells")
end

-- ---------------------------------------------------------------------------
print("power math (QUICK-2)")
do
  -- fmt thresholds (FE / kFE / MFE / GFE / TFE)
  t.eq(power.fmt(999), "999 FE", "fmt: < 1k stays FE")
  t.eq(power.fmt(1500), "1.5 kFE", "fmt: kFE threshold")
  t.eq(power.fmt(2500000), "2.50 MFE", "fmt: MFE threshold")
  t.eq(power.fmt(3000000000), "3.00 GFE", "fmt: GFE threshold")
  t.eq(power.fmt(4000000000000), "4.00 TFE", "fmt: TFE threshold")
  -- percent normalization (0-1 fraction / 1-100 / fallback / maxEnergy=0)
  t.eq(power.percent(0.45), 45, "percent: 0-1 fraction -> *100")
  t.eq(power.percent(45), 45, "percent: already 1-100 -> as-is")
  t.eq(power.percent(0, 500, 1000), 50, "percent: falls back to energy/maxEnergy")
  t.eq(power.percent(0, 500, 0), 0, "percent: maxEnergy 0 -> 0 (no divide-by-zero)")
  -- effectiveNet: reported vs estimated switch
  local n1, s1 = power.effectiveNet({ input = 100, output = 40 })
  t.eq(n1, 60, "effectiveNet: reported input-output when IO present")
  t.eq(s1, "reported", "effectiveNet: source reported")
  local n2, s2 = power.effectiveNet({ input = 0, output = 0, estimatedNet = -250 })
  t.eq(n2, -250, "effectiveNet: switches to estimated when IO both zero")
  t.eq(s2, "estimated", "effectiveNet: source estimated")
  -- estimateTime: stable / empty / full + the /20 (FE/t -> FE/s) conversion
  local _, st = power.estimateTime(1000, 2000, 0)
  t.eq(st, "stable", "estimateTime: |net|<1 -> stable")
  local et, se = power.estimateTime(1200, 5000, -1)
  t.eq(se, "empty", "estimateTime: net<0 -> empty")
  t.eq(et, "Empty in 1m", "estimateTime: drains 1200 at 1/t (/20) -> 60s = 1m")
  local _, sf = power.estimateTime(1000, 5000, 1)
  t.eq(sf, "full", "estimateTime: net>0 -> full")
  -- QUICK-1: transfer-cap headroom (% of cap used); nil when cap unknown
  t.eq(power.headroom(50, 100), 50, "headroom: 50 of 100 -> 50%")
  t.eq(power.headroom(0, 100), 0, "headroom: 0 used -> 0%")
  t.eq(power.headroom(100, 100), 100, "headroom: at cap -> 100%")
  t.eq(power.headroom(5, 0), nil, "headroom: cap 0 -> nil (display hides it)")
  t.eq(power.headroom(nil, 100), 0, "headroom: nil used -> 0%")
  t.check(power.headroom(150, 100) > 100, "headroom: over-cap is not clamped (anomaly shows)")
  -- QUICK-3: edge-triggered alarm (fires on ENTRY to an alarming status, not while it persists)
  local fire, active = power.alarmDecision("CRITICAL", false)
  t.check(fire == true and active == true, "alarm: fires on entry to CRITICAL")
  fire, active = power.alarmDecision("CRITICAL", active)
  t.check(fire == false and active == true, "alarm: does NOT re-fire while still CRITICAL (hysteresis)")
  fire, active = power.alarmDecision("OK", active)
  t.check(fire == false and active == false, "alarm: clears when status returns to OK")
  t.check((power.alarmDecision("STALE DATA", false)), "alarm: fires on entry to STALE DATA")
  t.check(not (power.alarmDecision("LOW", false)), "alarm: LOW is not an alarming status by default")
  t.check((power.alarmDecision("DRAINING", false, { states = { DRAINING = true } })),
    "alarm: states are configurable (DRAINING alarms when opted in)")
  -- deadband: pct jitter across the CRITICAL line (CRITICAL -> LOW -> CRITICAL) must NOT re-fire
  local af, aa = power.alarmDecision("CRITICAL", false)
  af, aa = power.alarmDecision("LOW", aa)
  t.check(af == false and aa == true, "alarm: LOW holds the latch (deadband, stays active)")
  af, aa = power.alarmDecision("CRITICAL", aa)
  t.check(af == false, "alarm: re-entering CRITICAL after a dip to LOW does NOT chatter")
  af, aa = power.alarmDecision("DRAINING", aa)
  t.check(aa == false, "alarm: only a full recovery (OK/DRAINING, pct out of the LOW band) re-arms")
end

-- ---------------------------------------------------------------------------
print("power graph helpers (POWER-GRAPH)")
do
  -- downsample: 4 samples into 2 buckets -> {min,max,avg,last,n} per bucket.
  -- bucket1 = {1,2}, bucket2 = {3,4} (contiguous, oldest-first).
  local ds = power.downsample({ 1, 2, 3, 4 }, 2)
  t.eq(#ds, 2, "downsample: returns exactly width buckets")
  t.eq(ds[1].min, 1, "downsample: bucket1 min")
  t.eq(ds[1].max, 2, "downsample: bucket1 max")
  t.eq(ds[1].avg, 1.5, "downsample: bucket1 avg")
  t.eq(ds[1].last, 2, "downsample: bucket1 last")
  t.eq(ds[1].n, 2, "downsample: bucket1 count")
  t.eq(ds[2].min, 3, "downsample: bucket2 min")
  t.eq(ds[2].max, 4, "downsample: bucket2 max")
  t.eq(ds[2].avg, 3.5, "downsample: bucket2 avg")
  t.eq(ds[2].n, 2, "downsample: bucket2 count")
  -- BITE: revert the bucketing (1:1 last-N indexing) and bucket2.max becomes 2 not 4 -- this
  -- asserts the WHOLE window is aggregated, not just the last `width` samples.
  -- whole-window: 180 samples compressed into 50 cols still sees the oldest value.
  local big = {}
  for i = 1, 180 do big[i] = i end
  local wide = power.downsample(big, 50)
  t.eq(#wide, 50, "downsample: 180 -> 50 buckets")
  t.eq(wide[1].min, 1, "downsample: first bucket holds the OLDEST sample (window not dropped)")
  t.eq(wide[50].max, 180, "downsample: last bucket holds the NEWEST sample")
  -- fewer samples than width -> data sits at the left, trailing buckets empty (n=0)
  local sparse = power.downsample({ 7, 9 }, 5)
  t.eq(sparse[1].last, 7, "downsample: sparse keeps chronological order (left)")
  t.eq(sparse[2].last, 9, "downsample: sparse second sample in second bucket")
  t.eq(sparse[3].n, 0, "downsample: trailing buckets empty when fewer samples than width")
  -- guards
  t.eq(#power.downsample({ 1, 2 }, 0), 0, "downsample: width 0 -> empty")
  t.eq(power.downsample({}, 3)[1].n, 0, "downsample: no values -> empty buckets")

  -- bucketByTimeframe: slice the last windowSeconds then bucket. 100 samples at 1Hz, want
  -- last 10s -> samples 91..100 into 5 cols. bucket1 covers {91,92}, bucket5 covers {99,100}.
  local series = {}
  for i = 1, 100 do series[i] = i end
  local tf = power.bucketByTimeframe(series, 10, 5, 1)
  t.eq(#tf, 5, "bucketByTimeframe: returns columns buckets")
  t.eq(tf[1].min, 91, "bucketByTimeframe: window starts at the right TAIL (last 10s)")
  t.eq(tf[5].max, 100, "bucketByTimeframe: window ends at the newest sample")
  -- BITE: if the slice took the HEAD instead of the tail, tf[1].min would be 1 not 91.
  -- window longer than the buffer -> uses everything available (no crash, no empty tail jump)
  local tfBig = power.bucketByTimeframe(series, 3600, 4, 1)
  t.eq(tfBig[1].min, 1, "bucketByTimeframe: window > buffer falls back to whole buffer")
  t.eq(tfBig[4].max, 100, "bucketByTimeframe: window > buffer keeps newest")
  -- sampleHz scales the window: 50 samples at 2Hz, want 5s -> 10 samples (41..50)
  local hz = {}
  for i = 1, 50 do hz[i] = i end
  local tfHz = power.bucketByTimeframe(hz, 5, 2, 2)
  t.eq(tfHz[1].min, 41, "bucketByTimeframe: sampleHz scales sample count (5s @ 2Hz = 10)")
  t.eq(#power.bucketByTimeframe(series, 10, 0, 1), 0, "bucketByTimeframe: columns 0 -> empty")

  -- computeScale: auto tracks max(abs); fixed pins to caller; both floor at 1.
  t.eq(power.computeScale({ 10, -40, 25 }, "auto"), 40, "computeScale: auto = max(abs)")
  t.eq(power.computeScale({ 5, -3 }, "fixed", 200), 200, "computeScale: fixed pins to caller value")
  -- BITE: fixed must IGNORE the data peak -- data peaks at 999 but fixed stays 200.
  t.eq(power.computeScale({ 999, -50 }, "fixed", 200), 200, "computeScale: fixed ignores data peak")
  t.eq(power.computeScale({ 0, 0, 0 }, "auto"), 1, "computeScale: auto floors at 1 (no divide-by-zero)")
  t.eq(power.computeScale({}, "fixed", 0), 1, "computeScale: fixed floors at 1")
end

-- ---------------------------------------------------------------------------
print("all scripts compile")
-- loadfile parses without executing, so the display while-loops and peripheral
-- wraps never run. This guards every shipped Lua file against syntax errors.
local luaFiles = {
  "lib/atm10-status.lua", "lib/atm10-draw.lua", "lib/atm10-palette.lua",
  "lib/atm10-control.lua", "lib/atm10-stockplan.lua", "lib/atm10-queue.lua",
  "lib/atm10-craftrunner.lua", "lib/atm10-managed.lua", "lib/atm10-balance.lua",
  "lib/atm10-suggest.lua", "lib/atm10-presets.lua", "lib/atm10-power.lua", "atm10-power.lua",
  "lib/atm10-health.lua", "atm10-health.lua",
  "power-probe.lua",
  "lib/atm10-console.lua", "atm10-console.lua",
  "inventory/manager.lua", "inventory/remote.lua", "inventory/request.lua",
  "inventory-request.lua", "inventory/request-startup.lua", "inventory-request-startup.lua",
  "inventory/config.lua", "inventory/config-example.lua",
  "power/display.lua", "power/probe.lua",
  "atm10-update.lua", "safereboot.lua", "atm10-reload.lua", "atm10-bridge-probe.lua",
  "atm10-target-probe.lua", "atm10-patterns.lua",
  "reboot-guard.lua",
  "inventory/manager-startup.lua", "inventory-startup.lua",
  "inventory/remote-startup.lua", "inventory-remote-startup.lua",
  "power/display-startup.lua", "display-startup.lua",
  "power/probe-startup.lua", "probe-startup.lua",
  "inventory-info.lua", "inventory-remote.lua", "power-display.lua",
  "atm10-status.lua", "atm10-palette.lua", "atm10-control.lua",
  "atm10-draw.lua", "atm10-stockplan.lua", "atm10-queue.lua",
  "atm10-craftrunner.lua", "atm10-managed.lua", "atm10-balance.lua",
  "atm10-suggest.lua", "atm10-presets.lua",
}
for _, f in ipairs(luaFiles) do
  local chunk, err = loadfile(f)
  t.check(chunk ~= nil, "compiles: " .. f .. (chunk and "" or "  (" .. tostring(err) .. ")"))
end

-- ---------------------------------------------------------------------------
print("required-lib guard")
-- A shipped program must require() every lib it uses. loadfile above only parses
-- (an undefined global like `control` is valid syntax), and the program body
-- never runs in these tests, so a missing require would otherwise crash only
-- in-game. This guards the known lib set for the entrypoint programs.
local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then return "" end
  local s = fh:read("*a")
  fh:close()
  return s or ""
end
local requireGuards = {
  ["inventory/manager.lua"] = {
    "atm10-status", "atm10-draw", "atm10-palette", "atm10-stockplan", "atm10-control",
    "atm10-queue", "atm10-craftrunner", "atm10-managed", "atm10-balance",
    "atm10-suggest", "atm10-presets", "atm10-console",
  },
  ["inventory/remote.lua"] = { "atm10-status", "atm10-draw", "atm10-palette", "atm10-console" },
  ["inventory/request.lua"] = { "atm10-status", "atm10-draw", "atm10-palette", "atm10-console", "atm10-control" },
}
for file, libs in pairs(requireGuards) do
  local src = readFile(file)
  for _, lib in ipairs(libs) do
    t.check(src:find('require("' .. lib .. '")', 1, true) ~= nil, file .. " requires " .. lib)
  end
end

-- ---------------------------------------------------------------------------
print("pattern /give emitter (CRAFT-4)")

-- GOLDEN: byte-exact match to the in-world-proven commands. These literals are
-- copied verbatim from the two ~/Downloads give-command files (compress + un-
-- compress) that were pasted live. If any byte of the format drifts (fuzzyMode,
-- left/top, count, bracket nesting, item order) these FAIL -> the test is biting.
local GOLD_LEAD = [[/give @s refinedstorage:pattern[refinedstorage:pattern_state={type:"crafting",id:[I;3001,9003,15005,21007]},refinedstorage:crafting_pattern_state={input:{input:{height:3,width:3,items:[{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1},{id:"alltheores:lead_ingot",count:1}]},left:0,top:0},fuzzyMode:0b}] 1]]
local GOLD_STEEL = [[/give @s refinedstorage:pattern[refinedstorage:pattern_state={type:"crafting",id:[I;3005,9015,15025,21035]},refinedstorage:crafting_pattern_state={input:{input:{height:3,width:3,items:[{id:"alltheores:steel_ingot",count:1},{id:"alltheores:steel_ingot",count:1},{id:"alltheores:steel_ingot",count:1},{id:"alltheores:steel_ingot",count:1},{id:"alltheores:steel_ingot",count:1},{id:"alltheores:steel_ingot",count:1},{id:"alltheores:steel_ingot",count:1},{id:"alltheores:steel_ingot",count:1},{id:"alltheores:steel_ingot",count:1}]},left:0,top:0},fuzzyMode:0b}] 1]]
local GOLD_TIN = [[/give @s refinedstorage:pattern[refinedstorage:pattern_state={type:"crafting",id:[I;80001,80002,80003,80004]},refinedstorage:crafting_pattern_state={input:{input:{height:1,width:1,items:[{id:"alltheores:tin_block",count:1}]},left:0,top:0},fuzzyMode:0b}] 1]]

t.eq(pgive.compressIngotToBlock("alltheores:lead_ingot", { 3001, 9003, 15005, 21007 }), GOLD_LEAD,
  "lead compress give matches proven command")
t.eq(pgive.compressIngotToBlock("alltheores:steel_ingot", { 3005, 9015, 15025, 21035 }), GOLD_STEEL,
  "steel compress give matches proven command")
t.eq(pgive.uncompressBlockToIngots("alltheores:tin_block", { 80001, 80002, 80003, 80004 }), GOLD_TIN,
  "tin uncompress give matches proven command")

-- idQuad: determinism + the default block scheme + distinctness per pattern.
local q1 = pgive.idQuad(1)
t.eq(q1[1], 3001, "idQuad(1)[1]"); t.eq(q1[2], 9003, "idQuad(1)[2]")
t.eq(q1[3], 15005, "idQuad(1)[3]"); t.eq(q1[4], 21007, "idQuad(1)[4]")
local q2 = pgive.idQuad(2)
t.eq(q2[1], 3002, "idQuad(2)[1]"); t.eq(q2[2], 9006, "idQuad(2)[2]")
t.eq(q2[3], 15010, "idQuad(2)[3]"); t.eq(q2[4], 21014, "idQuad(2)[4]")
local seen = {}
local distinct = true
for n = 1, 20 do
  local q = pgive.idQuad(n)
  for i = 1, 4 do
    if seen[q[i]] then distinct = false end
    seen[q[i]] = true
  end
end
t.check(distinct, "idQuad n=1..20 produces 80 distinct ints (no handle collisions)")
-- uncompress scheme reproduces the uncompress-file band (tin n=0 -> 80001..80004).
local qu = pgive.idQuad(0, "uncompress")
t.eq(qu[1], 80001, "uncompress idQuad(0)[1]"); t.eq(qu[4], 80004, "uncompress idQuad(0)[4]")

-- ARITY guard (biting on the no-partial-emit safety rule): 2 items != 3x3.
local bad, badErr = pgive.craftingGive({ items = { "a", "a" }, width = 3, height = 3, id = { 1, 2, 3, 4 } })
t.eq(bad, nil, "craftingGive rejects wrong item count (returns nil)")
t.check(type(badErr) == "string", "craftingGive returns an error string on arity failure")

-- derive: suffix swap pairs ingot<->block; nil when the suffix is absent (no guess).
t.eq(pgive.deriveBlockId("alltheores:lead_ingot"), "alltheores:lead_block", "deriveBlockId lead")
t.eq(pgive.deriveIngotId("alltheores:tin_block"), "alltheores:tin_ingot", "deriveIngotId tin")
t.eq(pgive.deriveBlockId("minecraft:diamond"), nil, "deriveBlockId nil when no _ingot suffix")
t.eq(pgive.deriveIngotId("minecraft:diamond"), nil, "deriveIngotId nil when no _block suffix")
t.eq(pgive.hintForItem("alltheores:lead_block").kind, "crafting", "hintForItem: block is crafting")
t.check(pgive.hintForItem("alltheores:lead_block").derivable == true,
  "hintForItem: block pattern is /give derivable")
t.eq(pgive.hintForItem("alltheores:zinc_dust").kind, "processing", "hintForItem: dust is processing")
t.check(pgive.hintForItem("alltheores:zinc_dust").derivable == false,
  "hintForItem: processing pattern is not /give derivable")
t.eq(pgive.hintForItem("enderio:conductive_alloy_ingot").kind, "processing",
  "hintForItem: alloy ingot stays processing despite _ingot suffix")
t.check(pgive.hintForItem("enderio:conductive_alloy_ingot").text:find("captured reference", 1, true) ~= nil,
  "hintForItem: ingot hint preserves processing-reference warning")
t.eq((pgive.bucketForItem("alltheores:lead_block")), "crafting",
  "bucketForItem: derivable block goes to crafting bucket")
t.eq((pgive.bucketForItem("alltheores:zinc_dust")), "processing",
  "bucketForItem: dust goes to processing bucket")
t.eq((pgive.bucketForItem("minecraft:diamond")), "manual",
  "bucketForItem: unknown recipe goes to manual bucket")

-- emitForItems: derive a compress (block) / uncompress (ingot) /give per item, skip
-- non-derivable ones, with a distinct running idQuad. This is what atm10-patterns
-- prints. Biting: wrong derivation/id/skip changes the command or the count.
local em = pgive.emitForItems({
  { name = "alltheores:tin_block", label = "Tin Block" },
  { name = "alltheores:lead_ingot", label = "Lead Ingot" },
  { name = "enderio:conductive_alloy_ingot", label = "Conductive Alloy" }, -- processing -> skipped
  { name = "minecraft:redstone", label = "Redstone" }, -- not derivable -> skipped
})
t.eq(#em, 2, "emitForItems: derivable block+ingot emitted, processing/manual skipped")
t.eq(em[1].kind, "compress", "emitForItems: *_block -> compress")
t.eq(em[1].command, pgive.compressIngotToBlock("alltheores:tin_ingot", pgive.idQuad(1)),
  "emitForItems: block emits the compress-from-ingot command (derived ingot + id #1)")
t.eq(em[2].kind, "uncompress", "emitForItems: *_ingot -> uncompress")
t.eq(em[2].command, pgive.uncompressBlockToIngots("alltheores:lead_block", pgive.idQuad(2, "uncompress")),
  "emitForItems: ingot emits the uncompress-from-block command (derived block + id #2)")

os.exit(t.summary() and 0 or 1)

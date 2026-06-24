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

-- ---------------------------------------------------------------------------
print("status vocabulary")
t.eq(status.normalize("WOULD CRAFT"), status.WOULD, "WOULD CRAFT -> WOULD")
t.eq(status.normalize("NOT CRAFTABLE"), status.NO_RECIPE, "NOT CRAFTABLE -> NO_RECIPE")
t.eq(status.normalize("ALREADY CRAFTING"), status.CRAFTING, "ALREADY CRAFTING -> CRAFTING")
t.eq(status.normalize("CYCLE CAP"), status.BLOCKED, "CYCLE CAP -> BLOCKED")
t.eq(status.normalize(123), status.UNKNOWN, "non-string -> UNKNOWN")
t.eq(status.normalize("would"), status.WOULD, "lowercase resolves via upper()")
t.check(status.color(status.OK) == colors.green, "OK color is green")
t.check(status.glyph("WOULD CRAFT") == ">", "WOULD glyph is >")
t.eq(status.worst({ "OK", "BLOCKED", "WOULD" }), status.BLOCKED, "worst picks BLOCKED")
t.eq(status.worst({ "OK", "NO_RECIPE", "BLOCKED" }), status.NO_RECIPE, "worst picks NO_RECIPE")
local tally = status.tally({ { action = "WOULD CRAFT" }, { action = "OK" }, { status = "OK" } })
t.eq(tally.WOULD, 1, "tally WOULD = 1")
t.eq(tally.OK, 2, "tally OK = 2")
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

q = cqueue.approve(q, { label = "no name" }, 30) -- missing name -> no-op
t.eq(cqueue.count(q), 1, "approve without a name is a no-op")

q = cqueue.approve(q, { name = "y", request = 16 }, 40)
local listed = cqueue.list(q)
t.eq(listed[1].name, "y", "list is newest-approval first")

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
  { action = "WOULD CRAFT", name = "copper", label = "Copper", key = "compress:copper", request = 9 },
}
local _, an1 = cqueue.autoApprove(aq, autoPlans, 100)
t.eq(an1, 2, "autoApprove approves only WOULD CRAFT rows with a positive request")
t.check(cqueue.has(aq, "iron"), "autoApprove enqueued the refill deficit")
t.check(cqueue.has(aq, "compress:copper"), "autoApprove enqueued the overflow deficit under its compress key")
t.eq(cqueue.has(aq, "gold"), false, "autoApprove skipped the OK row")
t.eq(cqueue.has(aq, "zinc"), false, "autoApprove skipped the zero-request row")

local _, an2 = cqueue.autoApprove(aq, autoPlans, 200)
t.eq(an2, 0, "autoApprove skips entries already APPROVED and waiting")
t.eq(cqueue.get(aq, "iron").approvedAt, 100, "skip leaves the original timestamp untouched")

cqueue.markCrafting(aq, "iron", 150)
local _, an3 = cqueue.autoApprove(aq, autoPlans, 300)
t.eq(an3, 1, "autoApprove re-arms a CRAFTING entry that is WOULD CRAFT again (next batch)")
t.eq(cqueue.get(aq, "iron").state, cqueue.APPROVED, "re-armed entry is APPROVED again")

local _, an4 = cqueue.autoApprove(aq, nil, 400)
t.eq(an4, 0, "autoApprove(nil plans) is a no-op")

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
cqueue.markCrafting(sq, "s", 20)
t.eq(sq.entries.s.state, cqueue.CRAFTING, "markCrafting sets CRAFTING state")
t.eq(sq.entries.s.craftingAt, 20, "markCrafting stamps craftingAt")
cqueue.markError(sq, "s", 30, "boom")
t.eq(sq.entries.s.error, "boom", "markError records the reason")
t.eq(sq.entries.s.triedAt, 30, "markError stamps triedAt for backoff")
cqueue.markCrafting(sq, "absent", 40) -- no-op on a missing entry
t.check(cqueue.has(sq, "absent") == false, "markCrafting on a missing entry is a no-op")

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

-- bridge rejects: stays APPROVED, records error, backs off one cooldown, then retries
local tries = 0
local qf = mkQ({ { name = "f", request = 32 } })
local depsF = { policy = pManualCraft, mode = "manual", now = 1000, cooldownMs = 300000,
  isCrafting = function() return false end,
  craft = function() tries = tries + 1; return false, "missing ingredients" end }
craftrunner.run(qf, depsF)
t.eq(tries, 1, "failed craft is attempted once")
t.eq(qf.entries.f.state, cqueue.APPROVED, "a failed craft stays APPROVED for retry")
t.eq(qf.entries.f.error, "missing ingredients", "failure reason is recorded")
depsF.now = 1000 + 100000
craftrunner.run(qf, depsF)
t.eq(tries, 1, "no retry within the backoff cooldown")
depsF.now = 1000 + 400000
craftrunner.run(qf, depsF)
t.eq(tries, 2, "retries after the backoff cooldown elapses")

-- maxPerCycle caps NEW bridge requests per run; the rest stay APPROVED
local fired = {}
local qcap = mkQ({ { name = "a", request = 1 }, { name = "b", request = 1 }, { name = "c", request = 1 } })
craftrunner.run(qcap, { policy = pManualCraft, mode = "manual", now = 1, maxPerCycle = 2,
  isCrafting = function() return false end,
  craft = function(name) fired[#fired + 1] = name; return true end })
t.eq(#fired, 2, "maxPerCycle=2 fires only two requests this cycle")
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
managed.clearOverflow(os2, "iron")
t.eq(managed.get(os2, "iron").ceiling, nil, "clearOverflow drops the ceiling")
t.eq(#managed.overflowItems(os2), 0, "clearOverflow removes it from overflowItems")

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

-- maxEntries caps the table, dropping the least-recently-seen
local pc = {
  a = { tN = 10 }, b = { tN = 30 }, c = { tN = 20 },
}
local _, capRemoved = suggest.prune(pc, 100, { maxEntries = 2 })
t.eq(capRemoved, 1, "prune drops down to maxEntries")
t.check(pc.a == nil and pc.b ~= nil and pc.c ~= nil, "prune keeps the most-recently-seen entries")

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

-- ---------------------------------------------------------------------------
print("all scripts compile")
-- loadfile parses without executing, so the display while-loops and peripheral
-- wraps never run. This guards every shipped Lua file against syntax errors.
local luaFiles = {
  "lib/atm10-status.lua", "lib/atm10-draw.lua", "lib/atm10-palette.lua",
  "lib/atm10-control.lua", "lib/atm10-stockplan.lua", "lib/atm10-queue.lua",
  "lib/atm10-craftrunner.lua", "lib/atm10-managed.lua", "lib/atm10-balance.lua",
  "lib/atm10-suggest.lua", "lib/atm10-presets.lua",
  "lib/atm10-console.lua", "atm10-console.lua",
  "inventory/manager.lua", "inventory/remote.lua",
  "inventory/config.lua", "inventory/config-example.lua",
  "power/display.lua", "power/probe.lua",
  "atm10-update.lua",
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
}
for file, libs in pairs(requireGuards) do
  local src = readFile(file)
  for _, lib in ipairs(libs) do
    t.check(src:find('require("' .. lib .. '")', 1, true) ~= nil, file .. " requires " .. lib)
  end
end

os.exit(t.summary() and 0 or 1)

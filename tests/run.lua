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

os.exit(t.summary() and 0 or 1)

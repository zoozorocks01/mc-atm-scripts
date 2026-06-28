-- atm10-monitor.lua : health + demand monitoring for the HEALTH dashboard page.
--
-- Pure compute, no peripherals. Takes the manager's EXISTING state snapshots
-- (craft queue, craft results, trend history, plan craftability) and derives the
-- two answers the operator actually wants:
--   (1) "is everything FUNCTIONING?"  -> monitor.craft()
--   (2) "is it KEEPING UP, and what should I go SOURCE?" -> monitor.demand()
--
-- Mirror pair: lib/atm10-monitor.lua == atm10-monitor.lua (byte-identical).

local monitor = {}

local function minutesBetween(a, b)
  local ms = (b or 0) - (a or 0)
  if ms <= 0 then return 0 end
  return ms / 60000
end

-- FUNCTIONING: craft-pipeline health from snapshots the manager already keeps.
--   queueEntries : key -> { state, craftingAt, approvedAt, label, name }  (craftQueue.entries)
--   craftResults : name -> { ok, reason, at }                             (.atm10-craft-results)
--   firedCount   : #crafts fired in the last 60s  (== crafts/min throughput)
--   nowMs, opts { stuckMs = 300000, recentMs = 1800000 }
-- returns { inFlight, stuck = { {label, ageMin}, ... }, recentOk, recentFail, ratePerMin }
-- A CRAFTING entry that has sat past stuckMs with no completion is "stuck" -- RS
-- gives no completion signal, so a healthy in-flight job and a wedged one look
-- identical until you time them; this is that timer.
function monitor.craft(queueEntries, craftResults, firedCount, nowMs, opts)
  opts = opts or {}
  nowMs = nowMs or 0
  local stuckMs = opts.stuckMs or 300000
  local recentMs = opts.recentMs or 1800000
  local out = { inFlight = 0, stuck = {}, recentOk = 0, recentFail = 0, ratePerMin = firedCount or 0 }

  for _, e in pairs(queueEntries or {}) do
    if e.state == "CRAFTING" then
      out.inFlight = out.inFlight + 1
      local age = nowMs - (e.craftingAt or nowMs)
      if age >= stuckMs then
        out.stuck[#out.stuck + 1] = { label = e.label or e.name or "?", ageMin = age / 60000 }
      end
    end
  end

  for _, r in pairs(craftResults or {}) do
    if r.at and (nowMs - r.at) <= recentMs then
      if r.ok then out.recentOk = out.recentOk + 1 else out.recentFail = out.recentFail + 1 end
    end
  end

  table.sort(out.stuck, function(a, b) return a.ageMin > b.ageMin end)
  return out
end

-- KEEPING UP + SOURCE MORE, from the persisted trend windows.
--   trends    : name -> { label, t0, a0, tN, aN, minA, maxA, n }   (.atm10-trends)
--   craftable : name -> bool   (true if the autosystem can make it; from the plan)
--   opts { minPerMin = 20, minWindowMin = 10, minSamples = 4, top = 6 }
-- returns { fallingBehind = { {label, name, perMin, etaMin} }, sourceMore = { ... } }
--   * fallingBehind = declining AND auto-craftable -> the crafting can't keep pace
--     (throughput / starved input) -- fixable inside the system.
--   * sourceMore    = declining AND NOT auto-craftable -> a raw input being drained
--     faster than it arrives -> go mine/farm/produce more (e.g. silver dust, shards).
-- etaMin = current amount / drain rate = rough "time to empty".
function monitor.demand(trends, craftable, opts)
  opts = opts or {}
  local minPerMin = opts.minPerMin or 20
  local minWindowMin = opts.minWindowMin or 10
  local minSamples = opts.minSamples or 4
  local top = opts.top or 6
  craftable = craftable or {}

  local falling, source = {}, {}
  for name, t in pairs(trends or {}) do
    local span = minutesBetween(t.t0, t.tN)
    local decline = (t.a0 or 0) - (t.aN or 0) -- positive => net drained over the window
    if span >= minWindowMin and (t.n or 0) >= minSamples and decline > 0 then
      local perMin = decline / span
      if perMin >= minPerMin then
        local eta = (t.aN and t.aN > 0) and (t.aN / perMin) or 0
        local row = { label = t.label or name, name = name, perMin = perMin, etaMin = eta }
        if craftable[name] then
          falling[#falling + 1] = row
        else
          source[#source + 1] = row
        end
      end
    end
  end

  -- worst first: closest to empty (smallest eta), then biggest drain
  local function bySeverity(a, b)
    if a.etaMin ~= b.etaMin then return a.etaMin < b.etaMin end
    return a.perMin > b.perMin
  end
  table.sort(falling, bySeverity)
  table.sort(source, bySeverity)

  local function trim(list)
    local o = {}
    for i = 1, math.min(top, #list) do o[i] = list[i] end
    return o
  end
  return { fallingBehind = trim(falling), sourceMore = trim(source) }
end

return monitor

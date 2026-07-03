-- atm10-monitor.lua : health + demand monitoring for the HEALTH dashboard page.
--
-- Pure compute, no peripherals. Takes the manager's EXISTING state snapshots
-- (craft queue, craft results, trend history, plan craftability) and derives the
-- two answers the operator actually wants:
--   (1) "is everything FUNCTIONING?"  -> monitor.craft()
--   (2) "is it KEEPING UP, and what should I go SOURCE?" -> monitor.demand()
--   (3) "is the manager loop itself keeping pace?" -> monitor.pace()
--
-- Mirror pair: lib/atm10-monitor.lua == atm10-monitor.lua (byte-identical).

local monitor = {}

local function minutesBetween(a, b)
  local ms = (b or 0) - (a or 0)
  if ms <= 0 then return 0 end
  return ms / 60000
end

-- FUNCTIONING: craft-pipeline health from snapshots the manager already keeps.
--   queueEntries : key -> { state, craftingAt, approvedAt, label, name, kind } (craftQueue.entries)
--   craftResults : name -> { ok, reason, at }                             (.atm10-craft-results)
--   firedCount   : #crafts fired in the last 60s  (== crafts/min throughput)
--   nowMs, opts { stuckMs = 300000, compressStuckMs = 1200000, recentMs = 1800000 }
-- returns { inFlight, stuck = { {label, ageMin}, ... }, recentOk, recentFail, ratePerMin }
-- A CRAFTING entry that has sat past its kind-specific threshold with no
-- completion is "stuck". Refill jobs stay tight; compress jobs are expected
-- to be slower bulk drains.
local function stuckThresholdMs(e, opts)
  if e and e.kind == "compress" then
    return opts.compressStuckMs or opts.bulkStuckMs or 1200000
  end
  return opts.stuckMs or 300000
end

function monitor.craft(queueEntries, craftResults, firedCount, nowMs, opts)
  opts = opts or {}
  nowMs = nowMs or 0
  local recentMs = opts.recentMs or 1800000
  local out = { inFlight = 0, stuck = {}, recentOk = 0, recentFail = 0, ratePerMin = firedCount or 0 }

  for _, e in pairs(queueEntries or {}) do
    if e.state == "CRAFTING" then
      out.inFlight = out.inFlight + 1
      local age = nowMs - (e.craftingAt or nowMs)
      local stuckMs = stuckThresholdMs(e, opts)
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

-- LOOP PACE: health of the manager's own scan/render loop.
--   state : {
--     loopMs, loopGapMs, dataAgeMs, refreshMs, lastError, errors
--   }
-- returns {
--   status = "OK"|"SLOW"|"STALE"|"ERROR", reason, loopSec, gapSec, ageSec,
--   refreshSec, loadPct, errors
-- }
-- A slow loop means scans are eating most/all of the requested refresh window. A
-- stale loop means no successful inventory frame has landed recently. This catches
-- "the program is alive but not keeping up" before it turns into a hard watchdog
-- restart.
function monitor.pace(state, nowMs, opts)
  opts = opts or {}
  state = type(state) == "table" and state or {}
  local refreshMs = tonumber(state.refreshMs) or tonumber(opts.refreshMs) or 5000
  if refreshMs <= 0 then refreshMs = 5000 end
  local loopMs = tonumber(state.loopMs) or 0
  local gapMs = tonumber(state.loopGapMs) or 0
  local ageMs = tonumber(state.dataAgeMs)
  if not ageMs and state.lastOkAt then
    ageMs = math.max(0, (tonumber(nowMs) or 0) - (tonumber(state.lastOkAt) or 0))
  end
  ageMs = ageMs or 0

  local slowMs = tonumber(opts.slowMs) or math.max(refreshMs, 8000)
  local staleMs = tonumber(opts.staleMs) or math.max(refreshMs * 4, 30000)
  local warnLoad = tonumber(opts.warnLoadPct) or 100
  local loadPct = math.floor((loopMs / refreshMs) * 100 + 0.5)
  local status, reason = "OK", "on pace"

  if state.lastError then
    status, reason = "ERROR", tostring(state.lastError)
  elseif ageMs >= staleMs then
    status, reason = "STALE", "no fresh data"
  elseif loopMs >= slowMs or loadPct >= warnLoad then
    status, reason = "SLOW", "scan slow"
  end

  return {
    status = status,
    reason = reason,
    loopSec = loopMs / 1000,
    gapSec = gapMs / 1000,
    ageSec = ageMs / 1000,
    refreshSec = refreshMs / 1000,
    loadPct = loadPct,
    errors = tonumber(state.errors) or 0,
  }
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
  local spikeRatio = opts.spikeRatio or 3 -- swing > spikeRatio*netDrain => transient, ignore
  craftable = craftable or {}
  local skip = opts.skip or {} -- names to exclude entirely (e.g. watch-only / machine-made)

  local falling, source = {}, {}
  for name, t in pairs(trends or {}) do
    if not skip[name] then
      local span = minutesBetween(t.t0, t.tN)
      local decline = (t.a0 or 0) - (t.aN or 0) -- positive => net drained over the window
      if span >= minWindowMin and (t.n or 0) >= minSamples and decline > 0 then
        local perMin = decline / span
        -- Drop transient spikes: if the in-window swing (max-min) dwarfs the NET drain,
        -- the stock bounced (consumed then refilled) rather than steadily declining --
        -- not something to go "source more" of. Kills the v10k/min ~0m noise.
        local swing = (t.maxA or 0) - (t.minA or 0)
        local spiky = swing > spikeRatio * decline
        if perMin >= minPerMin and not spiky then
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
  end

  -- Rank by biggest sustained drain first -- the most actionable "what am I burning
  -- through?" -- with eta shown alongside as the urgency cue.
  local function byDrain(a, b)
    if a.perMin ~= b.perMin then return a.perMin > b.perMin end
    return (a.etaMin or 0) < (b.etaMin or 0)
  end
  table.sort(falling, byDrain)
  table.sort(source, byDrain)

  local function trim(list)
    local o = {}
    for i = 1, math.min(top, #list) do o[i] = list[i] end
    return o
  end
  return { fallingBehind = trim(falling), sourceMore = trim(source) }
end

return monitor

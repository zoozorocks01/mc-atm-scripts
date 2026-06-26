-- Smart-mode suggestion engine. Tracks item amounts over time and proposes
-- recurring quotas for items that keep draining. Pure logic: no peripherals/fs.
-- The manager feeds snapshots each scan and keeps the history in memory.
--
-- OFF BY DEFAULT: the manager only records + analyzes when smart mode is enabled
-- (via the zoozo-late-game profile or a manual toggle), so a generic install does
-- nothing here. Suggestions are advisory — accepting one just opens the normal
-- quota editor, pre-seeded; nothing is auto-applied unless the operator confirms.
local suggest = {}

-- history: { [name] = { label, t0, a0, tN, aN, minA, maxA, n } }
-- record one snapshot. snapshot: array of { name, label, amount }.
function suggest.record(history, snapshot, now)
  history = history or {}
  now = tonumber(now) or 0
  for _, it in ipairs(snapshot or {}) do
    local name = it.name
    if name then
      local amt = tonumber(it.amount) or 0
      local h = history[name]
      if not h then
        history[name] = { label = it.label or name, t0 = now, a0 = amt, tN = now, aN = amt, minA = amt, maxA = amt, n = 1 }
      else
        h.tN = now
        h.aN = amt
        h.n = h.n + 1
        if amt < h.minA then h.minA = amt end
        if amt > (h.maxA or h.a0 or amt) then h.maxA = amt end
        if it.label then h.label = it.label end
      end
    end
  end
  return history
end

-- Bound the (now persisted) history so it neither grows without limit nor lets an
-- item's window stretch over its whole lifetime. Call before saving.
--   maxAgeMs    : drop an entry not seen within this window (item left the grid)
--   maxWindowMs : restart an entry's window (t0/a0/minA/n) once its span exceeds
--                 this, so analyze() measures recent behavior, not all-time drain
--   maxEntries  : hard cap; drop the least-recently-seen beyond it
-- Returns history and the number of entries removed. (0 for any option disables it.)
function suggest.prune(history, now, opts)
  history = history or {}
  opts = opts or {}
  now = tonumber(now) or 0
  local maxAgeMs = tonumber(opts.maxAgeMs) or 0
  local maxWindowMs = tonumber(opts.maxWindowMs) or 0
  local maxEntries = tonumber(opts.maxEntries) or 0
  local removed = 0

  for name, h in pairs(history) do
    if maxAgeMs > 0 and (now - (h.tN or 0)) > maxAgeMs then
      history[name] = nil
      removed = removed + 1
    elseif maxWindowMs > 0 and ((h.tN or 0) - (h.t0 or 0)) > maxWindowMs then
      -- restart the window at the latest sample so drain reflects recent time
      h.t0, h.a0, h.minA, h.maxA, h.n = h.tN or now, h.aN or 0, h.aN or 0, h.aN or 0, 1
    end
  end

  if maxEntries > 0 then
    local arr = {}
    for name, h in pairs(history) do arr[#arr + 1] = { name = name, tN = h.tN or 0, n = h.n or 0 } end
    if #arr > maxEntries then
      -- keep the most-SAMPLED entries (consistently-present items carry the real
      -- drain signal); recency breaks ties. This bounds the persisted file on the
      -- CC computer's ~1MB disk -- a base has thousands of items, only a fraction move.
      table.sort(arr, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.tN > b.tN
      end)
      for i = maxEntries + 1, #arr do
        history[arr[i].name] = nil
        removed = removed + 1
      end
    end
  end

  return history, removed
end

-- A dismissed-set entry is one of: a number (dismissal ts), a legacy boolean `true`, or a
-- rich { ts, baseline } table (CRAFT-6: baseline = abs drain rate, items/min, frozen at
-- dismissal, used to re-surface when drain materially accelerates). These helpers read either
-- field from any shape so analyze() + pruneDismissed stay backward-compatible with old data.
local function dismissedTs(v)
  if type(v) == "number" then return v end
  if type(v) == "table" then return tonumber(v.ts) end
  return nil
end
local function dismissedBaseline(v)
  if type(v) == "table" then return tonumber(v.baseline) end
  return nil
end

-- Bound the operator's dismissed-suggestion set the same way the trend history is
-- bounded: it persists on the same ~1MB CC disk and would otherwise grow forever
-- (each "clear all" only ever ADDS names). Values are dismissal timestamps (or a rich
-- { ts, baseline } table); legacy boolean-true entries are normalized to `now`. Age out
-- entries older than maxAgeMs (drain may have changed -> let the suggestion return) and, if
-- still over maxEntries, drop the OLDEST. The original value shape is PRESERVED on output so
-- a {ts,baseline} survives a prune. Returns a NEW set and the number removed. (0 disables.)
function suggest.pruneDismissed(set, now, opts)
  opts = opts or {}
  now = tonumber(now) or 0
  local maxAgeMs = tonumber(opts.maxAgeMs) or 0
  local maxEntries = tonumber(opts.maxEntries) or 0

  local total, kept = 0, {}
  for name, v in pairs(set or {}) do
    total = total + 1
    local ts = dismissedTs(v)
    if ts == nil then ts, v = now, now end -- legacy boolean `true` -> timestamp (a NUMBER)
    if maxAgeMs <= 0 or (now - ts) <= maxAgeMs then
      kept[#kept + 1] = { name = name, ts = ts, val = v } -- preserve value so a {ts,baseline} survives
    end
  end

  if maxEntries > 0 and #kept > maxEntries then
    table.sort(kept, function(a, b) return a.ts > b.ts end) -- newest first
    for i = #kept, maxEntries + 1, -1 do kept[i] = nil end  -- keep the newest maxEntries
  end

  local out, count = {}, 0
  for _, e in ipairs(kept) do out[e.name] = e.val; count = count + 1 end
  return out, total - count
end

-- VIEW-5: compact per-item trend from the recorded history. Returns
-- { dir = "up"|"down"|"flat", perMin = number } or nil when there's no usable
-- history, so callers HIDE it rather than error (smart mode off / item unseen).
-- up = filling, down = draining. Reuses the same data analyze() already collects --
-- no new bridge calls.
function suggest.trend(history, name, opts)
  local h = history and history[name]
  if type(h) ~= "table" then return nil end
  local span = (tonumber(h.tN) or 0) - (tonumber(h.t0) or 0)
  if span <= 0 then return nil end
  opts = opts or {}
  local flat = tonumber(opts.flatPerMin) or 1
  local delta = (tonumber(h.aN) or 0) - (tonumber(h.a0) or 0)
  local perMin = delta / (span / 60000)
  local dir = "flat"
  if perMin >= flat then dir = "up" elseif perMin <= -flat then dir = "down" end
  return { dir = dir, perMin = perMin }
end

local function mins(span) return math.max(1, math.floor(span / 60000)) end

-- Map a confidence weight (0..1, from analyze) to a compact lo/med/hi bucket for the
-- SMART row + any viewer. Pure + unit-testable so the row text and a future viewer agree.
-- nil/non-number -> nil (caller hides it). Buckets: <0.33 lo, <0.66 med, else hi.
function suggest.confLabel(conf)
  local c = tonumber(conf)
  if not c then return nil end
  if c < 0.33 then return "lo" end
  if c < 0.66 then return "med" end
  return "hi"
end

-- analyze(history, ctx) -> array of suggestions (each seeded for the editor):
--   { kind, name, label, seeded=true, target, craftTo, ceiling?, ratio?, perMin, reason }
-- ctx: { managed = {[name]=true}, quotas = {[name]={target,craftTo}},
--        dismissed = {[name]=ts|true|{ts,baseline}}, minDrain = 64, minWindowMs = 60000,
--        max = 8, cooldownSeconds = 300, compressChains = false, resurfaceFactor = 2 }
--
-- Over a window of >= minWindowMs (skipping a dismissed item unless its drain has materially
-- accelerated past the baseline frozen at dismissal -- see resurfaceFactor):
--   * UNMANAGED + net decline >= minDrain  -> "quota": keep it stocked.
--   * UNMANAGED + net growth  >= minDrain  -> "cap":      set a compress ceiling, OR
--                                            "compress":  (when ctx.compressChains AND it climbed
--                                            past a stable band) seed a full overflow chain
--                                            (floor quota + ceiling + ratio; `into` left for the
--                                            operator -- the denser target can't be derived generically).
--   * MANAGED (has quota) + below target the whole window + still draining
--                                          -> "raise": refill can't keep up.
-- CRAFT-6: a "quota"/"raise"/"compress" craftTo buffers max(minDrain, perMin * cooldownSeconds/60)
-- so the refill lasts one craft cooldown. cooldownSeconds default 300 reproduces the legacy *5.
function suggest.analyze(history, ctx)
  ctx = ctx or {}
  local managedSet = ctx.managed or {}
  local quotas = ctx.quotas or {}
  local dismissed = ctx.dismissed or {}
  local minDrain = tonumber(ctx.minDrain) or 64
  local minWindow = tonumber(ctx.minWindowMs) or 60000
  local cooldownSec = tonumber(ctx.cooldownSeconds) or 300 -- 300/60 = 5 => byte-identical to the old *5
  local compressChains = ctx.compressChains == true        -- opt-in: promote a band-climb to "compress"
  local resurfaceFactor = tonumber(ctx.resurfaceFactor) or 2

  -- confidence weight: an item observed over many samples across a long span carries a
  -- more trustworthy drain signal than one seen twice 60s apart that happened to dip. We
  -- weight _rank by conf so thin/short evidence is DEMOTED but never zeroed (a high-drain
  -- item still ranks, just below an equally-declining well-observed one). conf in [0,1].
  local confK = tonumber(ctx.confSamples) or 5            -- samples for full sample-confidence
  local idealWindow = tonumber(ctx.confIdealWindowMs) or (minWindow * 4)

  local out = {}
  for name, h in pairs(history or {}) do
    local span = (h.tN or 0) - (h.t0 or 0)
    if span >= minWindow then
      local decline = (h.a0 or 0) - (h.aN or 0)
      local perMin = math.abs(decline) / (span / 60000)
      -- conf = (sample-count confidence) * (window-span confidence), each capped at 1.
      local nConf = math.min(1, ((h.n or 1) - 1) / (confK > 0 and confK or 1))
      local spanConf = idealWindow > 0 and math.min(1, span / idealWindow) or 1
      local conf = nConf * spanConf
      -- spiky: the intra-window swing (maxA-minA) dwarfs the net move, so the item
      -- refilled then dipped (self-replenishing) rather than steadily draining. Endpoint
      -- decline is blind to this; damp confidence so a spiky item is demoted vs a monotone
      -- drainer of equal net decline. maxA defaults to aN for pre-maxA persisted entries.
      local maxA = h.maxA or h.aN or 0
      local minA = h.minA or h.aN or 0
      local swing = maxA - minA
      local spiky = swing > 2 * math.abs(decline)
      if spiky then conf = conf * 0.5 end
      local confW = 0.5 + 0.5 * conf  -- never below 0.5: thin evidence is demoted, not erased
      -- a dismissed item stays suppressed UNLESS drain has materially accelerated past the
      -- baseline recorded at dismissal; legacy/no-baseline entries never re-surface this way.
      local dv = dismissed[name]
      local suppressed = dv ~= nil
      if suppressed then
        local base = dismissedBaseline(dv)
        if base and base > 0 and resurfaceFactor > 0 and perMin >= resurfaceFactor * base then
          suppressed = false
        end
      end
      if not suppressed then
        local q = quotas[name]
        local isManaged = managedSet[name] == true or q ~= nil
        local buffer = math.max(minDrain, math.floor(perMin * (cooldownSec / 60)))

        if not isManaged and decline >= minDrain then
          local target = math.max(0, math.floor(h.minA or 0))
          out[#out + 1] = {
            kind = "quota", name = name, label = h.label or name, seeded = true,
            target = target, craftTo = target + buffer, perMin = perMin, conf = conf, spiky = spiky,
            reason = "down " .. decline .. " in " .. mins(span) .. "m", _rank = decline * confW,
          }
        elseif not isManaged and -decline >= minDrain then
          if compressChains and ((h.aN or 0) - (h.minA or 0)) >= minDrain then
            -- climbed past a stable band: seed a full compress chain. `into` is intentionally
            -- nil (no generic way to pick the denser item); until the operator sets INTO,
            -- managed.set keeps the ceiling inert and the row is just a low refill quota
            -- (target..craftTo), so the seed is never invalid/partial.
            local target = math.max(0, math.floor(h.minA or 0))
            -- seed the ceiling above the observed PEAK (maxA), not just the last sample, so a
            -- mid-window high doesn't get clipped below the true band top. maxA>=aN always.
            local ceiling = math.max(target + 1, math.floor(math.max(h.aN or 0, maxA))) -- band climb => >=target+minDrain
            out[#out + 1] = {
              kind = "compress", name = name, label = h.label or name, seeded = true,
              target = target, ceiling = ceiling, ratio = 1, perMin = perMin, conf = conf, spiky = spiky,
              -- the cooldown buffer is sized off the GROWTH rate (unrelated to the band height),
              -- so clamp the refill floor strictly below the cap: target < craftTo < ceiling.
              craftTo = math.max(target + 1, math.min(target + buffer, ceiling - 1)),
              reason = "up " .. (-decline) .. " in " .. mins(span) .. "m, past band", _rank = (-decline) * confW,
            }
          else
            out[#out + 1] = {
              kind = "cap", name = name, label = h.label or name, seeded = true,
              target = 0, craftTo = 0, ceiling = math.max(0, math.floor(math.max(h.aN or 0, maxA))), perMin = perMin, conf = conf, spiky = spiky,
              reason = "up " .. (-decline) .. " in " .. mins(span) .. "m", _rank = (-decline) * confW,
            }
          end
        elseif q and decline >= minDrain
            and (h.aN or 0) < (q.target or 0) and (h.a0 or 0) < (q.target or 0) then
          local proposed = (q.target or 0) + buffer
          if proposed > (q.craftTo or 0) then
            out[#out + 1] = {
              kind = "raise", name = name, label = h.label or name, seeded = true,
              target = q.target, craftTo = proposed, perMin = perMin, conf = conf, spiky = spiky,
              reason = "below target, still draining", _rank = decline * confW,
            }
          end
        end
      end
    end
  end

  table.sort(out, function(a, b)
    if a._rank ~= b._rank then return a._rank > b._rank end
    return tostring(a.name) < tostring(b.name)
  end)

  local max = tonumber(ctx.max) or 8
  while #out > max do table.remove(out) end
  for _, s in ipairs(out) do s._rank = nil end
  return out
end

return suggest

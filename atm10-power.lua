-- Pure power-math helpers shared by the power probe + display. No peripherals, no
-- colors -- so the load-bearing FE/duration/percent/net conversions are unit-tested
-- off-CC (QUICK-2). The display maps the returned state strings to colors; the probe
-- feeds raw port readings into percent().
local power = {}

-- Format an energy value with an FE magnitude suffix. Keeps sign on negatives
-- (net flow can be negative).
function power.fmt(n)
  n = tonumber(n) or 0
  local a = math.abs(n)
  if a >= 1000000000000 then return string.format("%.2f TFE", n / 1000000000000) end
  if a >= 1000000000 then return string.format("%.2f GFE", n / 1000000000) end
  if a >= 1000000 then return string.format("%.2f MFE", n / 1000000) end
  if a >= 1000 then return string.format("%.1f kFE", n / 1000) end
  return tostring(math.floor(n)) .. " FE"
end

-- Human duration from seconds (s / m / h / d).
function power.fmtDuration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  if seconds >= 86400 then return string.format("%.1fd", seconds / 86400) end
  if seconds >= 3600 then return string.format("%.1fh", seconds / 3600) end
  if seconds >= 60 then return string.format("%dm", math.floor(seconds / 60)) end
  return tostring(seconds) .. "s"
end

-- Time-to-full / time-to-empty from a per-TICK net (net is FE/t; /20 converts the
-- FE/t rate to FE/s before dividing into the FE gap). Returns (text, state) where
-- state is "stable" | "empty" | "full" -- the caller picks a color.
function power.estimateTime(energy, maxEnergy, net)
  energy = tonumber(energy) or 0
  maxEnergy = tonumber(maxEnergy) or 0
  net = tonumber(net) or 0

  if math.abs(net) < 1 then return "Time: stable", "stable" end
  if net < 0 then return "Empty in " .. power.fmtDuration(energy / math.abs(net) / 20), "empty" end
  return "Full in  " .. power.fmtDuration((maxEnergy - energy) / net / 20), "full"
end

-- Pick the trustworthy net: the induction matrix's reported input-output, unless
-- BOTH are zero (matrix idle / reporting nothing) and we have a meaningful sampled
-- delta, in which case fall back to the estimate. Returns (net, source).
function power.effectiveNet(sample)
  sample = sample or {}
  local input = tonumber(sample.input) or 0
  local output = tonumber(sample.output) or 0
  local reported = tonumber(sample.reportedNet) or (input - output)
  local estimated = tonumber(sample.estimatedNet) or 0

  if input == 0 and output == 0 and math.abs(estimated) > 1 then
    return estimated, "estimated"
  end
  return reported, "reported"
end

-- Normalize a fill percentage to 0-100. rawPct may be a 0-1 fraction or an already
-- 0-100 value (peripheral builds vary); if it's unusable, fall back to
-- energy/maxEnergy. maxEnergy <= 0 yields 0 (no divide-by-zero).
function power.percent(rawPct, energy, maxEnergy)
  local p = tonumber(rawPct) or 0
  if p > 0 and p <= 1 then return p * 100 end
  if p > 1 and p <= 100 then return p end

  energy = tonumber(energy) or 0
  maxEnergy = tonumber(maxEnergy) or 0
  if maxEnergy > 0 then return (energy / maxEnergy) * 100 end
  return 0
end

-- QUICK-1: percentage of the induction matrix's per-tick transfer cap a given input/output
-- rate is using (a throughput-headroom readout -- how close the matrix is to its transfer
-- limit). Returns nil when the cap is unknown / <= 0 so the display HIDES the readout rather
-- than dividing by zero or showing a meaningless 0%. May exceed 100 (a real over-cap anomaly
-- shows rather than being clamped away).
function power.headroom(used, cap)
  used = tonumber(used) or 0
  cap = tonumber(cap) or 0
  if cap <= 0 then return nil end
  return math.max(0, (used / cap) * 100)
end

-- QUICK-3: latching alarm decision with a recovery DEADBAND so it does not chatter at the
-- threshold. The alarm FIRES once on the rising edge into an alarming status and stays latched
-- (active) until the status fully RECOVERS to a healthy one -- statuses in between (e.g. LOW,
-- which sits in the 15-35% band right next to CRITICAL) HOLD the latch, so pct jitter across
-- the CRITICAL line does not re-fire. Defaults: alarm on CRITICAL/STALE; clear on OK/DRAINING
-- (both pct >= the LOW band, i.e. genuinely recovered). Pure: the caller drives the
-- redstone/speaker and persists `active` across frames. Returns (fire, active).
function power.alarmDecision(status, active, opts)
  opts = opts or {}
  local alarmStates = opts.states or { ["CRITICAL"] = true, ["STALE DATA"] = true, ["STALE"] = true }
  local clearStates = opts.clearStates or { ["OK"] = true, ["DRAINING"] = true }
  active = active == true
  if alarmStates[status] then
    local fire = not active           -- rising edge: fire once on entry
    return fire, true                 -- latch on
  elseif clearStates[status] then
    return false, false               -- recovered: re-arm
  end
  return false, active                -- in-between (e.g. LOW): hold the latch, no re-fire
end

-- POWER-GRAPH: downsample a raw sample series into exactly `width` buckets so the WHOLE
-- history window is shown in a narrow graph instead of silently dropping older samples off
-- the left edge. Each output bucket is {min,max,avg,last,n}: min/max give a volatility RANGE
-- the renderer can draw as a vertical bar (a real sparkline), avg/last are point summaries,
-- n is how many raw samples fell in the bucket (0 = empty bucket, renderer draws nothing).
-- Samples are partitioned contiguously oldest->newest; if there are fewer samples than width,
-- trailing buckets are empty (n=0) and the data sits at the LEFT, preserving chronological
-- order. Pure -> unit-tested. Returns {} for width<=0 or no values.
function power.downsample(values, width)
  values = values or {}
  width = math.floor(tonumber(width) or 0)
  local out = {}
  if width <= 0 then return out end

  local total = #values
  for b = 1, width do
    out[b] = { min = 0, max = 0, avg = 0, last = 0, n = 0 }
  end
  if total == 0 then return out end

  -- Assign each raw sample (index 1..total, oldest->newest) to a bucket 1..width so the
  -- buckets are contiguous and ordered. When total < width, each sample maps to its own
  -- early bucket (b = i), leaving later buckets empty. When total >= width, samples are
  -- spread evenly across all buckets.
  for i = 1, total do
    local v = tonumber(values[i]) or 0
    local b
    if total <= width then
      b = i
    else
      b = math.floor((i - 1) * width / total) + 1
      if b > width then b = width end
    end
    local bk = out[b]
    if bk.n == 0 then
      bk.min = v
      bk.max = v
      bk.avg = v
      bk.last = v
      bk.n = 1
    else
      if v < bk.min then bk.min = v end
      if v > bk.max then bk.max = v end
      bk.avg = bk.avg + v        -- accumulate; divide once below
      bk.last = v
      bk.n = bk.n + 1
    end
  end
  for b = 1, width do
    local bk = out[b]
    if bk.n > 1 then bk.avg = bk.avg / bk.n end
  end
  return out
end

-- POWER-GRAPH: select the last `windowSeconds` of a 1-sample-per-(1/sampleHz)s series and
-- downsample that slice into `columns` buckets. The probe emits ~1 sample/s (sampleHz~=1), so
-- history index ~= seconds-ago; this gives 1m / 10m / 1h windows from the SAME ring buffer
-- (provided the buffer is long enough to hold the window -- a 1h window needs ~3600 samples).
-- sampleHz is samples-per-second (default 1). Pure -> unit-tested (slice picks the correct
-- tail, then downsample() does the bucketing). Returns {} for bad args.
function power.bucketByTimeframe(values, windowSeconds, columns, sampleHz)
  values = values or {}
  windowSeconds = tonumber(windowSeconds) or 0
  columns = math.floor(tonumber(columns) or 0)
  sampleHz = tonumber(sampleHz) or 1
  if columns <= 0 then return {} end
  if windowSeconds <= 0 or sampleHz <= 0 then
    return power.downsample(values, columns)
  end

  local wantSamples = math.floor(windowSeconds * sampleHz)
  if wantSamples < 1 then wantSamples = 1 end

  local total = #values
  local startIdx = total - wantSamples + 1
  if startIdx < 1 then startIdx = 1 end

  local slice = {}
  for i = startIdx, total do
    slice[#slice + 1] = values[i]
  end
  return power.downsample(slice, columns)
end

-- POWER-GRAPH: pick a y-axis maximum so the graph can stop jumping every frame. mode 'fixed'
-- pins the scale to the caller's `fixedMax` (operator-chosen, ignores the data peak) so a
-- transient spike does not rescale everything; mode 'auto' (default) tracks max(abs(value))
-- so the graph fills the height. Both floor at 1 to avoid a divide-by-zero / flat graph when
-- everything is ~0. Pure -> unit-tested. Returns a positive number.
function power.computeScale(values, mode, fixedMax)
  if mode == "fixed" then
    local m = tonumber(fixedMax) or 0
    return math.max(1, m)
  end
  values = values or {}
  local maxAbs = 1
  for i = 1, #values do
    local v = tonumber(values[i])
    if v then maxAbs = math.max(maxAbs, math.abs(v)) end
  end
  return maxAbs
end

return power

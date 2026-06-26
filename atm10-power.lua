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

return power

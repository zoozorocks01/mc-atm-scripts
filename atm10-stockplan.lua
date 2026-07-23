-- Dry-run stock keeper planner. Pure logic: no peripherals, no fs, no rednet.
-- The caller supplies current stock through ctx.resolve, which is why this can
-- be unit-tested off the in-game runtime (see tests/run.lua).
--
-- This NEVER crafts. It only classifies each managed item into a plan row.
local stockplan = {}

local function floorNumber(value, fallback)
  local n = tonumber(value)
  if not n then return fallback end
  return math.floor(n)
end

function stockplan.deficitPriority(amount, target)
  amount = tonumber(amount) or 0
  target = tonumber(target) or 0
  if target <= 0 then return 0 end
  return math.max(0, (target - amount) / target)
end

function stockplan.effectiveCraftTo(target, stock)
  target = target or {}
  stock = stock or {}

  -- Exact numbers: craftTo is exactly what the operator set. One number => refill to
  -- that floor; set a higher craftTo for a min->max buffer. No auto-band, no rounding
  -- (matches how RS/AE2 level emitters + keep-stock scripts work). Cooldown limits
  -- re-craft frequency; overflow stacks extra above the floor.
  local trigger = math.max(0, floorNumber(target.target, 0))
  local craftTo = math.max(trigger, 1, floorNumber(target.craftTo, trigger))

  local meta = {
    craftTo = craftTo,
    configuredCraftTo = craftTo,
    banded = false,
  }

  local ceiling = tonumber(target.ceiling)
  if ceiling and ceiling > 0 and type(target.into) == "table" and target.into.name then
    local maxCraftTo = math.floor(ceiling) - 1
    if maxCraftTo < trigger then
      meta.blocked = true
      meta.reason = "ceiling must be greater than target"
      meta.ceiling = math.floor(ceiling)
    elseif craftTo > maxCraftTo then
      meta.craftTo = maxCraftTo
      meta.adjusted = true
      meta.reason = "craftTo lowered below ceiling"
    end
  end

  return meta.craftTo, meta
end

local function copyMeta(row, meta)
  if not meta then return row end
  row.configuredCraftTo = meta.configuredCraftTo
  row.banded = meta.banded == true
  row.adjusted = meta.adjusted == true
  if meta.reason ~= nil then row.reason = meta.reason end
  row.ceiling = meta.ceiling
  return row
end

local function isWatchOnly(target)
  target = target or {}
  local mode = tostring(target.craftMode or ""):lower()
  return mode == "watch" or mode == "manual" or mode == "machine" or target.autocraft == false
end

local function watchReason(target)
  target = target or {}
  return target.blockReason or target.reason or "watch-only target; no RS craft request"
end

local function compressionPairSpecs(stock)
  stock = stock or {}
  local categories = stock.categories or {}
  if #categories == 0 and type(stock.items) == "table" then
    categories = { { label = "Stock Keeper", items = stock.items } }
  end

  local byName, order = {}, {}
  for _, category in ipairs(categories) do
    for _, target in ipairs(category.items or {}) do
      if target and target.name and not byName[target.name] then
        byName[target.name] = target
        order[#order + 1] = target.name
      end
    end
  end

  local specs = {}
  for _, name in ipairs(order) do
    local source = byName[name]
    local into = source and source.into
    local dense = into and into.name and byName[into.name] or nil
    if dense then
      specs[#specs + 1] = {
        source = source.name,
        dense = dense.name,
        sourceLabel = source.label or source.name,
        denseLabel = dense.label or dense.name,
      }
    end
  end
  return specs
end

local function blockCompressionPair(row, spec)
  row.action = "BLOCKED"
  row.request = nil
  row.capped = nil
  row.reserveCapped = nil
  row.reason = "compression pair low: " .. tostring(spec.sourceLabel) .. " and " .. tostring(spec.denseLabel)
  row.conflictWith = (row.name == spec.source) and spec.dense or spec.source
  return row
end

local function applyCompressionPairGuards(plans, specs, amounts, targets)
  if type(plans) ~= "table" or type(specs) ~= "table" then return plans end
  for _, spec in ipairs(specs) do
    local sourceTarget, denseTarget = tonumber(targets[spec.source]), tonumber(targets[spec.dense])
    if sourceTarget and denseTarget then
      local sourceAmount = tonumber(amounts[spec.source]) or 0
      local denseAmount = tonumber(amounts[spec.dense]) or 0
      if sourceAmount < sourceTarget and denseAmount < denseTarget then
        for _, row in ipairs(plans) do
          if row.action == "WOULD CRAFT" and (row.name == spec.source or row.name == spec.dense) then
            blockCompressionPair(row, spec)
          end
        end
      end
    end
  end
  return plans
end

function stockplan.compressionPairHold(stockKeeper, resolve, name)
  if not name then return nil end
  resolve = resolve or function() return 0 end
  local targetByName = {}
  local categories = (stockKeeper or {}).categories or {}
  if #categories == 0 and type((stockKeeper or {}).items) == "table" then
    categories = { { items = stockKeeper.items } }
  end
  for _, category in ipairs(categories) do
    for _, target in ipairs(category.items or {}) do
      if target.name then targetByName[target.name] = tonumber(target.target) or 0 end
    end
  end

  for _, spec in ipairs(compressionPairSpecs(stockKeeper)) do
    if name == spec.source or name == spec.dense then
      local sourceTarget = targetByName[spec.source]
      local denseTarget = targetByName[spec.dense]
      if sourceTarget and denseTarget then
        local sourceAmount = tonumber((resolve(spec.source))) or 0
        local denseAmount = tonumber((resolve(spec.dense))) or 0
        if sourceAmount < sourceTarget and denseAmount < denseTarget then
          return "compression pair low: " .. tostring(spec.sourceLabel) .. " and " .. tostring(spec.denseLabel),
            (name == spec.source) and spec.dense or spec.source
        end
      end
    end
  end
  return nil
end

local function compactPlanRow(row)
  return {
    action = row.action,
    name = row.name,
    label = row.label,
    category = row.category,
    amount = row.amount,
    target = row.target,
    craftTo = row.craftTo,
    request = row.request,
    priority = row.priority,
    reason = row.reason,
    conflictWith = row.conflictWith,
  }
end

-- Compact, bounded snapshot for SSH diagnostics. The full plan is already rendered
-- on the monitor and broadcast to viewers; this keeps just enough of the non-OK
-- plan to explain why the manager is waiting, blocked, capped, or about to craft.
function stockplan.compactState(plans, opts)
  opts = opts or {}
  local limit = math.max(0, math.floor(tonumber(opts.limit) or 40))
  local out = {
    total = 0,
    omitted = 0,
    counts = {},
    wouldCraftCount = 0,
    wouldCraftAmount = 0,
    blockedCount = 0,
    unknownIdCount = 0,
    rows = {},
  }

  for _, row in ipairs(plans or {}) do
    local action = tostring(row.action or "?")
    out.total = out.total + 1
    out.counts[action] = (out.counts[action] or 0) + 1
    if action == "WOULD CRAFT" then
      out.wouldCraftCount = out.wouldCraftCount + 1
      out.wouldCraftAmount = out.wouldCraftAmount + (tonumber(row.request) or 0)
    elseif action == "UNKNOWN-ID" then
      out.unknownIdCount = out.unknownIdCount + 1
    elseif action == "BLOCKED" or action == "NO RECIPE" or action == "RESERVED" then
      out.blockedCount = out.blockedCount + 1
    end
    if action ~= "OK" then
      if #out.rows < limit then
        out.rows[#out.rows + 1] = compactPlanRow(row)
      else
        out.omitted = out.omitted + 1
      end
    end
  end

  return out
end

-- ctx fields:
--   stockKeeper : {
--     enabled, cooldownSeconds, maxCraftsPerCycle, maxRequest, maxBatch,
--     refillMarginRatio, minRefillMargin,
--     categories = { { label, items = { { name, label, target, craftTo, maxRequest, maxBatch } } } },
--     items = { ... }   -- used only when categories is empty
--   }
--   now         : current time in ms (wall clock; the ledger persists it across reboots)
--   ledger      : { requests = { [name] = { requestedAt = <ms> } } }  (a table when present)
--   ledgerError : string surfaced when ledger is nil (fail closed: plan nothing)
--   drain       : { [name] = perMin } measured consumption for drain-aware batch
--                 sizing (optional; absent => base cap only). See DECISIONS #6.
--   resolve     : function(name) -> amount (number), craftable (bool), crafting (bool), exists (bool|nil)
--
-- Returns an array of plan rows. Each row has an `action`, one of:
--   OK, NOT CRAFTABLE, ALREADY CRAFTING, ON COOLDOWN, CYCLE CAP, WOULD CRAFT,
--   BLOCKED, RESERVED.
-- Deficit rows carry `priority` (larger = farther below the floor), so the
-- queue/runner can fire the most-deficient items first under a per-cycle cap.
function stockplan.plan(ctx)
  ctx = ctx or {}
  local plans = {}
  local stock = ctx.stockKeeper or {}

  if stock.enabled ~= true then
    return plans
  end

  local ledger = ctx.ledger
  if not ledger then
    plans[#plans + 1] = { action = "BLOCKED", label = "Ledger", reason = ctx.ledgerError or "ledger unavailable" }
    return plans
  end

  local resolve = ctx.resolve or function() return 0, false, false end
  local now = tonumber(ctx.now) or 0
  local cooldownMs = (tonumber(stock.cooldownSeconds) or 300) * 1000
  local cycleLimit = tonumber(stock.maxCraftsPerCycle) or 2
  -- Measured drain per item (units/min), keyed by registry name. Optional: the
  -- caller derives it from the persisted trend window (monitor.drainRate); absent
  -- => drain-aware sizing is off and every request uses the base cap. See DECISIONS #6.
  local drainByName = ctx.drain or {}
  local wouldIndexes = {}
  local amounts, targets = {}, {}

  local categories = stock.categories or {}
  if #categories == 0 and type(stock.items) == "table" then
    categories = { { label = "Stock Keeper", items = stock.items } }
  end
  local pairSpecs = compressionPairSpecs({ categories = categories })

  for _, category in ipairs(categories) do
    local categoryLabel = category.label or "Stock Keeper"
    for _, target in ipairs(category.items or {}) do
      local amount, craftable, crafting, exists = resolve(target.name)
      amount = tonumber(amount) or 0
      local label = target.label or target.name
      local trigger = tonumber(target.target) or 0
      local craftTo, craftMeta = stockplan.effectiveCraftTo(target, stock)
      local maxRequest = tonumber(target.maxRequest) or tonumber(stock.maxRequest) or 4096
      -- Drain-aware ceiling: the highest a single turn's request may grow to for a
      -- high-drain item. Opt-in (per-item, else global); nil => base cap only.
      local maxBatch = tonumber(target.maxBatch) or tonumber(stock.maxBatch)
      local priority = stockplan.deficitPriority(amount, trigger)
      amounts[target.name] = amount
      targets[target.name] = trigger

      if exists == false and not craftable then
        plans[#plans + 1] = copyMeta({ action = "UNKNOWN-ID", name = target.name, category = categoryLabel,
          label = label, amount = amount, target = trigger, craftTo = craftTo, priority = priority,
          reason = "not present in live RS item grid" }, craftMeta)
      elseif amount >= trigger then
        plans[#plans + 1] = copyMeta({ action = "OK", name = target.name, category = categoryLabel,
          label = label, amount = amount, target = trigger, priority = 0 }, craftMeta)
      elseif craftMeta.blocked then
        plans[#plans + 1] = copyMeta({ action = "BLOCKED", name = target.name, category = categoryLabel,
          label = label, amount = amount, target = trigger, craftTo = craftTo, priority = priority }, craftMeta)
      elseif isWatchOnly(target) then
        plans[#plans + 1] = copyMeta({ action = "BLOCKED", name = target.name, category = categoryLabel,
          label = label, amount = amount, target = trigger, craftTo = craftTo, priority = priority,
          reason = watchReason(target), craftMode = target.craftMode or "watch" }, craftMeta)
      elseif not craftable then
        plans[#plans + 1] = copyMeta({ action = "NOT CRAFTABLE", name = target.name, category = categoryLabel,
          label = label, amount = amount, target = trigger, craftTo = craftTo, priority = priority }, craftMeta)
      elseif crafting then
        plans[#plans + 1] = copyMeta({ action = "ALREADY CRAFTING", name = target.name, category = categoryLabel,
          label = label, amount = amount, target = trigger, craftTo = craftTo, priority = priority }, craftMeta)
      else
        local record = ledger.requests[target.name]
        local age = record and record.requestedAt and (now - record.requestedAt) or nil

        if record and age and age < cooldownMs then
          plans[#plans + 1] = copyMeta({
            action = "ON COOLDOWN",
            name = target.name,
            category = categoryLabel,
            label = label,
            amount = amount,
            target = trigger,
            craftTo = craftTo,
            priority = priority,
            secondsLeft = math.ceil((cooldownMs - age) / 1000),
          }, craftMeta)
        else
          local deficit = math.max(0, craftTo - amount)

          -- Per-turn batch cap. The base is maxRequest (unchanged; 4096 default).
          -- DRAIN-AWARE SIZING (DECISIONS #6): a high-drain item capped at the base
          -- batch can be consumed faster than one turn replenishes, so its deficit
          -- never closes (live 2026-07-22: gold 18,776/100,000, 4096/turn lost to a
          -- Dyson-swarm chain). When a sustained drain is MEASURED and a higher
          -- maxBatch ceiling is configured, raise THIS turn's cap to cover the drain
          -- expected before the item can be re-requested (~one cooldown) plus one
          -- base batch of headway, bounded by maxBatch. The request never exceeds the
          -- deficit (craftTo ceiling holds) and the input reserve below still clamps
          -- it; only the ceiling on one turn's ask changes.
          local cap = maxRequest
          local perMin = tonumber(drainByName[target.name]) or 0
          if perMin > 0 and maxBatch and maxBatch > maxRequest then
            local drainPerCooldown = math.floor(perMin * (cooldownMs / 60000))
            local drainCap = maxRequest + drainPerCooldown
            cap = math.max(maxRequest, math.min(maxBatch, drainCap))
          end

          local request = deficit
          local capped = false
          if request > cap then
            request = cap
            capped = true
          end

          -- Input reserve (craftFrom): never let a craft draw its SOURCE item below
          -- a kept floor -- e.g. keep 1k metal dust for alloys and only smelt the
          -- surplus into ingots. craftFrom = { name, reserve, ratio }. The source's
          -- live amount comes from resolve(); each output unit consumes `ratio` of
          -- it. If the whole request is held, the row is RESERVED (informational,
          -- never fired) so the operator sees WHY it isn't crafting.
          local reserveHeld = false
          local cf = target.craftFrom
          if type(cf) == "table" and cf.name then
            local inputAmount = tonumber((resolve(cf.name))) or 0
            local ratio = math.max(1, floorNumber(cf.ratio, 1))
            local reserve = math.max(0, floorNumber(cf.reserve, 0))
            local maxByInput = math.max(0, math.floor((inputAmount - reserve) / ratio))
            if request > maxByInput then
              request = maxByInput
              reserveHeld = true
            end
          end

          if reserveHeld and request <= 0 then
            plans[#plans + 1] = copyMeta({
              action = "RESERVED",
              name = target.name,
              category = categoryLabel,
              label = label,
              amount = amount,
              target = trigger,
              craftTo = craftTo,
              priority = priority,
              reason = "keeping " .. tostring(cf.name) .. " reserve",
            }, craftMeta)
          else
            local row = copyMeta({
              action = "WOULD CRAFT",
              name = target.name,
              category = categoryLabel,
              label = label,
              amount = amount,
              target = trigger,
              craftTo = craftTo,
              priority = priority,
              request = request,
              capped = capped,
              reserveCapped = reserveHeld,
            }, craftMeta)
            plans[#plans + 1] = row
            wouldIndexes[#wouldIndexes + 1] = #plans
          end
        end
      end
    end
  end

  applyCompressionPairGuards(plans, pairSpecs, amounts, targets)
  do
    local activeWould = {}
    for _, idx in ipairs(wouldIndexes) do
      if plans[idx].action == "WOULD CRAFT" then activeWould[#activeWould + 1] = idx end
    end
    wouldIndexes = activeWould
  end

  if cycleLimit ~= math.huge and #wouldIndexes > cycleLimit then
    table.sort(wouldIndexes, function(a, b)
      local pa, pb = plans[a], plans[b]
      local ua, ub = tonumber(pa.priority) or 0, tonumber(pb.priority) or 0
      if ua ~= ub then return ua > ub end
      return a < b
    end)
    local allowed = {}
    for i = 1, math.max(0, cycleLimit) do
      if wouldIndexes[i] then allowed[wouldIndexes[i]] = true end
    end
    for _, idx in ipairs(wouldIndexes) do
      if plans[idx].action == "WOULD CRAFT" and not allowed[idx] then
        local row = plans[idx]
        row.action = "CYCLE CAP"
        row.request = nil
        row.capped = nil
      end
    end
  end

  return plans
end

return stockplan

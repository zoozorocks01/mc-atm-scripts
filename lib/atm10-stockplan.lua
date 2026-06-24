-- Dry-run stock keeper planner. Pure logic: no peripherals, no fs, no rednet.
-- The caller supplies current stock through ctx.resolve, which is why this can
-- be unit-tested off the in-game runtime (see tests/run.lua).
--
-- This NEVER crafts. It only classifies each managed item into a plan row.
local stockplan = {}

local DEFAULT_REFILL_MARGIN_RATIO = 0.25
local DEFAULT_MIN_REFILL_MARGIN = 4

local function floorNumber(value, fallback)
  local n = tonumber(value)
  if not n then return fallback end
  return math.floor(n)
end

local function positiveNumber(value, fallback)
  local n = tonumber(value)
  if not n or n <= 0 then return fallback end
  return n
end

local function refillMargin(target, stock)
  local ratio = positiveNumber(target.refillMarginRatio, positiveNumber(stock.refillMarginRatio, DEFAULT_REFILL_MARGIN_RATIO))
  local minMargin = math.max(1, floorNumber(target.minRefillMargin,
    floorNumber(stock.minRefillMargin, DEFAULT_MIN_REFILL_MARGIN)))
  return math.max(minMargin, math.ceil((tonumber(target.target) or 0) * ratio))
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

  local trigger = math.max(0, floorNumber(target.target, 0))
  local configuredCraftTo = math.max(trigger, 1, floorNumber(target.craftTo, trigger))
  local craftTo = configuredCraftTo
  local banded = false

  if craftTo <= trigger then
    craftTo = trigger + refillMargin(target, stock)
    banded = true
  end

  local meta = {
    craftTo = craftTo,
    configuredCraftTo = configuredCraftTo,
    banded = banded,
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
  row.reason = meta.reason
  row.ceiling = meta.ceiling
  return row
end

-- ctx fields:
--   stockKeeper : {
--     enabled, cooldownSeconds, maxCraftsPerCycle, maxRequest,
--     refillMarginRatio, minRefillMargin,
--     categories = { { label, items = { { name, label, target, craftTo, maxRequest } } } },
--     items = { ... }   -- used only when categories is empty
--   }
--   now         : current time in ms (wall clock; the ledger persists it across reboots)
--   ledger      : { requests = { [name] = { requestedAt = <ms> } } }  (a table when present)
--   ledgerError : string surfaced when ledger is nil (fail closed: plan nothing)
--   resolve     : function(name) -> amount (number), craftable (bool), crafting (bool)
--
-- Returns an array of plan rows. Each row has an `action`, one of:
--   OK, NOT CRAFTABLE, ALREADY CRAFTING, ON COOLDOWN, CYCLE CAP, WOULD CRAFT, BLOCKED.
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
  local wouldIndexes = {}

  local categories = stock.categories or {}
  if #categories == 0 and type(stock.items) == "table" then
    categories = { { label = "Stock Keeper", items = stock.items } }
  end

  for _, category in ipairs(categories) do
    local categoryLabel = category.label or "Stock Keeper"
    for _, target in ipairs(category.items or {}) do
      local amount, craftable, crafting = resolve(target.name)
      amount = tonumber(amount) or 0
      local label = target.label or target.name
      local trigger = tonumber(target.target) or 0
      local craftTo, craftMeta = stockplan.effectiveCraftTo(target, stock)
      local maxRequest = tonumber(target.maxRequest) or tonumber(stock.maxRequest) or 4096
      local priority = stockplan.deficitPriority(amount, trigger)

      if amount >= trigger then
        plans[#plans + 1] = copyMeta({ action = "OK", name = target.name, category = categoryLabel,
          label = label, amount = amount, target = trigger, priority = 0 }, craftMeta)
      elseif craftMeta.blocked then
        plans[#plans + 1] = copyMeta({ action = "BLOCKED", name = target.name, category = categoryLabel,
          label = label, amount = amount, target = trigger, craftTo = craftTo, priority = priority }, craftMeta)
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
          local request = math.max(0, craftTo - amount)
          local capped = false
          if request > maxRequest then
            request = maxRequest
            capped = true
          end

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
          }, craftMeta)
          plans[#plans + 1] = row
          wouldIndexes[#wouldIndexes + 1] = #plans
        end
      end
    end
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
      if not allowed[idx] then
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

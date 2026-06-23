-- Dry-run stock keeper planner. Pure logic: no peripherals, no fs, no rednet.
-- The caller supplies current stock through ctx.resolve, which is why this can
-- be unit-tested off the in-game runtime (see tests/run.lua).
--
-- This NEVER crafts. It only classifies each managed item into a plan row.
local stockplan = {}

-- ctx fields:
--   stockKeeper : {
--     enabled, cooldownSeconds, maxCraftsPerCycle, maxRequest,
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
  local cycleWouldCraft = 0

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
      local craftTo = tonumber(target.craftTo) or trigger
      local maxRequest = tonumber(target.maxRequest) or tonumber(stock.maxRequest) or 4096

      if amount >= trigger then
        plans[#plans + 1] = { action = "OK", name = target.name, category = categoryLabel, label = label, amount = amount, target = trigger }
      elseif not craftable then
        plans[#plans + 1] = { action = "NOT CRAFTABLE", name = target.name, category = categoryLabel, label = label, amount = amount, target = trigger }
      elseif crafting then
        plans[#plans + 1] = { action = "ALREADY CRAFTING", name = target.name, category = categoryLabel, label = label, amount = amount, target = trigger }
      else
        local record = ledger.requests[target.name]
        local age = record and record.requestedAt and (now - record.requestedAt) or nil

        if record and age and age < cooldownMs then
          plans[#plans + 1] = {
            action = "ON COOLDOWN",
            name = target.name,
            category = categoryLabel,
            label = label,
            amount = amount,
            target = trigger,
            secondsLeft = math.ceil((cooldownMs - age) / 1000),
          }
        elseif cycleWouldCraft >= cycleLimit then
          plans[#plans + 1] = { action = "CYCLE CAP", name = target.name, category = categoryLabel, label = label, amount = amount, target = trigger }
        else
          local request = math.max(0, craftTo - amount)
          local capped = false
          if request > maxRequest then
            request = maxRequest
            capped = true
          end

          cycleWouldCraft = cycleWouldCraft + 1
          plans[#plans + 1] = {
            action = "WOULD CRAFT",
            name = target.name,
            category = categoryLabel,
            label = label,
            amount = amount,
            target = trigger,
            craftTo = craftTo,
            request = request,
            capped = capped,
          }
        end
      end
    end
  end

  return plans
end

return stockplan

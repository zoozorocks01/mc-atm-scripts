-- Overflow / compression planner. The floor planner (atm10-stockplan) keeps
-- stock ABOVE a target by crafting more. This keeps stock BELOW a ceiling by
-- crafting the denser "into" item to drain the surplus (dust -> ingot -> block).
--
-- Pure logic: no peripherals/fs. The caller injects resolve(name), exactly like
-- the stock planner, so this is unit-tested off-CC. It emits rows in the SAME
-- shape as stockplan rows, so they flow through the existing Plan page, approval,
-- queue, and gated runner unchanged. Crafting the `into` item is what consumes
-- the surplus (RS pulls the source via its pattern).
local balance = {}

-- ctx fields:
--   items   : { { name, label, ceiling, into = {name,label}, ratio } }
--   resolve : function(name) -> amount (number), craftable (bool), crafting (bool)
--   now     : current time ms
--   ledger  : { requests = { [name] = { requestedAt } } } (shared with stockplan;
--             cooldown is keyed by the INTO item so refills and compresses of the
--             same item never fire more than once per cooldown)
--   cooldownSeconds, maxRequest : same meaning as the stock keeper
--
-- Returns rows: { action, name = into.name, category = "Overflow", label,
--   amount = source amount, target = ceiling, request, craftTo, capped }
-- action is one of OK (skipped), WOULD CRAFT, NOT CRAFTABLE, ALREADY CRAFTING,
-- ON COOLDOWN.
function balance.plan(ctx)
  ctx = ctx or {}
  local rows = {}
  local items = ctx.items or {}
  local resolve = ctx.resolve or function() return 0, false, false end
  local now = tonumber(ctx.now) or 0
  local cooldownMs = (tonumber(ctx.cooldownSeconds) or 300) * 1000
  local ledger = ctx.ledger or { requests = {} }
  local requests = type(ledger.requests) == "table" and ledger.requests or {}
  local defaultMax = tonumber(ctx.maxRequest) or 4096

  for _, it in ipairs(items) do
    local into = it.into
    if into and into.name and it.ceiling ~= nil then
      local amount = tonumber((resolve(it.name))) or 0
      local ceiling = tonumber(it.ceiling) or 0
      local ratio = math.max(1, tonumber(it.ratio) or 1)
      local qty = math.floor((amount - ceiling) / ratio)

      if qty > 0 then
        local label = (it.label or it.name) .. " -> " .. (into.label or into.name)
        -- distinct queue identity so a compress row crafting `into.name` does not
        -- alias the refill row for that same item (both craft it; they stay separate)
        local row = { name = into.name, key = "compress:" .. it.name, kind = "compress",
          category = "Overflow", label = label, amount = amount, target = ceiling }

        local _, craftable, crafting = resolve(into.name)
        if not craftable then
          row.action = "NOT CRAFTABLE"
        elseif crafting then
          row.action = "ALREADY CRAFTING"
        else
          local rec = requests[into.name]
          local age = rec and rec.requestedAt and (now - rec.requestedAt) or nil
          if rec and age and age < cooldownMs then
            row.action = "ON COOLDOWN"
            row.secondsLeft = math.ceil((cooldownMs - age) / 1000)
          else
            local maxReq = tonumber(it.maxRequest) or defaultMax
            local capped = false
            if qty > maxReq then qty = maxReq; capped = true end
            row.action = "WOULD CRAFT"
            row.request = qty
            row.craftTo = ceiling
            row.capped = capped
          end
        end

        rows[#rows + 1] = row
      end
    end
  end

  return rows
end

return balance

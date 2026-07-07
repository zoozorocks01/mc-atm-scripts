-- Shared local scenarios for the ATM10 manager simulator.
-- Both tools/atm10-sim.lua and tests/smoke_sim.lua consume this file so a bug
-- reproduction has one setup and one set of expectations.

local sim = require("sim.manager_sim")

local M = {}

local ORDER = {
  "approval-aluminum",
  "approval-aluminum-ambiguous",
  "approval-stale-request",
  "ap-failure-progress",
  "auto-admission-bounded",
}

local function contains(text, needle)
  return tostring(text or ""):find(tostring(needle or ""), 1, true) ~= nil
end

local function addCheck(checks, ok, msg)
  checks[#checks + 1] = { ok = ok == true, msg = msg }
end

local function allPassed(checks)
  for _, c in ipairs(checks or {}) do
    if not c.ok then return false end
  end
  return true
end

local function reachedSentinel(report)
  local result = report and report.result or {}
  return result.ok == false and tostring(result.err):find(result.sentinel, 1, true) ~= nil
end

local function serialized(report, path)
  return report.runner:getSerializedFile(path)
end

local function queueEntries(report)
  local q = serialized(report, ".atm10-craft-queue")
  return (q and q.entries) or {}
end

local function audit(report)
  return serialized(report, ".atm10-craft-audit") or {}
end

local function hasAudit(report, predicate)
  for _, event in ipairs(audit(report)) do
    if predicate(event) then return true end
  end
  return false
end

local function aluminumItems(opts)
  opts = opts or {}
  local items = {
    { name = "alltheores:aluminum_ingot", amount = opts.ingotAmount or 1000, isCraftable = true },
    { name = "alltheores:aluminum_dust", amount = opts.dustAmount or 5000, isCraftable = false },
    { name = "alltheores:tiny_aluminum_dust", amount = opts.tinyDustAmount or 12000, isCraftable = false },
    { name = "minecraft:iron_ingot", amount = 800000, isCraftable = false },
  }
  if opts.includeBlock then
    items[#items + 1] = { name = "alltheores:aluminum_block", amount = opts.blockAmount or 0, isCraftable = true }
  end
  return items
end

local function aluminumManagedStore(opts)
  opts = opts or {}
  local store = {
    items = {
      ["alltheores:aluminum_ingot"] = {
        name = "alltheores:aluminum_ingot",
        label = "Aluminum Ingot",
        target = 5000,
        craftTo = 5000,
      },
      ["alltheores:aluminum_dust"] = {
        name = "alltheores:aluminum_dust",
        label = "Aluminum Dust",
        target = 0,
        craftTo = 1,
        ceiling = 1000,
        into = { name = "alltheores:aluminum_ingot", label = "Aluminum Ingot" },
        ratio = 1,
      },
    },
    settings = { modeOverride = "manual" },
  }
  if opts.includeBlock then
    store.items["alltheores:aluminum_block"] = {
      name = "alltheores:aluminum_block",
      label = "Aluminum Block",
      target = 1024,
      craftTo = 1024,
    }
  end
  return store
end

local function runAluminumApproval(target, opts)
  opts = opts or {}
  target = target or opts.target or "alltheores:aluminum_ingot"
  local bridge = sim.bridge({ items = aluminumItems(opts) })
  local runner = sim.new({
    bridge = bridge,
    managedStore = aluminumManagedStore(opts),
    approveRequest = { target = target, requestedAt = opts.requestedAt or 1 },
    events = opts.events or { { "timer", 1 } },
  })
  local result = runner:run()
  return {
    target = target,
    runner = runner,
    result = result,
    crafted = result.crafted,
  }
end

local SCENARIOS = {}

SCENARIOS["approval-aluminum"] = {
  description = "Exact aluminum ingot approval resolves refill/compress collision and fires one bridge request.",
  run = function(args)
    return runAluminumApproval(args[1])
  end,
  checks = function(report)
    local checks = {}
    local approveResult = serialized(report, ".atm10-approve-result")
    local entries = queueEntries(report)
    local refill = entries["alltheores:aluminum_ingot"]
    local compress = entries["compress:alltheores:aluminum_dust"]
    local statusFile = serialized(report, ".atm10-status")
    local planState = serialized(report, ".atm10-planstate")
    addCheck(checks, reachedSentinel(report), "manager completed one scripted cycle and stopped at the simulator sentinel")
    addCheck(checks, type(approveResult) == "table" and approveResult.ok == true
      and approveResult.name == "alltheores:aluminum_ingot",
      "approval result records the matched aluminum refill row")
    addCheck(checks, type(approveResult) == "table" and approveResult.matcher == 2,
      "approval result records the runtime approval matcher version")
    addCheck(checks, type(approveResult) == "table" and approveResult.reason == nil,
      "approval result is not an ambiguity failure")
    addCheck(checks, type(refill) == "table" and refill.state == "CRAFTING"
      and refill.key == "alltheores:aluminum_ingot",
      "exact item id selected the refill queue key")
    addCheck(checks, compress == nil, "exact item id did not select the compress queue key")
    addCheck(checks, #report.crafted == 1 and report.crafted[1].name == "alltheores:aluminum_ingot",
      "the simulated RS bridge received one aluminum ingot craftItem request")
    addCheck(checks, type(statusFile) == "table" and statusFile.version == 2
      and statusFile.runtime and statusFile.runtime.approvalMatcher == 2,
      "status file records the runtime approval matcher version")
    addCheck(checks, type(planState) == "table" and planState.runtime
      and planState.runtime.approvalMatcher == 2,
      "planstate records the runtime approval matcher version")
    return checks
  end,
}

SCENARIOS["approval-aluminum-ambiguous"] = {
  description = "Fuzzy aluminum approval stays ambiguous when multiple refill rows match.",
  run = function(args)
    return runAluminumApproval(args[1] or "aluminum", { includeBlock = true })
  end,
  checks = function(report)
    local checks = {}
    local approveResult = serialized(report, ".atm10-approve-result")
    local entries = queueEntries(report)
    addCheck(checks, reachedSentinel(report), "manager completed one scripted cycle and stopped at the simulator sentinel")
    addCheck(checks, type(approveResult) == "table" and approveResult.ok == false
      and approveResult.matcher == 2,
      "ambiguous fuzzy approval records a matcher-v2 failure")
    addCheck(checks, type(approveResult) == "table" and contains(approveResult.reason, "ambiguous target"),
      "ambiguous fuzzy approval reports an ambiguous target")
    addCheck(checks, next(entries) == nil, "ambiguous fuzzy approval does not queue anything")
    addCheck(checks, #report.crafted == 0, "ambiguous fuzzy approval does not call craftItem")
    return checks
  end,
}

SCENARIOS["approval-stale-request"] = {
  description = "Stale terminal approval request is deleted and never reaches the craft queue.",
  run = function(args)
    return runAluminumApproval(args[1] or "alltheores:aluminum_ingot", { requestedAt = -1 })
  end,
  checks = function(report)
    local checks = {}
    local approveResult = serialized(report, ".atm10-approve-result")
    addCheck(checks, reachedSentinel(report), "manager completed one scripted cycle and stopped at the simulator sentinel")
    addCheck(checks, type(approveResult) == "table" and approveResult.ok == false
      and approveResult.matcher == 2,
      "stale approval request records a matcher-v2 failure")
    addCheck(checks, type(approveResult) == "table" and approveResult.reason == "stale request",
      "stale approval request reports stale request")
    addCheck(checks, report.result.files[".atm10-approve-request"] == nil,
      "stale approval request is deleted")
    addCheck(checks, next(queueEntries(report)) == nil, "stale approval request does not queue anything")
    addCheck(checks, #report.crafted == 0, "stale approval request does not call craftItem")
    return checks
  end,
}

SCENARIOS["ap-failure-progress"] = {
  description = "AP failure after stock gain is treated as progress and keeps the row retryable.",
  run = function()
    local progressed = false
    local bridge = sim.bridge({
      getCraftingTask = false,
      items = function()
        return {
          { name = "alltheores:aluminum_ingot", amount = progressed and 1032 or 1000, isCraftable = true },
          { name = "minecraft:iron_ingot", amount = 800000, isCraftable = false },
        }
      end,
      tasks = function()
        if progressed then return { { name = "alltheores:aluminum_ingot", count = 32 } } end
        return {}
      end,
      craftItem = function(arg, b)
        b.__crafted[#b.__crafted + 1] = { name = arg.name, count = arg.count }
        progressed = true
        return { getId = function() return 1001 end, id = 1001 }
      end,
    })
    local runner = sim.new({
      bridge = bridge,
      managedStore = {
        items = {
          ["alltheores:aluminum_ingot"] = {
            name = "alltheores:aluminum_ingot",
            label = "Aluminum Ingot",
            target = 5000,
            craftTo = 5000,
          },
        },
        settings = { modeOverride = "auto" },
      },
      events = {
        { "timer", 1 },
        { "timer", 2 },
        { "rs_crafting", true, 1001, "craft failed" },
      },
    })
    local result = runner:run()
    return {
      target = "alltheores:aluminum_ingot",
      runner = runner,
      result = result,
      crafted = result.crafted,
    }
  end,
  checks = function(report)
    local checks = {}
    local entries = queueEntries(report)
    local entry = entries["alltheores:aluminum_ingot"]
    local results = serialized(report, ".atm10-craft-results")
    addCheck(checks, reachedSentinel(report), "manager completed the scripted AP failure/progress events")
    addCheck(checks, #report.crafted == 1 and report.crafted[1].name == "alltheores:aluminum_ingot",
      "simulation issued one aluminum craft request")
    addCheck(checks, type(entry) == "table" and entry.state == "APPROVED"
      and entry.jobId == nil and entry.error == nil,
      "stock-progress failure returns the row to APPROVED without an error")
    addCheck(checks, type(entry) == "table" and entry.request == 3968,
      "stock-progress failure reduces the remaining request by the progressed batch")
    addCheck(checks, type(results) == "table" and results["alltheores:aluminum_ingot"]
      and results["alltheores:aluminum_ingot"].ok == true,
      "stock-progress failure records an OK progress result")
    addCheck(checks, hasAudit(report, function(event)
      return event.kind == "job_progress"
        and event.name == "alltheores:aluminum_ingot"
        and event.amount == 32
    end), "audit records job_progress with the capped batch size")
    return checks
  end,
}

SCENARIOS["auto-admission-bounded"] = {
  description = "Auto mode admits only a runnable backlog instead of queueing every deficit at once.",
  run = function()
    local items, managedItems = {}, {}
    for i = 1, 6 do
      local name = "test:auto_item_" .. i
      items[#items + 1] = { name = name, amount = 0, isCraftable = true }
      managedItems[name] = {
        name = name,
        label = "Auto Item " .. i,
        target = 4096,
        craftTo = 4096,
      }
    end
    local bridge = sim.bridge({ items = items })
    local runner = sim.new({
      bridge = bridge,
      managedStore = {
        items = managedItems,
        settings = { modeOverride = "auto" },
      },
      config = {
        mode = "auto",
        allowAutocraft = true,
        stockKeeper = { enabled = true, maxCraftsPerCycle = 2, maxBridgeRequest = 32 },
      },
      events = { { "timer", 1 } },
    })
    local result = runner:run()
    return {
      runner = runner,
      result = result,
      crafted = result.crafted,
    }
  end,
  checks = function(report)
    local checks = {}
    local entries = queueEntries(report)
    local depth = 0
    for _ in pairs(entries) do depth = depth + 1 end
    local statusFile = serialized(report, ".atm10-status")
    addCheck(checks, reachedSentinel(report), "manager completed one auto scan and stopped at the simulator sentinel")
    addCheck(checks, depth == 2, "auto admission keeps queue depth to maxCraftsPerCycle instead of all deficits")
    addCheck(checks, #report.crafted == 2, "runner fires only the admitted auto rows in that cycle")
    addCheck(checks, type(statusFile) == "table" and statusFile.plan and statusFile.plan.wouldCraftCount == 6,
      "sim still had more deficits available than auto admitted")
    return checks
  end,
}

function M.names()
  local out = {}
  for i, name in ipairs(ORDER) do out[i] = name end
  return out
end

function M.get(name)
  return SCENARIOS[name]
end

function M.run(name, args)
  local scenario = SCENARIOS[name]
  if not scenario then return nil, "unknown scenario: " .. tostring(name) end
  args = args or {}
  local report = scenario.run(args)
  report.name = name
  report.description = scenario.description
  report.checks = scenario.checks(report)
  report.ok = allPassed(report.checks)
  return report
end

function M.runAll()
  local reports = {}
  for _, name in ipairs(ORDER) do
    reports[#reports + 1] = M.run(name, {})
  end
  return reports
end

return M

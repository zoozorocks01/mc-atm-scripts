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
  "auto-quarantines-failed-row",
  "soak-request-bounded-window",
  "soak-fail-stop-reverts",
  "soak-restart-stays-manual",
  "late-progress-clears-failed-row",
  "drain-aware-batch-sizing",
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

SCENARIOS["auto-quarantines-failed-row"] = {
  description = "Auto mode holds a failed row but keeps unrelated work moving within the bounded backlog.",
  run = function()
    local bridge = sim.bridge({
      items = {
        { name = "minecraft:copper_ingot", amount = 9000, isCraftable = true },
        { name = "alltheores:aluminum_ingot", amount = 1000, isCraftable = true },
        { name = "alltheores:tin_ingot", amount = 1000, isCraftable = true },
      },
    })
    local runner = sim.new({
      bridge = bridge,
      managedStore = {
        items = {
          ["minecraft:copper_ingot"] = {
            name = "minecraft:copper_ingot",
            label = "Copper Ingot",
            target = 12000,
            craftTo = 12000,
          },
          ["alltheores:aluminum_ingot"] = {
            name = "alltheores:aluminum_ingot",
            label = "Aluminum Ingot",
            target = 5000,
            craftTo = 5000,
          },
          ["alltheores:tin_ingot"] = {
            name = "alltheores:tin_ingot",
            label = "Tin Ingot",
            target = 5000,
            craftTo = 5000,
          },
        },
        settings = { modeOverride = "auto" },
      },
      config = {
        mode = "auto",
        allowAutocraft = true,
        stockKeeper = { enabled = true, maxCraftsPerCycle = 2, maxBridgeRequest = 32 },
      },
      queue = {
        entries = {
          ["minecraft:copper_ingot"] = {
            key = "minecraft:copper_ingot",
            name = "minecraft:copper_ingot",
            label = "Copper Ingot",
            state = "APPROVED",
            request = 4096,
            approvedAt = 1,
            triedAt = 1,
            error = "craft failed",
          },
        },
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
    local copper = entries["minecraft:copper_ingot"]
    local aluminum = entries["alltheores:aluminum_ingot"]
    local tin = entries["alltheores:tin_ingot"]
    addCheck(checks, reachedSentinel(report), "manager completed one auto quarantine cycle and stopped at the simulator sentinel")
    addCheck(checks, type(copper) == "table" and copper.error == "craft failed"
      and copper.state == "APPROVED",
      "failed copper row remains quarantined for explicit retry or clear")
    addCheck(checks, type(aluminum) == "table" and aluminum.state == "CRAFTING",
      "unrelated aluminum row is allowed to proceed despite the failed copper row")
    addCheck(checks, type(tin) == "table" and tin.state == "CRAFTING",
      "failed row does not consume one of the bounded runnable auto slots")
    local fired = {}
    for _, row in ipairs(report.crafted or {}) do fired[row.name] = true end
    addCheck(checks, #report.crafted == 2 and fired["alltheores:aluminum_ingot"] and fired["alltheores:tin_ingot"],
      "runner fired both healthy admitted rows while copper stayed quarantined")
    return checks
  end,
}

-- Shared setup for the SOAK scenarios: a MANUAL base with n craftable deficits
-- and the stock keeper enabled, so the only thing that can make auto fire is the
-- agent-requested soak window itself.
local function soakWorld(n)
  local items, managedItems = {}, {}
  for i = 1, n do
    local name = "test:soak_item_" .. i
    items[#items + 1] = { name = name, amount = 0, isCraftable = true }
    managedItems[name] = { name = name, label = "Soak Item " .. i, target = 4096, craftTo = 4096 }
  end
  return {
    bridge = sim.bridge({ items = items }),
    managedStore = { items = managedItems, settings = { modeOverride = "manual" } },
    config = {
      mode = "manual",
      allowAutocraft = true,
      stockKeeper = { enabled = true, maxCraftsPerCycle = 2, maxBridgeRequest = 32 },
    },
  }
end

-- Event helper: write a FRESH soak request mid-run (boot intentionally deletes a
-- pre-boot request, so a live agent writes while the manager runs), then hand the
-- loop a scan timer so the same cycle consumes it.
local function soakRequestEvent(opts)
  return function(s)
    local req = { requestedAt = s.clock, durationMs = 600000 }
    for k, v in pairs(opts or {}) do req[k] = v end
    s:setSerializedFile(".atm10-soak-request", req)
    return { "timer", 99 }
  end
end

SCENARIOS["soak-request-bounded-window"] = {
  description = "Agent soak request runs bounded auto from a manual base and stays within its per-cycle cap.",
  run = function()
    local world = soakWorld(3)
    local runner = sim.new({
      bridge = world.bridge,
      managedStore = world.managedStore,
      config = world.config,
      events = {
        { "timer", 1 },                        -- manual cycle: nothing may fire
        soakRequestEvent({ maxPerCycle = 1 }), -- agent asks; soak starts + fires 1
        { "timer", 2 },                        -- first job closes (vanished-ok)
        { "timer", 3 },                        -- freed slot admits + fires the next
      },
    })
    local result = runner:run()
    return { runner = runner, result = result, crafted = result.crafted }
  end,
  checks = function(report)
    local checks = {}
    local statusFile = serialized(report, ".atm10-status")
    local soakState = serialized(report, ".atm10-soakstate")
    addCheck(checks, reachedSentinel(report), "manager completed the scripted soak cycles and stopped at the simulator sentinel")
    addCheck(checks, #report.crafted == 2,
      "soak fired exactly one craft per healthy cycle (2 of 3 deficits), not the whole backlog")
    addCheck(checks, #report.crafted == 2 and report.crafted[1].name ~= report.crafted[2].name,
      "each bounded soak fire went to a different deficit item")
    addCheck(checks, type(statusFile) == "table" and statusFile.mode == "auto",
      "status reports the soak's effective auto mode for agent polling")
    addCheck(checks, type(statusFile) == "table" and type(statusFile.soak) == "table"
      and statusFile.soak.running == true and statusFile.soak.fired == 2,
      "status carries the running soak block with the fired count")
    addCheck(checks, type(soakState) == "table" and (tonumber(soakState.endsAt) or 0) > 0,
      "manager persisted the running soak state for restart detection")
    addCheck(checks, report.result.files[".atm10-soak-report"] == nil,
      "no soak report is written while the window is still running")
    addCheck(checks, report.result.files[".atm10-soak-request"] == nil,
      "the consumed soak request file is deleted")
    return checks
  end,
}

SCENARIOS["soak-fail-stop-reverts"] = {
  description = "First failed row ends the soak, reverts to manual, and reports the failure -- not the clock.",
  run = function()
    local world = soakWorld(2)
    local runner = sim.new({
      bridge = world.bridge,
      managedStore = world.managedStore,
      config = world.config,
      events = {
        { "timer", 1 },                        -- manual cycle: nothing may fire
        soakRequestEvent({ maxPerCycle = 1 }), -- soak starts + fires item 1 (job 1001)
        { "rs_crafting", true, 1001, "craft failed" }, -- AP reports the job failed
        { "timer", 2 },                        -- end-check sees the failure -> revert
      },
    })
    local result = runner:run()
    return { runner = runner, result = result, crafted = result.crafted }
  end,
  checks = function(report)
    local checks = {}
    local entries = queueEntries(report)
    local failed = entries["test:soak_item_1"]
    local soakReport = serialized(report, ".atm10-soak-report")
    local statusFile = serialized(report, ".atm10-status")
    addCheck(checks, reachedSentinel(report), "manager completed the scripted fail-stop cycles and stopped at the simulator sentinel")
    addCheck(checks, #report.crafted == 1 and report.crafted[1].name == "test:soak_item_1",
      "only the pre-failure craft fired; the second deficit never got a request")
    addCheck(checks, type(failed) == "table" and failed.state == "APPROVED" and failed.error ~= nil,
      "the failed row stays quarantined for explicit retry or clear")
    addCheck(checks, entries["test:soak_item_2"] == nil,
      "no new work was admitted once the failure ended the soak")
    addCheck(checks, type(soakReport) == "table" and soakReport.ok == false
      and soakReport.reason == "queue failure" and soakReport.fired == 1,
      "soak report names the queue failure (fail-stop), not the deadline")
    addCheck(checks, report.result.files[".atm10-soakstate"] == nil,
      "soak state is cleared when the soak ends")
    addCheck(checks, type(statusFile) == "table" and statusFile.mode == "manual"
      and statusFile.soak == nil,
      "manager reverted to the manual base with no soak block in status")
    addCheck(checks, type(statusFile) == "table" and statusFile.summary == "QUEUE_WARN",
      "status summary warns about the failed row left in the queue")
    return checks
  end,
}

SCENARIOS["soak-restart-stays-manual"] = {
  description = "A manager restart mid-soak reports the interruption and boots manual; pre-boot request files are ignored.",
  run = function()
    local world = soakWorld(1)
    local runner = sim.new({
      bridge = world.bridge,
      managedStore = world.managedStore,
      config = world.config,
      files = {
        -- as if the manager died mid-soak with a huge window left...
        [".atm10-soakstate"] = { requestedAt = 1, startedAt = 1, endsAt = 1e12, fired = 3 },
        -- ...and some agent left a request lying around before boot
        [".atm10-soak-request"] = { requestedAt = 1, durationMs = 600000 },
      },
      events = { { "timer", 1 }, { "timer", 2 } },
    })
    local result = runner:run()
    return { runner = runner, result = result, crafted = result.crafted }
  end,
  checks = function(report)
    local checks = {}
    local soakReport = serialized(report, ".atm10-soak-report")
    local statusFile = serialized(report, ".atm10-status")
    addCheck(checks, reachedSentinel(report), "manager booted, ran two manual cycles, and stopped at the simulator sentinel")
    addCheck(checks, type(soakReport) == "table" and soakReport.ok == false
      and soakReport.reason == "manager restart" and soakReport.fired == 3,
      "boot reports the interrupted soak with its fired count")
    addCheck(checks, report.result.files[".atm10-soakstate"] == nil,
      "boot clears the leftover soak state")
    addCheck(checks, report.result.files[".atm10-soak-request"] == nil,
      "boot deletes a pre-boot soak request instead of honoring it")
    addCheck(checks, #report.crafted == 0,
      "no craft fired: the interrupted soak did NOT resume as auto")
    addCheck(checks, type(statusFile) == "table" and statusFile.mode == "manual"
      and statusFile.soak == nil,
      "manager is back on its manual base with no soak block")
    return checks
  end,
}

SCENARIOS["late-progress-clears-failed-row"] = {
  description = "A delivery that lands AFTER the failure event still clears the quarantined row (order-independence).",
  run = function()
    -- Live repro (AP 0.7.61b, 2026-07-08): AP fires "craft failed" ~20s in, the
    -- items land seconds LATER. In-window gain is absorbed by progressJobId;
    -- this covers the late case. AUTO mode on purpose: autoApprove refreshes
    -- e.amount (the progress baseline) every scan, so the reconcile must rely
    -- on the failure-time snapshot, not the live baseline.
    local arrived = false
    local bridge = sim.bridge({
      getCraftingTask = false,
      items = function()
        return {
          { name = "test:late_item", amount = arrived and 1032 or 1000, isCraftable = true },
        }
      end,
    })
    local runner = sim.new({
      bridge = bridge,
      managedStore = {
        items = {
          ["test:late_item"] = { name = "test:late_item", label = "Late Item", target = 5000, craftTo = 5000 },
        },
        settings = { modeOverride = "auto" },
      },
      config = {
        mode = "auto",
        allowAutocraft = true,
        stockKeeper = { enabled = true, maxCraftsPerCycle = 1, maxBridgeRequest = 32 },
      },
      events = {
        { "timer", 1 },                                -- auto-approves + fires (job 1001)
        { "rs_crafting", true, 1001, "craft failed" }, -- failure lands FIRST, no stock gain yet
        function(s)                                    -- ...the delivery arrives after
          arrived = true
          return { "timer", 2 }                        -- next scan reconciles the late gain
        end,
      },
    })
    local result = runner:run()
    return { runner = runner, result = result, crafted = result.crafted }
  end,
  checks = function(report)
    local checks = {}
    local entries = queueEntries(report)
    local entry = entries["test:late_item"]
    local results = serialized(report, ".atm10-craft-results")
    addCheck(checks, reachedSentinel(report), "manager completed the fail-then-deliver cycles and stopped at the simulator sentinel")
    addCheck(checks, #report.crafted == 1, "exactly one bridge request fired before the failure")
    addCheck(checks, type(entry) == "table" and entry.state == "APPROVED" and entry.error == nil,
      "late delivery cleared the latched error (row healthy again, no operator retry needed)")
    addCheck(checks, type(entry) == "table" and entry.failedRequest == nil and entry.failedAmount == nil,
      "reconcile consumed the failure-time snapshot (no double-credit ammunition left)")
    addCheck(checks, type(results) == "table" and results["test:late_item"]
      and results["test:late_item"].ok == true,
      "late delivery recorded an OK result for diagnostics")
    addCheck(checks, hasAudit(report, function(event)
      return event.kind == "late_progress" and event.name == "test:late_item" and event.amount == 32
    end), "audit records late_progress with the credited batch size")
    return checks
  end,
}

SCENARIOS["drain-aware-batch-sizing"] = {
  description = "High-drain gold sizes ONE turn's request to outpace measured consumption instead of starving at the fixed base batch.",
  run = function()
    -- Live repro (production 2026-07-22): gold sat at 18,776 of a 100,000 target
    -- while the planner requested only 4,096/turn. A Dyson-swarm crafting chain
    -- drained gold faster than 4,096/turn, so the deficit never closed. Persist a
    -- sustained-drain window (net 21,224 over 15 min => ~1,415/min) and let auto
    -- fire once; the fired batch must now cover the drain expected before the next
    -- turn (~one 5-min cooldown) plus headway, bounded by the maxBatch ceiling.
    local goldName = "minecraft:gold_ingot"
    local bridge = sim.bridge({
      items = { { name = goldName, amount = 18776, isCraftable = true } },
    })
    local runner = sim.new({
      bridge = bridge,
      -- start the sim clock past the trend window so the persisted history is
      -- fresh (now > tN) and inside the 12h keep window when loadTrends prunes.
      clockStart = 500000000,
      managedStore = {
        items = {
          [goldName] = { name = goldName, label = "Gold Ingot", target = 100000, craftTo = 100000 },
        },
        settings = { modeOverride = "auto", smartMode = true },
      },
      config = {
        mode = "auto",
        allowAutocraft = true,
        stockKeeper = {
          enabled = true,
          cooldownSeconds = 300,     -- 5-min re-request window the batch must span
          maxCraftsPerCycle = 2,
          maxRequest = 4096,         -- the fixed base batch that starved gold live
          maxBatch = 32768,          -- drain-aware ceiling (opt-in; DECISIONS #6)
          maxBridgeRequest = 65536,  -- large: don't let bridge batching mask the plan request
        },
      },
      files = {
        [".atm10-trends"] = {
          [goldName] = {
            label = "Gold Ingot",
            t0 = 499000000, a0 = 40000,
            tN = 499900000, aN = 18776,
            minA = 18776, maxA = 40000, n = 30,
          },
        },
      },
      events = { { "timer", 1 } },
    })
    local result = runner:run()
    return { runner = runner, result = result, crafted = result.crafted }
  end,
  checks = function(report)
    local checks = {}
    -- perMin = (40000-18776)/15min = 1414.93...; one 5-min cooldown of drain =
    -- floor(1414.93*5) = 7074; drain-aware batch = base 4096 + 7074 = 11170.
    local baseBatch = 4096
    local drainPerCooldown = 7074
    local expectedBatch = 11170
    local maxBatch = 32768
    local fired = report.crafted[1]
    local count = fired and tonumber(fired.count)
    addCheck(checks, reachedSentinel(report), "manager completed one auto scan and stopped at the simulator sentinel")
    addCheck(checks, #report.crafted == 1 and fired and fired.name == "minecraft:gold_ingot",
      "auto fired exactly one gold craft (serial lane unchanged: one task at a time)")
    addCheck(checks, count ~= nil and count > drainPerCooldown,
      "one turn's request outpaces a cooldown of measured drain (converges); the fixed " .. baseBatch .. " batch did not")
    addCheck(checks, count == expectedBatch,
      "drain-aware batch = base cap + one cooldown of drain (4096 + 7074 = 11170)")
    addCheck(checks, count ~= nil and count <= maxBatch,
      "batch stays bounded by the configured maxBatch ceiling")
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

-- safereboot: reboot this computer WITHOUT the AdvancedPeripherals server crash.
--
-- Rebooting/shutting-down a computer wired to an rs_bridge while AP still has a craft
-- job in flight makes AP tick that job against a computer that just went away -- an
-- uncaught NotAttachedException that crashes the WHOLE server tick.
--
-- This first asks the manager to stop issuing NEW craftItem calls, then polls the
-- BRIDGE'S LIVE crafting status (control.activeCraftCount). The manager's
-- .atm10-craftstate file is used only for its drain ack, last craft timestamp,
-- fallback item names, and AP job IDs that are invisible while still calculating.
-- We wait until RS reports zero active craft jobs (+ a drain grace for the final
-- AP events), then reboot. No bridge on this computer => reboot immediately.
--
-- TWO things the live task list cannot see:
--  * getCraftingTasks only mirrors RS's ACTIVE tasks. A job still in preview/
--    calculation can be invisible, so the snapshot's lastCraftAt keeps the drain
--    floor open even when the list reads 0.
--  * Recorded craftItem job ids are checked with getCraftingTask(id). Done,
--    canceled, errored, or NOT_FOUND jobs count as settled.
--
-- PROCEDURE: run `safereboot`; it will request a manager drain before rebooting.
--
-- Usage:
--   safereboot           drain crafts, then reboot (the safe path)
--   safereboot --force   reboot now (only if you KNOW nothing is crafting)

local control = require("atm10-control")

local CRAFTSTATE_FILE = ".atm10-craftstate" -- read only for fallback item names
local DRAIN_REQUEST_FILE = ".atm10-drain-request"
local HEARTBEAT_FILE = ".atm10-heartbeat"
local POLL_SECONDS = 3
local HEARTBEAT_STALE_MS = 30000
local GRACE_AUTHORITATIVE_MS = 12000              -- grace once the task list reads empty
local GRACE_BLIND_MS = control.DEFAULT_DRAIN_MS   -- conservative wait if we can't query

local function nowMs()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local text = f.readAll()
  f.close()
  return text
end

local function readSerializedFile(path)
  local text = readText(path)
  if not text then return nil end
  local ok, data = pcall(textutils.unserialize, text)
  if ok then return data end
  return nil
end

local function writeSerializedFile(path, data)
  local ok, text = pcall(textutils.serialize, data)
  if not ok or type(text) ~= "string" then return false end
  local f = fs.open(path, "w")
  if not f then return false end
  f.write(text)
  f.close()
  return true
end

local function readCraftState()
  local data = readSerializedFile(CRAFTSTATE_FILE)
  if type(data) == "table" then return data end
  return {}
end

-- The manager's last-known crafting item names, used only as a fallback when the
-- bridge has no task-list method (so isItemCrafting has something to check).
local function fallbackNames(state)
  if type(state) == "table" and type(state.craftingNames) == "table" then
    return state.craftingNames
  end
  return {}
end

local function heartbeatFresh(now)
  local at = tonumber(readText(HEARTBEAT_FILE))
  if not at then return false, "heartbeat missing" end
  local age = math.max(0, now - at)
  return age <= HEARTBEAT_STALE_MS, "heartbeat age " .. math.ceil(age / 1000) .. "s"
end

local function drainAcked(state, requestedAt)
  if type(state) ~= "table" or state.drainAck ~= true then return false end
  return tostring(state.drainRequestAt) == tostring(requestedAt)
end

local function maxAt(a, b)
  a, b = tonumber(a), tonumber(b)
  if a and b then return math.max(a, b) end
  return a or b
end

local function findBridge()
  for _, name in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(name)
    if t == "rsBridge" or t == "meBridge" or t == "rs_bridge" or t == "me_bridge" then
      return peripheral.wrap(name)
    end
  end
  return nil
end

local function doReboot(reason)
  print("safereboot: " .. reason .. " -> rebooting")
  sleep(1)
  os.reboot()
end

local args = { ... }
if args[1] == "--force" or args[1] == "-f" then
  doReboot("--force (skipping drain check)")
  return
end

local bridge = findBridge()
if not bridge then
  doReboot("no rs_bridge on this computer (no AP crash risk)")
  return
end

print("safereboot: draining crafts before reboot.  Ctrl+T to abort.")

local requestedAt = nowMs()
if not writeSerializedFile(DRAIN_REQUEST_FILE, { requestedAt = requestedAt }) then
  print("safereboot: could not write " .. DRAIN_REQUEST_FILE .. "; aborting")
  return
end
print("safereboot: requested manager drain.")

local lastActiveAt = nil
local startedAt = nowMs()
while true do
  local now = nowMs()
  if not fs.exists(DRAIN_REQUEST_FILE) then
    writeSerializedFile(DRAIN_REQUEST_FILE, { requestedAt = requestedAt })
  end

  local craftState = readCraftState()
  local acked = drainAcked(craftState, requestedAt)
  local heartbeatOk, heartbeatReason = heartbeatFresh(now)
  if not acked and heartbeatOk then
    print("safereboot: waiting for manager drain ack (" .. heartbeatReason .. ")")
    sleep(POLL_SECONDS)
  else
    local count, method = control.activeCraftCount(bridge, fallbackNames(craftState))
    local unsettled = control.unsettledJobs(bridge, craftState.outstanding)
    local blind = (method == "none")
    if type(unsettled) ~= "table" then
      if unsettled == nil then blind = true end
      unsettled = { count = tonumber(unsettled) or 0 }
    elseif unsettled.method == "missing" and type(craftState.outstanding) == "table" and #craftState.outstanding > 0 then
      blind = true
    end
    local unsettledCount = tonumber(unsettled.count) or 0
    if count > 0 or unsettledCount > 0 then lastActiveAt = now end
    -- blind (no craft-status API): wait a full conservative window from start
    if blind and not lastActiveAt then lastActiveAt = startedAt end
    local lastCraftAt = maxAt(lastActiveAt, craftState.lastCraftAt)
    local drainMs = (method == "isItemCrafting" or blind) and GRACE_BLIND_MS or GRACE_AUTHORITATIVE_MS
    if craftState.lastCraftAt then drainMs = math.max(drainMs, control.DEFAULT_DRAIN_MS) end

    local verdict = control.rebootSafety({
      now = now,
      lastCraftAt = lastCraftAt,
      crafting = count + unsettledCount,
      drainMs = drainMs,
    })
    if verdict.safe then
      doReboot("RS idle [" .. method .. "]")
      return
    end

    if count > 0 then
      print("safereboot: " .. count .. " craft(s) in flight [" .. method .. "] - waiting...")
    end
    if unsettledCount > 0 then
      print("safereboot: " .. unsettledCount .. " outstanding AP job(s) still unsettled")
    elseif verdict.secondsLeft then
      print("safereboot: grace ~" .. verdict.secondsLeft .. "s [" .. method .. (blind and "; blind wait, can't query" or "") .. "]")
    end
    sleep(POLL_SECONDS)
  end
end

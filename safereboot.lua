-- safereboot: reboot/restart this computer WITHOUT risking the AdvancedPeripherals
-- server crash.
--
-- Rebooting (or shutting down, or `update` + reboot) a computer while AP still has
-- a craft job pending makes AP fire that job's completion event at a computer that
-- just went away. That throw (NotAttachedException) is uncaught and crashes the
-- WHOLE server tick. AP's job list lags the manager's queue, so "nothing crafting"
-- on screen is not enough -- a drain window must also pass.
--
-- Use this INSTEAD of `reboot` on the manager (or anything wired to an rs_bridge).
-- It waits until no craft is in flight AND AP's drain window has elapsed, then
-- reboots. Viewer/power computers (no bridge, no craft state) reboot immediately.
--
-- Usage:
--   safereboot           wait for drain, then reboot
--   safereboot --force   reboot now (only if you KNOW nothing is crafting)

local control = require("atm10-control")

local CRAFTSTATE_FILE = ".atm10-craftstate"
local DRAIN_MS = control.DEFAULT_DRAIN_MS
local POLL_SECONDS = 5

local function nowMs()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

local function readCraftState()
  if not fs.exists(CRAFTSTATE_FILE) then return nil end
  local file = fs.open(CRAFTSTATE_FILE, "r")
  if not file then return nil end
  local text = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, text)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

-- Best-effort live confirmation: if a bridge is present, double-check that none of
-- the recently-crafting items still report as crafting. The time-based drain is the
-- real guarantee; this just catches a job that is still live past the window.
local function findBridge()
  for _, name in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(name)
    if t == "rsBridge" or t == "meBridge" or t == "rs_bridge" or t == "me_bridge" then
      return peripheral.wrap(name)
    end
  end
  return nil
end

local function liveCrafting(bridge, names)
  if not bridge or type(bridge.isItemCrafting) ~= "function" or type(names) ~= "table" then
    return false
  end
  for _, n in ipairs(names) do
    local ok, res = pcall(bridge.isItemCrafting, { name = n })
    if ok and res == true then return true end
  end
  return false
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

print("safereboot: checking craft drain (Ctrl+T to abort)...")

while true do
  local st = readCraftState() or {}
  local bridge = findBridge()
  local crafting = math.max(tonumber(st.crafting) or 0, liveCrafting(bridge, st.craftingNames) and 1 or 0)

  local verdict = control.rebootSafety({
    now = nowMs(),
    lastCraftAt = st.lastCraftAt,
    crafting = crafting,
    drainMs = DRAIN_MS,
  })

  if verdict.safe then
    doReboot("safe (" .. verdict.reason .. ")")
    return
  end

  local msg = "safereboot: NOT safe yet - " .. verdict.reason
  if verdict.secondsLeft then msg = msg .. " (~" .. verdict.secondsLeft .. "s)" end
  print(msg)
  sleep(POLL_SECONDS)
end

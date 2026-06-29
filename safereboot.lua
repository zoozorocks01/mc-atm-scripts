-- safereboot: reboot this computer WITHOUT the AdvancedPeripherals server crash.
--
-- Rebooting/shutting-down a computer wired to an rs_bridge while AP still has a craft
-- job in flight makes AP tick that job against a computer that just went away -- an
-- uncaught NotAttachedException that crashes the WHOLE server tick.
--
-- This polls the BRIDGE'S LIVE crafting status (control.activeCraftCount), NOT the
-- manager's .atm10-craftstate file. That file goes stale the instant you Ctrl+T the
-- manager -- and trusting it is exactly why the old version rebooted too early and
-- crashed. We wait until RS reports zero active craft jobs (+ a short grace for the
-- final tick), then reboot. No bridge on this computer => reboot immediately.
--
-- PROCEDURE: Ctrl+T the manager FIRST (so no NEW crafts start), then run `safereboot`.
--
-- Usage:
--   safereboot           drain crafts, then reboot (the safe path)
--   safereboot --force   reboot now (only if you KNOW nothing is crafting)

local control = require("atm10-control")

local CRAFTSTATE_FILE = ".atm10-craftstate" -- read only for fallback item names
local POLL_SECONDS = 3
local GRACE_AUTHORITATIVE_MS = 12000            -- grace once the task list reads empty
local GRACE_BLIND_MS = control.DEFAULT_DRAIN_MS  -- conservative wait if we can't query

local function nowMs()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

-- The manager's last-known crafting item names, used only as a fallback when the
-- bridge has no task-list method (so isItemCrafting has something to check).
local function fallbackNames()
  if not fs.exists(CRAFTSTATE_FILE) then return {} end
  local f = fs.open(CRAFTSTATE_FILE, "r")
  if not f then return {} end
  local text = f.readAll(); f.close()
  local ok, data = pcall(textutils.unserialize, text)
  if ok and type(data) == "table" and type(data.craftingNames) == "table" then
    return data.craftingNames
  end
  return {}
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
print("(Ctrl+T the manager FIRST so no new crafts start.)")

local lastActiveAt = nil
local startedAt = nowMs()
while true do
  local now = nowMs()
  local count, method = control.activeCraftCount(bridge, fallbackNames())
  local blind = (method == "none")
  if count > 0 then lastActiveAt = now end
  -- blind (no craft-status API): wait a full conservative window from start
  if blind and not lastActiveAt then lastActiveAt = startedAt end
  local drainMs = (method == "isItemCrafting" or blind) and GRACE_BLIND_MS or GRACE_AUTHORITATIVE_MS

  local verdict = control.rebootSafety({ now = now, lastCraftAt = lastActiveAt, crafting = count, drainMs = drainMs })
  if verdict.safe then
    doReboot("RS idle [" .. method .. "]")
    return
  end

  if count > 0 then
    print("safereboot: " .. count .. " craft(s) in flight [" .. method .. "] - waiting...")
  elseif verdict.secondsLeft then
    print("safereboot: grace ~" .. verdict.secondsLeft .. "s [" .. method .. (blind and "; blind wait, can't query" or "") .. "]")
  end
  sleep(POLL_SECONDS)
end

-- atm10-line.lua : production-line actuator (docs/DECISIONS.md #4).
--
-- Runs on a SMALL computer near a machine line (e.g. the smelter bank). It
-- listens for the manager's rednet broadcast and turns each configured line's
-- decision into a redstone output that gates that line's RS Exporter.
--
-- Usage (in the mini computer's shell, or its startup file):
--   atm10-line <line>:<side> [<line>:<side> ...]
--   e.g.  atm10-line aluminum:back copper:left
-- Line names must match `config.lines[].name` in the manager's inventory-config.
--
-- DEAD-MAN SWITCH: if no fresh manager broadcast arrives within STALE_MS, every
-- output goes OFF. A dead or unreachable manager can never leave a line running
-- unattended -- same fail-safe philosophy as the safereboot drain flag.

local PROTOCOL = "atm10-inventory-v1" -- the manager's existing broadcast protocol
local STALE_MS = 30000                -- outputs drop OFF beyond this silence
local VALID_SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

local args = { ... }
if #args == 0 then
  print("usage: atm10-line <line>:<side> [<line>:<side> ...]")
  print("e.g.   atm10-line aluminum:back copper:left")
  return
end

local outputs = {}
for _, spec in ipairs(args) do
  local line, side = tostring(spec):match("^([^:]+):(%a+)$")
  if not line or not VALID_SIDES[side] then
    print("bad spec '" .. tostring(spec) .. "' (want <line>:<side>, side one of top/bottom/left/right/front/back)")
    return
  end
  outputs[#outputs + 1] = { line = line, side = side, on = false }
end

local function openModem()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then
      rednet.open(side)
      return true
    end
  end
  return false
end

if not openModem() then
  print("no modem attached - place a (wireless) modem on any side")
  return
end

local function nowMs()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

local function apply(quietly)
  for _, o in ipairs(outputs) do
    rs.setOutput(o.side, o.on == true)
    if not quietly then
      print(("%s -> %s (%s): %s"):format(o.line, o.side, o.on and "ON" or "OFF", o.reason or ""))
    end
  end
end

-- Fail-safe boot posture: everything OFF until the first fresh broadcast.
apply(true)
print("atm10-line: listening for manager broadcasts (" .. PROTOCOL .. ")")
local lastHeard = 0

while true do
  local timer = os.startTimer(5)
  local event, p1, p2, p3 = os.pullEvent()
  if event == "rednet_message" and p3 == PROTOCOL and type(p2) == "table" and type(p2.lines) == "table" then
    lastHeard = nowMs()
    local changed = false
    for _, o in ipairs(outputs) do
      local st = p2.lines[o.line]
      local want = (type(st) == "table" and st.on == true) or false
      local reason = (type(st) == "table" and st.reason)
        or (st == nil and "line not in manager config" or nil)
      if want ~= o.on or reason ~= o.reason then changed = true end
      o.on, o.reason = want, reason
    end
    if changed then apply() end
  elseif event == "timer" and p1 == timer then
    if lastHeard > 0 and (nowMs() - lastHeard) > STALE_MS then
      local anyOn = false
      for _, o in ipairs(outputs) do anyOn = anyOn or o.on end
      for _, o in ipairs(outputs) do o.on, o.reason = false, "manager silent (dead-man)" end
      if anyOn then
        apply()
        print("manager silent > " .. math.floor(STALE_MS / 1000) .. "s - all lines OFF (dead-man)")
      end
      lastHeard = 0 -- report once, stay off until broadcasts resume
    end
  end
end

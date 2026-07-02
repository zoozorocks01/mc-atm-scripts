local PROTOCOL = "atm10-power-v1"
local DISPLAY_HOSTNAME = "display"
local MODEM_SIDE = "top"
local INDUCTION_SIDE = "bottom"

rednet.open(MODEM_SIDE)

local power = require("atm10-power") -- QUICK-2: shared percent normalization (tested off-CC)

-- The induction port is (re)wrapped EVERY cycle (see the loop). A chunk unload/
-- reload -- e.g. the operator logging out and back in -- recreates the block
-- entity, and a wrap captured once at boot stays bound to the DEAD instance:
-- reads freeze (0 FE in/out, static stored energy) until the computer is
-- rebooted. Wrapping is cheap at once a second; a fresh handle follows the
-- current block entity with no reboot. If the port vanishes entirely the sample
-- degrades to sensorOk=false (the display's SENSOR state) instead of erroring.
local port = peripheral.wrap(INDUCTION_SIDE)
if not port then error("No induction port on " .. INDUCTION_SIDE) end

local displayId = nil
local ticks = 0
local previousEnergy = nil
local previousTime = nil
local lastNonzeroInput = 0
local lastNonzeroOutput = 0

-- QUICK-4: return (value, reachable). reachable is false when the method is missing or the
-- read errored, so a wrong/detached induction port can be told apart from a genuine 0 instead
-- of fabricating a plausible empty matrix.
local function call(name)
  if port and port[name] then
    local ok, value = pcall(port[name])
    if ok then return tonumber(value) or value, true end
  end
  return 0, false
end

local function getPercent(energy, maxEnergy)
  -- QUICK-2: normalization lives in the tested atm10-power lib; the port read stays here.
  return power.percent(call("getEnergyFilledPercentage"), energy, maxEnergy)
end

local function findDisplay()
  local id = rednet.lookup(PROTOCOL, DISPLAY_HOSTNAME, 2)
  if id then
    displayId = id
    print("Display found: " .. id)
  else
    print("Display not found")
  end
end

local function nowMs()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

local function estimateNet(energy)
  local t = nowMs()
  local estimated = 0

  if previousEnergy and previousTime and t > previousTime then
    local elapsedSeconds = (t - previousTime) / 1000
    estimated = (energy - previousEnergy) / elapsedSeconds / 20
  end

  previousEnergy = energy
  previousTime = t
  return estimated
end

while true do
  ticks = ticks + 1

  -- re-acquire the handle so a chunk-reload-recreated port is picked up live
  port = peripheral.wrap(INDUCTION_SIDE)

  if not displayId or ticks % 30 == 1 then
    findDisplay()
  end

  local rawEnergy, okEnergy = call("getEnergy")
  local rawMax, okMax = call("getMaxEnergy")
  local energy = tonumber(rawEnergy) or 0
  local maxEnergy = tonumber(rawMax) or 0
  -- NOTE: call() returns (value, reachable); the extra parens truncate it to ONE value so the
  -- boolean does not leak into tonumber's `base` arg (which would raise and kill the loop).
  local input = tonumber((call("getLastInput"))) or 0
  local output = tonumber((call("getLastOutput"))) or 0
  local transferCap = tonumber((call("getTransferCap"))) or 0
  local estimatedNet = estimateNet(energy)
  -- QUICK-4: the core matrix reads define reachability; if they fail the display shows a
  -- SENSOR state instead of a fabricated 0/0/0%.
  local sensorOk = okEnergy and okMax

  if input and input > 0 then lastNonzeroInput = input end
  if output and output > 0 then lastNonzeroOutput = output end

  local msg = {
    kind = "power_sample",
    energy = energy,
    maxEnergy = maxEnergy,
    percent = getPercent(energy, maxEnergy),
    input = input,
    output = output,
    reportedNet = input - output,
    estimatedNet = estimatedNet,
    lastNonzeroInput = lastNonzeroInput,
    lastNonzeroOutput = lastNonzeroOutput,
    transferCap = transferCap,
    sensorOk = sensorOk,
    computer = os.getComputerID(),
  }

  if displayId then
    rednet.send(displayId, msg, PROTOCOL)
    print("Sent: in " .. tostring(input) .. " out " .. tostring(output))
  end

  sleep(1)
end

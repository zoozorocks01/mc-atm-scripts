local PROTOCOL = "atm10-power-v1"
local DISPLAY_HOSTNAME = "display"
local MODEM_SIDE = "top"
local INDUCTION_SIDE = "bottom"

rednet.open(MODEM_SIDE)

local port = peripheral.wrap(INDUCTION_SIDE)
if not port then error("No induction port on " .. INDUCTION_SIDE) end

local displayId = nil
local ticks = 0
local previousEnergy = nil
local previousTime = nil
local lastNonzeroInput = 0
local lastNonzeroOutput = 0

local function call(name)
  if port[name] then
    local ok, value = pcall(port[name])
    if ok then return tonumber(value) or value end
  end
  return 0
end

local function getPercent(energy, maxEnergy)
  local p = call("getEnergyFilledPercentage")
  p = tonumber(p) or 0

  if p > 0 and p <= 1 then return p * 100 end
  if p > 1 and p <= 100 then return p end

  if maxEnergy and maxEnergy > 0 then
    return (energy / maxEnergy) * 100
  end

  return 0
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

  if not displayId or ticks % 30 == 1 then
    findDisplay()
  end

  local energy = tonumber(call("getEnergy")) or 0
  local maxEnergy = tonumber(call("getMaxEnergy")) or 0
  local input = tonumber(call("getLastInput")) or 0
  local output = tonumber(call("getLastOutput")) or 0
  local transferCap = tonumber(call("getTransferCap")) or 0
  local estimatedNet = estimateNet(energy)

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
    computer = os.getComputerID(),
  }

  if displayId then
    rednet.send(displayId, msg, PROTOCOL)
    print("Sent: in " .. tostring(input) .. " out " .. tostring(output))
  end

  sleep(1)
end

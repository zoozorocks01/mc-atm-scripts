local PROTOCOL = "atm10-power-v1"
local DISPLAY_HOSTNAME = "display"
local MODEM_SIDE = "top"
local INDUCTION_SIDE = "bottom"

rednet.open(MODEM_SIDE)

local port = peripheral.wrap(INDUCTION_SIDE)
if not port then error("No induction port on " .. INDUCTION_SIDE) end

local displayId = nil
local ticks = 0

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

while true do
  ticks = ticks + 1

  if not displayId or ticks % 30 == 1 then
    findDisplay()
  end

  local energy = call("getEnergy")
  local maxEnergy = call("getMaxEnergy")
  local input = call("getLastInput")
  local output = call("getLastOutput")
  local transferCap = call("getTransferCap")

  local msg = {
    kind = "power_sample",
    energy = energy,
    maxEnergy = maxEnergy,
    percent = getPercent(energy, maxEnergy),
    input = input,
    output = output,
    transferCap = transferCap,
    computer = os.getComputerID(),
  }

  if displayId then
    rednet.send(displayId, msg, PROTOCOL)
    print("Sent: in " .. tostring(input) .. " out " .. tostring(output))
  end

  sleep(1)
end

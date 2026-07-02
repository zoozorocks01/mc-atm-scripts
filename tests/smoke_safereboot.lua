-- Off-CC smoke for safereboot's drain handshake:
--   safereboot writes a drain request, waits for a fresh manager heartbeat to ack,
--   treats an outstanding AP job as unsafe, then reboots only after it settles.
--
-- Run: lua tests/smoke_safereboot.lua
package.path = "./lib/?.lua;./tests/?.lua;" .. package.path

local failures = 0
local function check(cond, msg)
  if cond then print("  ok: " .. msg) else failures = failures + 1; print("  FAIL: " .. msg) end
end

local realOs = os
local COLOR_NAMES = {
  "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
  "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black",
}
_G.colors = {}
for i, name in ipairs(COLOR_NAMES) do _G.colors[name] = 2 ^ (i - 1) end

local function smokeSerialize(value, seen)
  local t = type(value)
  if t == "nil" or t == "boolean" or t == "number" then return tostring(value) end
  if t == "string" then return string.format("%q", value) end
  if t ~= "table" then error("cannot serialize " .. t) end
  seen = seen or {}
  if seen[value] then error("recursive table") end
  seen[value] = true
  local keys, parts = {}, {}
  for k in pairs(value) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = "[" .. smokeSerialize(k, seen) .. "]=" .. smokeSerialize(value[k], seen)
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

_G.textutils = {
  serialize = smokeSerialize,
  unserialize = function(text)
    if type(text) ~= "string" then return nil end
    local chunk = load("return " .. text, "smoke-safereboot", "t", {})
    if not chunk then return nil end
    local ok, data = pcall(chunk)
    if ok then return data end
    return nil
  end,
}

local files = { [".atm10-heartbeat"] = "100000" }
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  open = function(p, mode)
    if mode == "r" then
      if not files[p] then return nil end
      local text, read = files[p], false
      return {
        readAll = function() if read then return nil end; read = true; return text end,
        close = function() end,
      }
    end
    return {
      write = function(s) files[p .. ".__pending"] = s end,
      close = function() files[p] = files[p .. ".__pending"]; files[p .. ".__pending"] = nil end,
    }
  end,
}

local now = 100000
local rebooted = false
local SENTINEL = "__SAFEREBOOT_DONE__"
_G.os = {
  epoch = function() return now end,
  clock = realOs.clock,
  exit = realOs.exit,
  reboot = function() rebooted = true; error(SENTINEL, 0) end,
}

local jobSettled = false
local getTaskCalls = 0
local bridge = {
  getCraftingTasks = function() return {} end,
  getCraftingTask = function()
    getTaskCalls = getTaskCalls + 1
    if jobSettled then return nil end
    return { getDebugMessage = function() return "CALCULATION_STARTED" end }
  end,
}
_G.peripheral = {
  getNames = function() return { "rs_bridge_0" } end,
  getType = function() return "rs_bridge" end,
  wrap = function() return bridge end,
}

local sleeps = 0
local renewals = {} -- drain-request snapshots taken each poll (renewal liveness)
_G.sleep = function(seconds)
  sleeps = sleeps + 1
  local req = textutils.unserialize(files[".atm10-drain-request"]) or {}
  renewals[#renewals + 1] = { renewedAt = tonumber(req.renewedAt), requestedAt = req.requestedAt }
  now = now + ((tonumber(seconds) or 0) * 1000)
  if sleeps == 1 then
    local req = textutils.unserialize(files[".atm10-drain-request"])
    files[".atm10-craftstate"] = textutils.serialize({
      drainAck = true,
      drainRequestAt = req and req.requestedAt,
      lastCraftAt = now - 121000,
      outstanding = { { id = 77, name = "alltheores:zinc_ingot" } },
    })
  elseif sleeps == 2 then
    jobSettled = true
  end
end

print("smoke-safereboot: drain ack + outstanding AP job safety")
local ok, err = pcall(function() dofile("safereboot.lua") end)
check(ok == false and tostring(err):find(SENTINEL, 1, true) ~= nil,
  "safereboot eventually rebooted through the guarded path: " .. tostring(err))
check(files[".atm10-drain-request"] ~= nil,
  "safereboot wrote the drain request flag")
check(sleeps >= 2,
  "safereboot waited before rebooting (ack wait + outstanding AP job)")
check(getTaskCalls >= 2,
  "safereboot polled getCraftingTask for the persisted AP job id")
check(rebooted == true,
  "safereboot called os.reboot only after the drain checks passed")
check(#renewals >= 2 and renewals[1].renewedAt ~= nil
  and renewals[#renewals].renewedAt ~= nil
  and renewals[#renewals].renewedAt > renewals[1].renewedAt,
  "safereboot RENEWS the drain request every poll (an aborted run goes stale for the manager)")
check(renewals[#renewals].requestedAt == renewals[1].requestedAt,
  "safereboot renewals keep requestedAt stable so the manager's ack still matches")

print((failures == 0) and "SMOKE-SAFEREBOOT OK" or ("SMOKE-SAFEREBOOT FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)

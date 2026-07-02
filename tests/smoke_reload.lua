-- Off-CC smoke for atm10-reload:
--   writes drain/reload request, waits for manager handoff, clears cached atm10
--   modules, then starts the normal startup wrapper.
--
-- Run: lua tests/smoke_reload.lua
package.path = "./lib/?.lua;./tests/?.lua;" .. package.path

local failures = 0
local function check(cond, msg)
  if cond then print("  ok: " .. msg) else failures = failures + 1; print("  FAIL: " .. msg) end
end

local realOs = os

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
    local chunk = load("return " .. text, "smoke-reload", "t", {})
    if not chunk then return nil end
    local ok, data = pcall(chunk)
    if ok then return data end
    return nil
  end,
}

local now = 100000
local files = { [".atm10-heartbeat"] = tostring(now) }
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
  delete = function(p) files[p] = nil end,
}

_G.os = {
  epoch = function() return now end,
  clock = realOs.clock,
  exit = realOs.exit,
}

local sleeps = 0
_G.sleep = function(seconds)
  sleeps = sleeps + 1
  now = now + ((tonumber(seconds) or 0) * 1000)
  if sleeps == 1 then
    local req = textutils.unserialize(files[".atm10-drain-request"])
    files[".atm10-craftstate"] = textutils.serialize({
      drainAck = true,
      reloadAck = true,
      drainRequestAt = req and req.requestedAt,
    })
    files[".atm10-heartbeat"] = nil
  end
end

local shellRuns = {}
_G.shell = {
  run = function(program)
    shellRuns[#shellRuns + 1] = program
    return true
  end,
}

package.loaded["atm10-status"] = { stale = true }
package.loaded["atm10-control"] = { stale = true }
package.loaded["not-atm10"] = { keep = true }

print("smoke-reload: cache clear + startup rerun")
local ok, err = pcall(function() dofile("atm10-reload.lua") end)
check(ok == true, "atm10-reload completed without throwing: " .. tostring(err))
check(files[".atm10-drain-request"] == nil and files[".atm10-reload-request"] == nil,
  "atm10-reload cleaned up request marker files before restart")
check(sleeps >= 1,
  "atm10-reload waited for the manager drain/stopped handoff")
check(package.loaded["atm10-status"] == nil and package.loaded["atm10-control"] == nil,
  "atm10-reload cleared cached atm10-* modules")
check(package.loaded["not-atm10"] ~= nil,
  "atm10-reload left unrelated package.loaded entries alone")
check(#shellRuns == 1 and shellRuns[1] == "startup",
  "atm10-reload starts the normal startup wrapper once")

print((failures == 0) and "SMOKE-RELOAD OK" or ("SMOKE-RELOAD FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)

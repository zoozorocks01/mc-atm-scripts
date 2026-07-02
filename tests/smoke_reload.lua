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
local sleepDrainReq = nil -- drain request as the manager would see it mid-wait
_G.sleep = function(seconds)
  sleeps = sleeps + 1
  now = now + ((tonumber(seconds) or 0) * 1000)
  if sleeps == 1 then
    local req = textutils.unserialize(files[".atm10-drain-request"])
    sleepDrainReq = req
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
check(sleepDrainReq ~= nil and tonumber(sleepDrainReq.renewedAt) ~= nil,
  "atm10-reload stamps renewedAt on the drain request (manager freshness gate input)")

-- ---- wrapper: a FRESH reload flag makes the startup wrapper exit for reload ----
-- The wrapper is what atm10-reload hands control back to; it must exit (not
-- restart) only while a live reload is actually in flight.
_G.colors = { white = 1, orange = 2, yellow = 4, red = 8 }
_G.term = { clear = function() end, setCursorPos = function() end, setTextColor = function() end }
_G.parallel = { waitForAny = function(a) a() end }
_G.sleep = function() end

files = { [".atm10-heartbeat"] = tostring(now), [".atm10-reload-request"] = tostring(now) }
local freshRuns = 0
_G.shell = { run = function(program) freshRuns = freshRuns + 1; return true end }
print("smoke-reload: wrapper exits for a FRESH reload flag")
local wOk, wErr = pcall(function() dofile("inventory/manager-startup.lua") end)
check(wOk == true, "wrapper returned cleanly for a fresh reload flag: " .. tostring(wErr))
check(freshRuns == 1, "wrapper ran the program once, then exited for reload")
check(files[".atm10-reload-request"] ~= nil,
  "wrapper leaves the fresh reload flag for atm10-reload to clean up")
check(files[".atm10-heartbeat"] == nil,
  "wrapper dropped the heartbeat so atm10-reload sees the manager as stopped")

-- ---- wrapper: a STALE reload flag must NOT strand the watchdog -----------------
-- If atm10-reload was aborted mid-flight, its flag stops being renewed. On the
-- manager's NEXT natural stop (days later), the wrapper must delete the stale
-- flag and keep restarting -- exiting for it would silently kill the watchdog.
files = { [".atm10-reload-request"] = tostring(now - 3600000) }
local staleRuns = 0
_G.shell = {
  run = function(program)
    staleRuns = staleRuns + 1
    if staleRuns >= 2 then error("Terminated", 0) end -- end the test loop via Ctrl+T path
    return true
  end,
}
print("smoke-reload: wrapper ignores + deletes a STALE reload flag")
local sOk, sErr = pcall(function() dofile("inventory/manager-startup.lua") end)
check(sOk == false and tostring(sErr) == "Terminated",
  "wrapper kept looping past the stale flag (ended by the scripted Ctrl+T): " .. tostring(sErr))
check(staleRuns == 2,
  "wrapper RESTARTED the program after a stale reload flag instead of exiting")
check(files[".atm10-reload-request"] == nil,
  "wrapper deleted the stale reload flag (dead requester)")

print((failures == 0) and "SMOKE-RELOAD OK" or ("SMOKE-RELOAD FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)

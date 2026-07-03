-- Off-CC smoke for atm10-patterns.lua. Unit tests cover the pure helpers; this
-- runs the deployed script against a stubbed RS Bridge so file wiring stays honest.
--
-- Run: lua tests/smoke_patterns.lua
package.path = "./lib/?.lua;./?.lua;./tests/?.lua;" .. package.path

local realDofile = dofile
local realPrint = print
local failures = 0

local function check(cond, msg)
  if cond then realPrint("  ok: " .. msg) else failures = failures + 1; realPrint("  FAIL: " .. msg) end
end

local files = {}
_G.fs = {
  exists = function(path) return files[path] ~= nil end,
  open = function(path, mode)
    if mode == "r" then
      local content = files[path]
      if content == nil then return nil end
      return { readAll = function() return content end, close = function() end }
    end
    if mode == "w" then
      files[path] = ""
      return {
        write = function(s) files[path] = files[path] .. tostring(s or "") end,
        close = function() end,
      }
    end
    return nil
  end,
}

_G.textutils = {
  unserialize = function() return nil end,
}

local bridge = {
  getCraftableItems = function()
    return {
      { name = "minecraft:glass", displayName = "Glass" },
    }
  end,
  getItems = function()
    return {
      { name = "minecraft:glass", displayName = "Glass" },
      { name = "alltheores:steel_ingot", displayName = "Steel Ingot" },
      { name = "modern_industrialization:motor", displayName = "Motor" },
    }
  end,
}

_G.peripheral = {
  getNames = function() return { "bottom" } end,
  getType = function(name) return name == "bottom" and "rs_bridge" or nil end,
  wrap = function(name) return name == "bottom" and bridge or nil end,
}

_G.dofile = function(path)
  if path == "inventory-config" then
    return {
      stockKeeper = {
        categories = {
          { label = "Base", items = {
            { name = "minecraft:glass", label = "Glass", target = 128 },
            { name = "alltheores:steel_ingot", label = "Steel", target = 128 },
            { name = "ghost:item", label = "Ghost", target = 1 },
            { name = "modern_industrialization:motor", label = "Motor", target = 1,
              craftMode = "watch", blockReason = "machine route" },
          } },
        },
      },
    }
  end
  return realDofile(path)
end

_G.print = function() end

local ok, err = pcall(function() realDofile("atm10-patterns.lua") end)

_G.dofile = realDofile
_G.print = realPrint

check(ok, "atm10-patterns ran under stubbed bridge: " .. tostring(err))
check((files[".atm10-pattern-ids.txt"] or "") == "alltheores:steel_ingot",
  "pattern IDs include only known, non-craftable quota IDs")
check((files[".atm10-pattern-unknown-ids.txt"] or "") == "ghost:item",
  "unknown/not-in-grid IDs are written separately")
check((files[".atm10-patterns-needed.txt"] or ""):find("UNKNOWN / NOT IN GRID", 1, true) ~= nil,
  "full worklist explains the unknown-ID bucket")
check((files[".atm10-patterns-needed.txt"] or ""):find("machine route", 1, true) ~= nil,
  "watch/machine route remains excluded from pattern targets but visible")

realPrint((failures == 0) and "SMOKE-PATTERNS OK" or ("SMOKE-PATTERNS FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)

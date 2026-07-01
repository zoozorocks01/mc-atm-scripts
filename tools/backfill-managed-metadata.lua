#!/usr/bin/env lua
-- Backfill route metadata onto an existing .atm10-managed store without changing
-- the user's quota numbers. Run from the repo root:
--   lua tools/backfill-managed-metadata.lua INFILE PRESET_ID [OUTFILE]

package.path = "./lib/?.lua;" .. package.path

local presets = require("atm10-presets")

local input, presetId, output = arg[1], arg[2], arg[3]
if not input or not presetId then
  io.stderr:write("usage: lua tools/backfill-managed-metadata.lua INFILE PRESET_ID [OUTFILE]\n")
  os.exit(2)
end
output = output or input

local function readAll(path)
  local fh, err = io.open(path, "r")
  if not fh then error(err or ("failed to open " .. path)) end
  local text = fh:read("*a")
  fh:close()
  return text
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function serialize(value, indent)
  indent = indent or 0
  local typ = type(value)
  if typ == "string" then return string.format("%q", value) end
  if typ == "number" or typ == "boolean" then return tostring(value) end
  if typ ~= "table" then return "nil" end

  local pad = string.rep("  ", indent)
  local childPad = string.rep("  ", indent + 1)
  local lines = { "{" }
  for _, key in ipairs(sortedKeys(value)) do
    local renderedKey
    if type(key) == "string" and key:match("^[%a_][%w_]*$") then
      renderedKey = key
    else
      renderedKey = "[" .. serialize(key, 0) .. "]"
    end
    lines[#lines + 1] = childPad .. renderedKey .. " = " .. serialize(value[key], indent + 1) .. ","
  end
  lines[#lines + 1] = pad .. "}"
  return table.concat(lines, "\n")
end

local text = readAll(input)
local chunk, err = load("return " .. text, "managed-store", "t", {})
if not chunk then error(err or "failed to parse managed store") end
local ok, storeOrErr = pcall(chunk)
if not ok then error(storeOrErr) end

local store, count = presets.backfillMetadata(storeOrErr, presetId)

local fh, writeErr = io.open(output, "w")
if not fh then error(writeErr or ("failed to open " .. output)) end
fh:write(serialize(store), "\n")
fh:close()

print(string.format("backfilled %d metadata row(s) from %s", count, presetId))

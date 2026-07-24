-- Updater replacement transaction: a failed staged move must restore the old file.
local files = { ["atm10-status.lua"] = "old-status" }
local failTarget = "atm10-status.lua"

_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  getDir = function() return "" end,
  makeDir = function() end,
  delete = function(p) files[p] = nil end,
  move = function(from, to)
    if from == failTarget .. ".new" and to == failTarget then error("injected move failure", 0) end
    if files[from] == nil then error("missing " .. from, 0) end
    if files[to] ~= nil then error("destination exists " .. to, 0) end
    files[to], files[from] = files[from], nil
  end,
  open = function(p, mode)
    if mode == "r" then
      return { readAll = function() return files[p] end, close = function() end }
    end
    local out = {}
    return { write = function(s) out[#out + 1] = s end, close = function() files[p] = table.concat(out) end }
  end,
}
_G.shell = { run = function(cmd, _, target)
  if cmd == "wget" then files[target] = "new-file"; return true end
  return true
end }

local chunk = assert(loadfile("atm10-update.lua"))
local ok, err = pcall(chunk, "power-display")
assert(not ok and tostring(err):find("Replace failed", 1, true), "injected replacement failure must stop update")
assert(files[failTarget] == "old-status", "failed replacement must restore the previous live file")
assert(files[failTarget .. ".old"] == nil, "backup must not remain after immediate restore")
assert(files[failTarget .. ".new"] == "new-file", "verified staged replacement remains for a future retry")
print("SMOKE-UPDATE OK")

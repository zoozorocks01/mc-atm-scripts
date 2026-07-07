-- atm10-approve: terminal fallback for approving one manager Plan row.
-- Usage: atm10-approve aluminum
-- The running manager owns the live queue; this command only writes a short
-- request file that the manager consumes during its normal loop.

local REQUEST_FILE = ".atm10-approve-request"

local args = { ... }
local target = table.concat(args, " "):gsub("^%s+", ""):gsub("%s+$", "")

if target == "" then
  print("Usage: atm10-approve <label or item id>")
  print("Example: atm10-approve aluminum")
  return
end

local function nowMs()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

local function writeAtomic(path, value)
  local tmp = path .. ".tmp"
  if fs.exists(tmp) then fs.delete(tmp) end
  local file = fs.open(tmp, "w")
  if not file then return false, "open failed" end
  file.write(textutils.serialize(value))
  file.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

local ok, err = writeAtomic(REQUEST_FILE, {
  target = target,
  requestedAt = nowMs(),
})

if ok then
  print("Approval requested: " .. target)
  print("Manager will consume it on the next scan.")
else
  print("Approval request failed: " .. tostring(err))
end

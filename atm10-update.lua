local BASE_URL = "https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/"
local ROLE_FILE = ".atm10-role"

local roles = {
  ["power-display"] = {
    label = "atm10-power-display",
    files = {
      { remote = "power-display.lua", localName = "power-display" },
      { remote = "display-startup.lua", localName = "startup" },
    },
  },
  ["power-probe"] = {
    label = "atm10-power-probe",
    files = {
      { remote = "power-probe.lua", localName = "power-probe" },
      { remote = "probe-startup.lua", localName = "startup" },
    },
  },
  ["inventory-source"] = {
    label = "atm10-inventory-info",
    files = {
      { remote = "inventory-info.lua", localName = "inventory-info" },
      { remote = "inventory-startup.lua", localName = "startup" },
      { remote = "inventory-config.lua", localName = "inventory-config", onlyIfMissing = true },
    },
  },
  ["inventory-remote"] = {
    label = "atm10-inventory-remote",
    files = {
      { remote = "inventory-remote.lua", localName = "inventory-remote" },
      { remote = "inventory-remote-startup.lua", localName = "startup" },
    },
  },
}

local args = { ... }

local function cacheBust()
  if os.epoch then return tostring(os.epoch("utc")) end
  return tostring(math.floor(os.clock() * 1000))
end

local function readRole()
  if not fs.exists(ROLE_FILE) then return nil end
  local file = fs.open(ROLE_FILE, "r")
  local value = file.readAll()
  file.close()
  return value and value:gsub("%s+", "") or nil
end

local function writeRole(role)
  local file = fs.open(ROLE_FILE, "w")
  file.write(role)
  file.close()
end

local function printUsage()
  print("Usage:")
  print("  update power-display")
  print("  update power-probe")
  print("  update inventory-source")
  print("  update inventory-remote")
  print("")
  print("After role is set, just run: update")
end

local function download(remote, localName)
  local tmp = localName .. ".new"
  local url = BASE_URL .. remote .. "?v=" .. cacheBust()

  if fs.exists(tmp) then fs.delete(tmp) end

  print("Downloading " .. remote .. " -> " .. localName)
  local ok = shell.run("wget", url, tmp)
  if not ok or not fs.exists(tmp) then
    error("Download failed: " .. remote, 0)
  end

  if fs.exists(localName) then fs.delete(localName) end
  fs.move(tmp, localName)
end

local function shouldSkip(file)
  return file.onlyIfMissing and fs.exists(file.localName)
end

local role = args[1] or readRole()
if not role or role == "help" or role == "--help" then
  printUsage()
  return
end

local config = roles[role]
if not config then
  print("Unknown role: " .. tostring(role))
  printUsage()
  return
end

writeRole(role)
print("ATM10 role: " .. role)

for _, file in ipairs(config.files) do
  if shouldSkip(file) then
    print("Keeping existing " .. file.localName)
  else
    download(file.remote, file.localName)
  end
end

download("atm10-update.lua", "update")

if config.label then
  shell.run("label", "set", config.label)
end

print("")
print("Update complete.")
print("Run reboot to restart with the new files.")

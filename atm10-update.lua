local BASE_URL = "https://raw.githubusercontent.com/zoozorocks01/mc-atm-scripts/main/"
local ROLE_FILE = ".atm10-role"

local commonFiles = {
  { remote = "lib/atm10-status.lua", localName = "atm10-status.lua" },
  { remote = "lib/atm10-palette.lua", localName = "atm10-palette.lua" },
  { remote = "lib/atm10-draw.lua", localName = "atm10-draw.lua" },
  { remote = "lib/atm10-control.lua", localName = "atm10-control.lua" },
  { remote = "lib/atm10-stockplan.lua", localName = "atm10-stockplan.lua" },
  { remote = "lib/atm10-queue.lua", localName = "atm10-queue.lua" },
  { remote = "lib/atm10-craftrunner.lua", localName = "atm10-craftrunner.lua" },
  { remote = "lib/atm10-managed.lua", localName = "atm10-managed.lua" },
  { remote = "lib/atm10-balance.lua", localName = "atm10-balance.lua" },
  { remote = "lib/atm10-suggest.lua", localName = "atm10-suggest.lua" },
  { remote = "lib/atm10-power.lua", localName = "atm10-power.lua" },
  { remote = "lib/atm10-presets.lua", localName = "atm10-presets.lua" },
  { remote = "lib/atm10-console.lua", localName = "atm10-console.lua" },
  { remote = "atm10-bridge-probe.lua", localName = "atm10-bridge-probe" }, -- READ-ONLY RS Bridge diagnostic
  { remote = "atm10-patterns.lua", localName = "atm10-patterns" }, -- READ-ONLY patterns worklist (CRAFT-4)
  { remote = "safereboot.lua", localName = "safereboot" }, -- drain-safe reboot (avoids AP detach crash)
  { remote = "atm10-theme", localName = "atm10-theme", onlyIfMissing = true },
}

local roles = {
  ["power-display"] = {
    label = "atm10-power-display",
    files = {
      { remote = "power/display.lua", localName = "power-display" },
      { remote = "power/display-startup.lua", localName = "startup" },
    },
  },
  ["power-probe"] = {
    label = "atm10-power-probe",
    files = {
      { remote = "power/probe.lua", localName = "power-probe" },
      { remote = "power/probe-startup.lua", localName = "startup" },
    },
  },
  ["inventory-source"] = {
    label = "atm10-inventory-info",
    files = {
      { remote = "inventory/manager.lua", localName = "inventory-info" },
      { remote = "inventory/manager-startup.lua", localName = "startup" },
      { remote = "reboot-guard.lua", localName = "reboot" }, -- shadow `reboot` -> safereboot (manager only)
      { remote = "inventory/config-example.lua", localName = "inventory-config-example" },
      { remote = "inventory/config.lua", localName = "inventory-config", onlyIfMissing = true },
    },
  },
  ["inventory-remote"] = {
    label = "atm10-inventory-remote",
    files = {
      { remote = "inventory/remote.lua", localName = "inventory-remote" },
      { remote = "inventory/remote-startup.lua", localName = "startup" },
      { remote = "atm10-display", localName = "atm10-display", onlyIfMissing = true },
    },
  },
}

local function filesForRole(roleConfig)
  local files = {}
  for _, file in ipairs(commonFiles) do files[#files + 1] = file end
  for _, file in ipairs(roleConfig.files or {}) do files[#files + 1] = file end
  return files
end

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
  -- Atomic: write to a tmp then move over, so the live role file is never left
  -- truncated/empty if a crash interrupts the write (open "w" truncates at once).
  local tmp = ROLE_FILE .. ".new"
  local file = fs.open(tmp, "w")
  file.write(role)
  file.close()
  if fs.exists(ROLE_FILE) then fs.delete(ROLE_FILE) end
  fs.move(tmp, ROLE_FILE)
end

local function ensureParentDir(path)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
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

  ensureParentDir(localName)

  -- Self-heal: if a prior run crashed in the tiny window between deleting the live
  -- script and moving the freshly-downloaded replacement into place, the verified
  -- replacement is still staged in tmp while localName is missing. Finish that move
  -- BEFORE deleting tmp to re-download, so an interrupted update can't leave the
  -- computer with a deleted-but-unreplaced script. (localName is only ever deleted
  -- below AFTER tmp is verified complete, so "localName missing + tmp present" means
  -- tmp is the complete replacement.)
  if not fs.exists(localName) and fs.exists(tmp) then
    fs.move(tmp, localName)
  end

  if fs.exists(tmp) then fs.delete(tmp) end

  print("Downloading " .. remote .. " -> " .. localName)
  local ok = shell.run("wget", url, tmp)
  if not ok or not fs.exists(tmp) then
    error("Download failed: " .. remote, 0)
  end

  -- The replacement is fully downloaded + verified above; only now replace the live
  -- script. CC's fs.move won't overwrite, so the delete is unavoidable; the staged
  -- tmp + self-heal above make that one-rename gap recoverable on the next run.
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

for _, file in ipairs(filesForRole(config)) do
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
-- Use safereboot, NOT reboot: rebooting while AdvancedPeripherals still has a
-- craft job pending crashes the whole server (NotAttachedException). safereboot
-- waits out the craft drain first; on a viewer/power computer it reboots at once.
print("Run safereboot to restart safely (NOT reboot).")

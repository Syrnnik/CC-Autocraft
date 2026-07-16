local Roles = require("lib.roles")
local UI = require("lib.ui")
local Updater = require("lib.updater")

local function findMonitor()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "monitor") then
      return name
    end
  end
end

local monName = Roles.getPort("monitor")
if not monName or not peripheral.isPresent(monName) then
  monName = findMonitor()
end

-- Update check: on a pending update the monitor shows Skip / Install and
-- the choice is made by touch (or 0/1 on the terminal). A failed check
-- (no http, GitHub down) never blocks startup.
local info, checkErr = Updater.check("computer")
if info and info.hasUpdate then
  if Updater.promptMonitor(monName, info) then
    print("Installing update...")
    local runningPath = shell.getRunningProgram()
    local installDir = fs.getDir(runningPath)
    local ok, err = Updater.install(info, installDir)
    if ok then
      -- Keep a renamed entry point (e.g. startup.lua) on the new version.
      Updater.syncEntry(installDir, "monitor.lua", runningPath)
      print("Update installed. Rebooting...")
      os.sleep(1)
      os.reboot()
    end
    printError("Update failed: " .. tostring(err))
    os.sleep(2)
  end
elseif checkErr then
  print("Update check skipped: " .. tostring(checkErr))
end

UI.run(monName)

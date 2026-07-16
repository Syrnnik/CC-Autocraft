local Config = require("lib.config")
local Logger = require("lib.logger")
local Screen = require("lib.screen")
local Network = require("lib.network")
local Updater = require("lib.updater")

local networkEvents = Config.NETWORK_EVENTS

Screen.clearAndReset()

-- Update check: prompts 0 = Skip, 1 = Install in the terminal. A failed
-- check (no http, GitHub down) never blocks startup.
local info, checkErr = Updater.check("crafter")
if info and info.hasUpdate then
  if Updater.promptTerminal(info) then
    print("Installing update...")
    local runningPath = shell.getRunningProgram()
    local installDir = fs.getDir(runningPath)
    local ok, err = Updater.install(info, installDir)
    if ok then
      -- Keep a renamed entry point (e.g. startup.lua) on the new version.
      Updater.syncEntry(installDir, "crafter.lua", runningPath)
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

Network.prepareModem("right", true)

Logger.printInfo("Waiting for events..")
while true do
  local senderID, event = Network.receiveEvent()

  if senderID then
    if event == networkEvents.CRAFT then
      local isOK, error = turtle.craft()

      if not isOK then
        Logger.printWarning(error)
      end

      Network.sendEvent(senderID, error)
    else
      Logger.printWarning("Unknown event:", senderID, event)
    end
  end
end

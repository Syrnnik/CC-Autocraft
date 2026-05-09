local Config = require("lib.config")
local Logger = require("lib.logger")
local Screen = require("lib.screen")
local Network = require("lib.network")

local networkEvents = Config.NETWORK_EVENTS

Screen.clearAndReset()

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

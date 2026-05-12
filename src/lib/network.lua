local Logger = require("lib.logger")

local Network = {}

function Network.openModem(side)
  rednet.open(side)
end

function Network.prepareModem(side, isTurtle)
  local modem = peripheral.find("modem")
  if not modem then
    Logger.raiseError("Modem not found!!")
  end

  if isTurtle then
    local equipedItem = turtle.getEquippedRight()
    if not equipedItem then
      Logger.raiseError(
        "Equip modem on right slot!!",
        equipedItem and equipedItem.name
      )
    end
  end

  Network.openModem(side)
end

function Network.sendEvent(recepientID, eventName)
  Logger.printDebug(
    string.format("Sending event '%s' to '%s'", eventName or "ok", recepientID)
  )

  return rednet.send(recepientID, eventName)
end

function Network.receiveEvent(timeout)
  return rednet.receive(nil, timeout)
end

return Network

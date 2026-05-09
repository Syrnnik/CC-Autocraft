local Logger = require("lib.logger")
local Screen = require("lib.screen")
local Network = require("lib.network")
local Crafting = require("lib.crafting")

Screen.clearAndReset()

Network.prepareModem("bottom", false)

Logger.printInfo("Place recipe and press Enter..")
read()

Crafting.processNewCraft()

local Logger = require("lib.logger")
local Screen = require("lib.screen")
local Network = require("lib.network")
local Crafting = require("lib.crafting")

Screen.clearAndReset()

Network.prepareModem("bottom", false)

Logger.printInfo("Enter recipe name:")
local recipeName = read()

Logger.printInfo("Enter count:")
local count = read()

Crafting.craftItem(recipeName, tonumber(count))

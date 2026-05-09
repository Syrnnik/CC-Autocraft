local Logger = require("lib.logger")
local Screen = require("lib.screen")
local Recipes = require("lib.recipes")

Screen.clearAndReset()

local items = Recipes.getAllRecipesItems()

Logger.printInfo("All available recipes:")
for i, item in pairs(items) do
  Logger.printInfo(string.format("%d. %s", i, item))
end

local Logger = require("lib.logger")
local Screen = require("lib.screen")
local Recipes = require("lib.recipes")
local Utils = require("lib.utils")

Screen.clearAndReset()

Logger.printInfo("Enter recipe name:")
local recipeName = read()

local recipe = Recipes.getRecipe(recipeName)
print(recipe and Utils.serializeTable(recipe))

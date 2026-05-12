local Logger = require("lib.logger")
local Screen = require("lib.screen")
local Recipes = require("lib.recipes")

Screen.clearAndReset()

Logger.printInfo("Enter recipe name to delete:")
local recipeName = read()

Recipes.deleteRecipe(recipeName)

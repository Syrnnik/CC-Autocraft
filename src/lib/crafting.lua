local Config = require("lib.config")
local Logger = require("lib.logger")
local Network = require("lib.network")
local Planner = require("lib.planner")
local Recipes = require("lib.recipes")
local Stock = require("lib.stock")
local Utils = require("lib.utils")

local crafterName = Config.CRAFTER_NAME
local newRecipeInterfaceName = Config.NEW_RECIPE_INTERFACE_NAME

local crafterNetworkID = Config.CRAFTER_NETWORK_ID
local networkEvents = Config.NETWORK_EVENTS
local craftTimeout = Config.CRAFT_TIMEOUT
local clearCrafterBeforeCraft = Config.CLEAR_CRAFTER_BEFORE_CRAFT

local patternSize = Config.PATTERN_SIZE
local newRecipeInterfaceRowSize = Config.NEW_RECIPE_INTERFACE_ROW_SIZE

local stockName = Config.STOCK_NAME

local Crafting = {}

function Crafting.getSlotToPutItem()
  return math.ceil(newRecipeInterfaceRowSize / 2)
    + newRecipeInterfaceRowSize * math.floor(patternSize / 2)
end

function Crafting.pushItemsToCrafter(items, fromInterfaceName)
  local fromInterface = peripheral.wrap(fromInterfaceName)

  for _, item in pairs(items) do
    local itemName = item.name
    local itemSlot = item.slot
    local crafterSlot = item.crafterSlot

    Logger.printInfo(
      string.format("Pushing '%s' to crafter slot %d", itemName, crafterSlot)
    )

    local count =
      fromInterface.pushItems(crafterName, itemSlot, item.count, crafterSlot)

    if count == 0 then
      Logger.raiseError(
        string.format(
          "Failed to push '%s' from '%s' (%d) to '%s' (%d)",
          itemName,
          fromInterfaceName,
          itemSlot,
          crafterName,
          crafterSlot
        )
      )
    end
  end
end

function Crafting.returnRecipeItems(items, toInterfaceName)
  local toInterface = peripheral.wrap(toInterfaceName)

  Logger.printWarning(string.format("Returning items to '%s'", toInterfaceName))

  for _, item in pairs(items) do
    local crafterSlot = item.crafterSlot
    local count = toInterface.pullItems(crafterName, crafterSlot)

    if count == 0 then
      Logger.raiseError(
        string.format(
          "Failed to pull '%s' from '%s' (%d) to '%s'",
          item.name,
          crafterName,
          crafterSlot,
          toInterfaceName
        )
      )
    end
  end
end

function Crafting.getCraftedItem(toInterfaceName, isSpecificSlot)
  local toInterface = peripheral.wrap(toInterfaceName)

  local craftedItem, slot
  if isSpecificSlot then
    slot = Crafting.getSlotToPutItem()
  else
    slot = nil
  end

  Logger.printInfo(
    string.format("Getting crafted item from '%s'", toInterfaceName)
  )
  local count = toInterface.pullItems(crafterName, 1, nil, slot)
  if count == 0 then
    Logger.raiseError(
      string.format(
        "Failed to pull items from '%s' to '%s'",
        crafterName,
        toInterfaceName
      )
    )
  end

  if not slot then
    return
  end

  craftedItem = toInterface.getItemDetail(slot)
  Logger.printSuccess(
    string.format("Crafted '%s' x%d", craftedItem.name, craftedItem.count)
  )
  return craftedItem
end

function Crafting.craft(items, fromInterfaceName)
  if clearCrafterBeforeCraft then
    local fromInterface = peripheral.wrap(fromInterfaceName)
    for slot = 1, 16 do
      fromInterface.pullItems(crafterName, slot)
    end
  end

  Crafting.pushItemsToCrafter(items, fromInterfaceName)

  Network.sendEvent(crafterNetworkID, networkEvents.CRAFT)

  Logger.printDebug("Waiting for crafter..")
  local senderID, msg = Network.receiveEvent(craftTimeout)

  if not senderID then
    Logger.printError("Crafter did not respond (timeout or offline)")
    Crafting.returnRecipeItems(items, fromInterfaceName)
    Logger.raiseError()
  end

  if msg then
    Logger.printError(msg)
    Crafting.returnRecipeItems(items, fromInterfaceName)
    Logger.raiseError()
  end
end

-- Pull all items from the crafter back to the recipe interface
function Crafting.clearCrafter()
  local interface = peripheral.wrap(newRecipeInterfaceName)
  for slot = 1, 16 do
    interface.pullItems(crafterName, slot)
  end
  Logger.printInfo("Crafter cleared")
end

-- Push recipe pattern slots (and crafted-item slot) from the recipe interface
-- back to stock. Only touches the slots actually used for recipe input.
function Crafting.clearRecipeInterface()
  local stock = peripheral.wrap(stockName)

  local rowSize    = Config.NEW_RECIPE_INTERFACE_ROW_SIZE
  local pSize      = Config.PATTERN_SIZE
  local pStart     = Config.PATTERN_START

  -- Recipe pattern slots
  for row = 0, pSize - 1 do
    local rowStart = pStart + rowSize * row
    local rowEnd   = rowStart + pSize - 1
    for slot = rowStart, rowEnd do
      stock.pullItems(newRecipeInterfaceName, slot)
    end
  end

  -- Crafted-item result slot
  local craftedSlot = Crafting.getSlotToPutItem()
  stock.pullItems(newRecipeInterfaceName, craftedSlot)

  Logger.printInfo("Recipe interface cleared")
end

-- Craft from the recipe interface and return the items + crafted result
-- without saving anything. Raises an error on failure.
function Crafting.craftNewRecipe()
  Logger.printDebug(
    string.format("Getting items from '%s'", newRecipeInterfaceName)
  )
  local recipeItems = Recipes.getNewRecipeItems(newRecipeInterfaceName)

  if #recipeItems == 0 then
    Logger.raiseError("Items for new recipe not found")
  end
  Logger.printInfo("New recipe items:", Utils.serializeTable(recipeItems))

  Logger.printInfo("Crafting..")
  Crafting.craft(recipeItems, newRecipeInterfaceName)

  local craftedItem = Crafting.getCraftedItem(newRecipeInterfaceName, true)
  return recipeItems, craftedItem
end

-- Legacy entry point used by new_craft.lua (craft + auto-save)
function Crafting.processNewCraft()
  local recipeItems, craftedItem = Crafting.craftNewRecipe()
  local craftedItemName = craftedItem.name

  local isExists, _ = pcall(Recipes.getRecipe, craftedItemName)
  if not isExists then
    Recipes.saveRecipe(recipeItems, craftedItem)
  else
    Logger.printWarning(
      string.format("Recipe for '%s' already added", craftedItemName)
    )
  end
end

function Crafting.processCraft(recipe)
  local recipeItem = recipe.name
  local recipeCount = recipe.count

  Logger.printInfo(string.format("Crafting '%s' x%d", recipeItem, recipeCount))

  local stockItems = Stock.getItemsForRecipe(recipe)
  Crafting.craft(stockItems, stockName)
  Crafting.getCraftedItem(stockName, false)

  Logger.printSuccess(
    string.format("Crafted '%s' x%d", recipeItem, recipeCount)
  )
end

-- Entry point for multi-level crafting: builds a plan and executes it in order.
function Crafting.craftItem(recipeName, count)
  Logger.printInfo(string.format("Planning '%s' x%d..", recipeName, count))

  local plan = Planner.buildCraftPlan(recipeName, count)

  if #plan == 0 then
    Logger.raiseError(string.format("No recipe found for '%s'", recipeName))
  end

  Planner.printPlan(plan)

  local missing = Planner.validatePlan(plan)
  if #missing > 0 then
    Logger.printError("Missing items:")
    for _, item in pairs(missing) do
      Logger.printError(string.format("  - '%s' x%d", item.name, item.count))
    end
    Logger.raiseError()
  end

  for _, step in ipairs(plan) do
    Logger.printInfo(
      string.format("Crafting '%s' x%d craft(s)..", step.name, step.craftsCount)
    )
    for _ = 1, step.craftsCount do
      Crafting.processCraft(step.recipe)
    end
  end

  Logger.printSuccess(
    string.format("Done! Crafted '%s' x%d", recipeName, count)
  )
end

return Crafting

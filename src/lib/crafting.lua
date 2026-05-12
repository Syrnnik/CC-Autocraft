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
local patternStart = Config.PATTERN_START
local newRecipeInterfaceRowSize = Config.NEW_RECIPE_INTERFACE_ROW_SIZE

local stockName = Config.STOCK_NAME

local Crafting = {}

local function patternSlots()
  local slots = {}
  for row = 0, patternSize - 1 do
    local rowStart = patternStart + newRecipeInterfaceRowSize * row
    for slot = rowStart, rowStart + patternSize - 1 do
      table.insert(slots, slot)
    end
  end
  return slots
end

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

-- Returns items in the recipe interface pattern slots only (same grid used by
-- getNewRecipeItems). Ignores items in other slots (e.g. decoration stacks).
function Crafting.getInterfaceItems()
  local listing = peripheral.wrap(newRecipeInterfaceName).list()
  local items = {}
  for _, slot in ipairs(patternSlots()) do
    local item = listing[slot]
    if item then
      table.insert(items, { name = item.name, count = item.count, slot = slot })
    end
  end
  return items
end

-- Push machineItems from the recipe interface to their processors, wait for
-- a result to appear in resultProcessor, pull it back, then clear all machines.
function Crafting.craftNewMachineRecipe(machineItems, resultProcessor)
  local interface = peripheral.wrap(newRecipeInterfaceName)

  -- Items placed directly into the result machine (ignored during polling
  -- until they are transformed into the actual result).
  local inputsToResult = {}
  for _, item in pairs(machineItems) do
    if item.processor == resultProcessor then
      inputsToResult[item.name] = true
    end
  end

  for _, item in pairs(machineItems) do
    Logger.printInfo(
      string.format(
        "Pushing '%s' (slot %d) to '%s'",
        item.name,
        item.slot,
        item.processor
      )
    )
    local pushed = interface.pushItems(item.processor, item.slot, item.count)
    if pushed == 0 then
      Logger.raiseError(
        string.format("Failed to push '%s' to '%s'", item.name, item.processor)
      )
    end
  end

  -- Poll: wait until a non-input item appears in resultProcessor
  local steps = math.ceil(Config.MACHINE_CRAFT_TIMEOUT / 0.5)
  local destSlot = Crafting.getSlotToPutItem()
  local crafted = nil

  for _ = 1, steps do
    local listing = peripheral.wrap(resultProcessor).list()
    local resultSlot = nil
    for s, sItem in pairs(listing) do
      if not inputsToResult[sItem.name] then
        resultSlot = s
        break
      end
    end
    if resultSlot then
      interface.pullItems(resultProcessor, resultSlot, nil, destSlot)
      crafted = interface.getItemDetail(destSlot)
      break
    end
    os.sleep(0.5)
  end

  -- Always clear all machines (whether success or timeout)
  local seen = {}
  for _, item in pairs(machineItems) do
    if not seen[item.processor] then
      seen[item.processor] = true
      for slot, _ in pairs(peripheral.wrap(item.processor).list()) do
        interface.pullItems(item.processor, slot)
      end
    end
  end

  if not crafted then
    Logger.raiseError(
      "Machine craft timed out: no result from " .. resultProcessor
    )
  end

  return crafted
end

-- Execute one machine craft cycle from stock: push items to their processors,
-- wait for the result, pull it to stock, then clear all machines.
function Crafting.craftMachine(recipe)
  local stock = peripheral.wrap(stockName)
  local pushList = Stock.getItemsForMachineRecipe(recipe)

  -- Items placed directly into the result machine (ignored during polling)
  local inputsToResult = {}
  for _, item in pairs(recipe.items) do
    if item.processor == recipe.resultProcessor then
      inputsToResult[item.name] = true
    end
  end

  for _, item in pairs(pushList) do
    Logger.printInfo(
      string.format("Pushing '%s' to '%s'", item.name, item.processor)
    )
    local pushed = stock.pushItems(item.processor, item.slot, item.count)
    if pushed == 0 then
      Logger.raiseError(
        string.format("Failed to push '%s' to '%s'", item.name, item.processor)
      )
    end
  end

  -- Poll: wait until a non-input item appears in resultProcessor
  local steps = math.ceil(Config.MACHINE_CRAFT_TIMEOUT / 0.5)
  local got = false

  for _ = 1, steps do
    local listing = peripheral.wrap(recipe.resultProcessor).list()
    local resultSlot = nil
    for s, sItem in pairs(listing) do
      if not inputsToResult[sItem.name] then
        resultSlot = s
        break
      end
    end
    if resultSlot then
      for s, _ in pairs(peripheral.wrap(recipe.resultProcessor).list()) do
        stock.pullItems(recipe.resultProcessor, s)
      end
      got = true
      break
    end
    os.sleep(0.5)
  end

  -- Always clear all machines (whether success or timeout)
  local seen = {}
  for _, item in pairs(recipe.items) do
    if not seen[item.processor] then
      seen[item.processor] = true
      for slot, _ in pairs(peripheral.wrap(item.processor).list()) do
        stock.pullItems(item.processor, slot)
      end
    end
  end

  if not got then
    Logger.raiseError(
      "Machine craft timed out: no result from " .. recipe.resultProcessor
    )
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
  for _, slot in ipairs(patternSlots()) do
    stock.pullItems(newRecipeInterfaceName, slot)
  end
  stock.pullItems(newRecipeInterfaceName, Crafting.getSlotToPutItem())
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
  local recipeType = recipe.type or "crafter"
  local processor = recipe.processor or crafterName

  Logger.printInfo(
    string.format(
      "Crafting '%s' x%d [%s:%s]",
      recipeItem,
      recipeCount,
      recipeType,
      processor
    )
  )

  if recipeType == "machine" then
    Crafting.craftMachine(recipe)
  else
    local stockItems = Stock.getItemsForRecipe(recipe)
    Crafting.craft(stockItems, stockName)
    Crafting.getCraftedItem(stockName, false)
  end

  Logger.printSuccess(
    string.format("Crafted '%s' x%d", recipeItem, recipeCount)
  )
end

-- Entry point for multi-level crafting: builds a plan and executes it in order.
function Crafting.craftItem(recipeName, count)
  Logger.printInfo(string.format("Planning '%s' x%d..", recipeName, count))

  local totals, maxDmg = Stock.getDurabilityAwareTotals()
  local plan = Planner.buildCraftPlan(recipeName, count, totals)

  if #plan == 0 then
    Logger.raiseError(string.format("No recipe found for '%s'", recipeName))
  end

  Planner.printPlan(plan)

  local missing = Planner.validatePlan(plan, totals, maxDmg)
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

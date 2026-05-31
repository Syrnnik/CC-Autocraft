local Config = require("lib.config")
local Logger = require("lib.logger")
local Network = require("lib.network")
local Planner = require("lib.planner")
local Recipes = require("lib.recipes")
local Roles   = require("lib.roles")
local Stock   = require("lib.stock")
local Utils   = require("lib.utils")

-- Peripheral names read from Roles at call time (not module load time)
-- so that changes via the SETUP tab take effect without restart.
local function getCrafter()     return Roles.get("crafter")          end
local function interfaceName()  return Roles.get("recipe_interface") end
local function stockInName()    return Roles.get("stock_in")         end
local function stockOutName()   return Roles.get("stock_out")        end

local crafterNetworkID = Config.CRAFTER_NETWORK_ID
local networkEvents = Config.NETWORK_EVENTS
local craftTimeout = Config.CRAFT_TIMEOUT
local clearCrafterBeforeCraft = Config.CLEAR_CRAFTER_BEFORE_CRAFT

local patternSize = Config.PATTERN_SIZE
local patternStart = Config.PATTERN_START
local newRecipeInterfaceRowSize = Config.NEW_RECIPE_INTERFACE_ROW_SIZE

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
      fromInterface.pushItems(getCrafter(), itemSlot, item.count, crafterSlot)

    if count == 0 then
      Logger.raiseError(
        string.format(
          "Failed to push '%s' from '%s' (%d) to '%s' (%d)",
          itemName,
          fromInterfaceName,
          itemSlot,
          getCrafter(),
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
    local count = toInterface.pullItems(getCrafter(), crafterSlot)

    if count == 0 then
      Logger.raiseError(
        string.format(
          "Failed to pull '%s' from '%s' (%d) to '%s'",
          item.name,
          getCrafter(),
          crafterSlot,
          toInterfaceName
        )
      )
    end
  end
end

function Crafting.getCraftedItem(toInterfaceName, isSpecificSlot)
  local toInterface = peripheral.wrap(toInterfaceName)

  Logger.printInfo(
    string.format("Getting crafted item from '%s'", toInterfaceName)
  )

  if not isSpecificSlot then
    -- Pull everything from all crafter slots (batch craft fills multiple slots)
    for slot = 1, 16 do
      toInterface.pullItems(getCrafter(), slot)
    end
    return
  end

  local destSlot = Crafting.getSlotToPutItem()
  local count = toInterface.pullItems(getCrafter(), 1, nil, destSlot)
  if count == 0 then
    Logger.raiseError(
      string.format(
        "Failed to pull items from '%s' to '%s'",
        getCrafter(),
        toInterfaceName
      )
    )
  end

  local craftedItem = toInterface.getItemDetail(destSlot)
  Logger.printSuccess(
    string.format("Crafted '%s' x%d", craftedItem.name, craftedItem.count)
  )
  return craftedItem
end

function Crafting.craft(items, fromInterfaceName)
  if clearCrafterBeforeCraft then
    local fromInterface = peripheral.wrap(fromInterfaceName)
    for slot = 1, 16 do
      fromInterface.pullItems(getCrafter(), slot)
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
  local listing = peripheral.wrap(interfaceName()).list()
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
  local interface = peripheral.wrap(interfaceName())

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
  local stockIn  = peripheral.wrap(stockInName())
  local stockOut = peripheral.wrap(stockOutName())
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
    local pushed = stockIn.pushItems(item.processor, item.slot, item.count)
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
        stockOut.pullItems(recipe.resultProcessor, s)
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
        stockOut.pullItems(item.processor, slot)
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
  local interface = peripheral.wrap(interfaceName())
  for slot = 1, 16 do
    interface.pullItems(getCrafter(), slot)
  end
  Logger.printInfo("Crafter cleared")
end

-- Push recipe pattern slots (and crafted-item slot) from the recipe interface
-- back to stock. Only touches the slots actually used for recipe input.
function Crafting.clearRecipeInterface()
  local stock = peripheral.wrap(stockOutName())
  for _, slot in ipairs(patternSlots()) do
    stock.pullItems(interfaceName(), slot)
  end
  stock.pullItems(interfaceName(), Crafting.getSlotToPutItem())
  Logger.printInfo("Recipe interface cleared")
end

-- Craft from the recipe interface and return the items + crafted result
-- without saving anything. Raises an error on failure.
function Crafting.craftNewRecipe()
  Logger.printDebug(
    string.format("Getting items from '%s'", interfaceName())
  )
  local recipeItems = Recipes.getNewRecipeItems(interfaceName())

  if #recipeItems == 0 then
    Logger.raiseError("Items for new recipe not found")
  end
  Logger.printInfo("New recipe items:", Utils.serializeTable(recipeItems))

  Logger.printInfo("Crafting..")
  Crafting.craft(recipeItems, interfaceName())

  local craftedItem = Crafting.getCraftedItem(interfaceName(), true)
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

-- batchSize: craft batchSize recipe iterations in a single crafter call.
-- onEach(): called after each individual machine cycle, or once after a crafter batch.
function Crafting.processCraft(recipe, batchSize, onEach)
  batchSize = batchSize or 1
  local recipeItem = recipe.name
  local recipeCount = recipe.count
  local recipeType = recipe.type or "crafter"
  local processor = recipe.processor or getCrafter()

  Logger.printInfo(
    string.format(
      "Crafting '%s' x%d (batch %d) [%s:%s]",
      recipeItem,
      recipeCount,
      batchSize,
      recipeType,
      processor
    )
  )

  if recipeType == "machine" then
    for _ = 1, batchSize do
      Crafting.craftMachine(recipe)
      if onEach then onEach() end
    end
  else
    local stockItems = Stock.getItemsForRecipe(recipe, batchSize)
    Crafting.craft(stockItems, stockInName())
    Crafting.getCraftedItem(stockOutName(), false)
    if onEach then onEach() end
  end

  Logger.printSuccess(
    string.format("Crafted '%s' x%d", recipeItem, recipeCount * batchSize)
  )
end

-- Entry point for multi-level crafting: builds a plan and executes it in order.
-- onStep(current, total): called after each individual craft run (per machine cycle or crafter batch).
-- onPlan(plan): called once after the plan is built, before execution starts.
-- onStepDone(): called after each full plan step completes.
function Crafting.craftItem(recipeName, count, onStep, onPlan, onStepDone)
  Logger.printInfo(string.format("Planning '%s' x%d..", recipeName, count))

  local totals, maxDmg = Stock.getDurabilityAwareTotals()
  local plan = Planner.buildCraftPlan(recipeName, count, totals)

  if #plan == 0 then
    Logger.raiseError(string.format("No recipe found for '%s'", recipeName))
  end

  Planner.printPlan(plan)
  if onPlan then onPlan(plan) end

  local missing = Planner.validatePlan(plan, totals, maxDmg)
  if #missing > 0 then
    local lines = { "Missing items:" }
    for _, item in ipairs(missing) do
      local display = item.name:match("^[^:]+:(.+)") or item.name
      table.insert(lines, "- " .. display .. " x" .. item.count)
    end
    error(table.concat(lines, "\n"), 0)
  end

  -- Count total individual craft runs for per-item progress tracking.
  -- Machine steps contribute craftsCount runs; crafter steps always 1 (whole batch at once).
  local totalRuns = 0
  for _, step in ipairs(plan) do
    if (step.recipe.type or "crafter") == "machine" then
      totalRuns = totalRuns + step.craftsCount
    else
      totalRuns = totalRuns + 1
    end
  end

  local doneRuns = 0
  for _, step in ipairs(plan) do
    Logger.printInfo(
      string.format("Crafting '%s' x%d craft(s) as one batch..", step.name, step.craftsCount)
    )
    Crafting.processCraft(step.recipe, step.craftsCount, function()
      doneRuns = doneRuns + 1
      if onStep then onStep(doneRuns, totalRuns) end
    end)
    if onStepDone then onStepDone() end
  end

  Logger.printSuccess(
    string.format("Done! Crafted '%s' x%d", recipeName, count)
  )
end

-- Builds and returns the craft plan without executing it (for UI preview).
function Crafting.buildPlan(recipeName, count)
  local totals = Stock.getDurabilityAwareTotals()
  return Planner.buildCraftPlan(recipeName, count, totals)
end

return Crafting

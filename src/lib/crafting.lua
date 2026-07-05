local Config = require("lib.config")
local Labels = require("lib.labels")
local Logger = require("lib.logger")
local Network = require("lib.network")
local Planner = require("lib.planner")
local Recipes = require("lib.recipes")
local Roles = require("lib.roles")
local Stock = require("lib.stock")
local Utils = require("lib.utils")

-- Peripheral names read from Roles at call time (not module load time)
-- so that changes via the SETUP tab take effect without restart.
local function getCrafter()
  return Roles.getPort("crafter")
end
local function interfaceName()
  return Roles.getPort("recipe_interface")
end
local function stockInName()
  return Roles.getPort("stock_in")
end
local function stockOutName()
  return Roles.getPort("stock_out")
end

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
  local fromInterface = Utils.wrapPeripheral(fromInterfaceName)

  -- Push all slots concurrently; failures are collected and raised after.
  local failedItem = nil
  local tasks = {}
  for _, item in pairs(items) do
    tasks[#tasks + 1] = function()
      Logger.printInfo(
        string.format(
          "Pushing '%s' to crafter slot %d",
          item.name,
          item.crafterSlot
        )
      )
      local count = fromInterface.pushItems(
        getCrafter(),
        item.slot,
        item.count,
        item.crafterSlot
      )
      if count == 0 and not failedItem then
        failedItem = item
      end
    end
  end
  Utils.runParallel(tasks)

  if failedItem then
    Logger.raiseError(
      string.format(
        "Failed to push '%s' from '%s' (%d) to '%s' (%d)",
        failedItem.name,
        fromInterfaceName,
        failedItem.slot,
        getCrafter(),
        failedItem.crafterSlot
      )
    )
  end
end

function Crafting.returnRecipeItems(items, toInterfaceName)
  local toInterface = Utils.wrapPeripheral(toInterfaceName)

  Logger.printWarning(string.format("Returning items to '%s'", toInterfaceName))

  local failedItem = nil
  local tasks = {}
  for _, item in pairs(items) do
    tasks[#tasks + 1] = function()
      local count = toInterface.pullItems(getCrafter(), item.crafterSlot)
      if count == 0 and not failedItem then
        failedItem = item
      end
    end
  end
  Utils.runParallel(tasks)

  if failedItem then
    Logger.raiseError(
      string.format(
        "Failed to pull '%s' from '%s' (%d) to '%s'",
        failedItem.name,
        getCrafter(),
        failedItem.crafterSlot,
        toInterfaceName
      )
    )
  end
end

-- skipSlots: optional set { [crafterSlot] = true } of slots to leave in the crafter.
function Crafting.getCraftedItem(toInterfaceName, isSpecificSlot, skipSlots)
  local toInterface = Utils.wrapPeripheral(toInterfaceName)

  Logger.printInfo(
    string.format("Getting crafted item from '%s'", toInterfaceName)
  )

  if not isSpecificSlot then
    -- Pull everything from all crafter slots (batch craft fills multiple
    -- slots); all pulls run concurrently.
    local tasks = {}
    for slot = 1, 16 do
      if not (skipSlots and skipSlots[slot]) then
        local s = slot
        tasks[#tasks + 1] = function()
          toInterface.pullItems(getCrafter(), s)
        end
      end
    end
    Utils.runParallel(tasks)
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
    local fromInterface = Utils.wrapPeripheral(fromInterfaceName)
    local tasks = {}
    for slot = 1, 16 do
      local s = slot
      tasks[#tasks + 1] = function()
        fromInterface.pullItems(getCrafter(), s)
      end
    end
    Utils.runParallel(tasks)
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
  local listing = Utils.wrapPeripheral(interfaceName()).list()
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
  local interface = Utils.wrapPeripheral(interfaceName())

  -- Items placed directly into the result machine (ignored during polling
  -- until they are transformed into the actual result).
  local inputsToResult = {}
  for _, item in pairs(machineItems) do
    if item.processor == resultProcessor then
      inputsToResult[item.name] = true
    end
  end

  local failedItem = nil
  local pushTasks = {}
  for _, item in pairs(machineItems) do
    pushTasks[#pushTasks + 1] = function()
      Logger.printInfo(
        string.format(
          "Pushing '%s' (slot %d) to '%s'",
          item.name,
          item.slot,
          item.processor
        )
      )
      local pushed = interface.pushItems(item.processor, item.slot, item.count)
      if pushed == 0 and not failedItem then
        failedItem = item
      end
    end
  end
  Utils.runParallel(pushTasks)
  if failedItem then
    Logger.raiseError(
      string.format(
        "Failed to push '%s' to '%s'",
        failedItem.name,
        failedItem.processor
      )
    )
  end

  -- Poll: wait until a non-input item appears in resultProcessor
  local steps = math.ceil(Config.MACHINE_CRAFT_TIMEOUT / 0.5)
  local destSlot = Crafting.getSlotToPutItem()
  local crafted = nil

  for _ = 1, steps do
    local listing = Utils.wrapPeripheral(resultProcessor).list()
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

  -- Always clear all machines (whether success or timeout); one concurrent
  -- task per machine.
  local seen = {}
  local clearTasks = {}
  for _, item in pairs(machineItems) do
    if not seen[item.processor] then
      seen[item.processor] = true
      local proc = item.processor
      clearTasks[#clearTasks + 1] = function()
        for slot, _ in pairs(Utils.wrapPeripheral(proc).list()) do
          interface.pullItems(proc, slot)
        end
      end
    end
  end
  Utils.runParallel(clearTasks)

  if not crafted then
    Logger.raiseError(
      "Machine craft timed out: no result from " .. resultProcessor
    )
  end

  return crafted
end

-- Execute one machine craft cycle from stock: push items to their processors,
-- wait for the result, pull it to stock, then clear all machines.
-- batchSize: how many recipe cycles to run in one call.
--   Items are pushed to processors all at once; results are pulled one by one.
-- onEach(): called after each individual result is collected (for progress tracking).
function Crafting.craftMachine(recipe, batchSize, onEach)
  batchSize = batchSize or 1
  local stockIn = Utils.wrapPeripheral(stockInName())
  local stockOut = Utils.wrapPeripheral(stockOutName())
  local pushList = Stock.getItemsForMachineRecipe(recipe, batchSize)

  -- Resolve labels → port names once (Utils.wrapPeripheral will error if not found)
  local resultPort = Labels.resolvePort(recipe.resultProcessor)
  local portCache = {}
  local function resolveItemPort(proc)
    if not portCache[proc] then
      portCache[proc] = Labels.resolvePort(proc)
    end
    return portCache[proc]
  end

  -- Items placed directly into the result machine (ignored during polling)
  local inputsToResult = {}
  for _, item in pairs(recipe.items) do
    if item.processor == recipe.resultProcessor then
      inputsToResult[item.name] = true
    end
  end

  -- Push all items for the full batch at once, concurrently.
  for _, item in pairs(pushList) do
    if not item.processor then
      Logger.raiseError(
        string.format("No processor assigned for '%s' in recipe", item.name)
      )
    end
  end
  local failedItem, failedPort
  local pushTasks = {}
  for _, item in pairs(pushList) do
    local port = resolveItemPort(item.processor)
    pushTasks[#pushTasks + 1] = function()
      Logger.printInfo(
        string.format("Pushing '%s' x%d to '%s'", item.name, item.count, port)
      )
      local pushed = stockIn.pushItems(port, item.slot, item.count)
      if pushed == 0 and not failedItem then
        failedItem, failedPort = item, port
      end
    end
  end
  Utils.runParallel(pushTasks)
  if failedItem then
    Logger.raiseError(
      string.format("Failed to push '%s' to '%s'", failedItem.name, failedPort)
    )
  end

  -- Collect results until we have batchSize * recipe.count items.
  -- Multiple cycles may stack into one slot if the machine is fast, so we
  -- count items pulled (not slot pulls) to track progress correctly.
  local steps = math.ceil(Config.MACHINE_CRAFT_TIMEOUT / 0.5)
  local totalNeeded = batchSize * (recipe.count or 1)
  local itemsPulled = 0
  local cyclesDone = 0

  while itemsPulled < totalNeeded do
    local found = false
    for _ = 1, steps do
      local listing = Utils.wrapPeripheral(resultPort).list()
      local resultSlot = nil
      for s, sItem in pairs(listing) do
        if not inputsToResult[sItem.name] then
          resultSlot = s
          break
        end
      end
      if resultSlot then
        local n = stockOut.pullItems(resultPort, resultSlot)
        itemsPulled = itemsPulled + n
        local newCycles = math.floor(itemsPulled / (recipe.count or 1))
          - cyclesDone
        cyclesDone = cyclesDone + newCycles
        for _ = 1, newCycles do
          if onEach then
            onEach()
          end
        end
        found = true
        break
      end
      os.sleep(0.5)
    end
    if not found then
      Logger.raiseError(
        string.format(
          "Machine craft timed out: got %d/%d items from %s",
          itemsPulled,
          totalNeeded,
          resultPort
        )
      )
    end
  end

  -- Always clear all machines; one concurrent task per machine.
  local seen = {}
  local clearTasks = {}
  for _, item in pairs(recipe.items) do
    if item.processor and not seen[item.processor] then
      seen[item.processor] = true
      local port = resolveItemPort(item.processor)
      clearTasks[#clearTasks + 1] = function()
        for slot, _ in pairs(Utils.wrapPeripheral(port).list()) do
          stockOut.pullItems(port, slot)
        end
      end
    end
  end
  Utils.runParallel(clearTasks)
end

-- Pull all items from the crafter back to the recipe interface
function Crafting.clearCrafter()
  local interface = Utils.wrapPeripheral(interfaceName())
  local tasks = {}
  for slot = 1, 16 do
    local s = slot
    tasks[#tasks + 1] = function()
      interface.pullItems(getCrafter(), s)
    end
  end
  Utils.runParallel(tasks)
  Logger.printInfo("Crafter cleared")
end

-- Push recipe pattern slots (and crafted-item slot) from the recipe interface
-- back to stock. Only touches the slots actually used for recipe input.
function Crafting.clearRecipeInterface()
  local stock = Utils.wrapPeripheral(stockOutName())
  local tasks = {}
  for _, slot in ipairs(patternSlots()) do
    local s = slot
    tasks[#tasks + 1] = function()
      stock.pullItems(interfaceName(), s)
    end
  end
  tasks[#tasks + 1] = function()
    stock.pullItems(interfaceName(), Crafting.getSlotToPutItem())
  end
  Utils.runParallel(tasks)
  Logger.printInfo("Recipe interface cleared")
end

-- Craft from the recipe interface and return the items + crafted result
-- without saving anything. Raises an error on failure.
function Crafting.craftNewRecipe()
  Logger.printDebug(string.format("Getting items from '%s'", interfaceName()))
  local recipeItems = Recipes.getNewRecipeItems(interfaceName())

  if #recipeItems == 0 then
    Logger.raiseError("Items for new recipe not found")
  end
  Logger.printInfo("New recipe items:", Utils.serializeTable(recipeItems))

  Logger.printInfo("Crafting..")
  Crafting.craft(recipeItems, interfaceName())

  -- Auto-detect catalysts: pull 1 item from each recipe crafter slot back to
  -- its original interface slot. If the same item name returns, it wasn't
  -- consumed. Each slot's pull+inspect pair runs as its own concurrent task.
  local interface = Utils.wrapPeripheral(interfaceName())
  local catalystTasks = {}
  for _, item in ipairs(recipeItems) do
    catalystTasks[#catalystTasks + 1] = function()
      local pulled =
        interface.pullItems(getCrafter(), item.crafterSlot, 1, item.slot)
      if pulled > 0 then
        local detail = interface.getItemDetail(item.slot)
        if detail and detail.name == item.name then
          item.catalyst = true
          Logger.printInfo(
            string.format(
              "Catalyst detected: '%s' (crafter slot %d)",
              item.name,
              item.crafterSlot
            )
          )
        end
      end
    end
  end
  Utils.runParallel(catalystTasks)

  local craftedItem = Crafting.getCraftedItem(interfaceName(), true)
  return recipeItems, craftedItem
end

-- Legacy entry point used by new_craft.lua (craft + auto-save)
function Crafting.processNewCraft()
  local recipeItems, craftedItem = Crafting.craftNewRecipe()
  local craftedItemName = craftedItem.name

  local existing =
    Recipes.findExisting(craftedItemName, craftedItem.displayName)
  if not existing then
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
    local maxMachineBatch = Stock.getMaxBatchForMachineRecipe(recipe)
    local done = 0
    while done < batchSize do
      local chunk = math.min(maxMachineBatch, batchSize - done)
      Crafting.craftMachine(recipe, chunk, onEach)
      done = done + chunk
    end
  else
    local catalysts = Stock.getCatalystItemsForRecipe(recipe)
    local catalystSlots = {}
    for _, cat in ipairs(catalysts) do
      catalystSlots[cat.crafterSlot] = true
    end

    if #catalysts > 0 then
      Crafting.pushItemsToCrafter(catalysts, stockInName())
    end

    local maxBatch = Stock.getMaxBatchForRecipe(recipe)
    local done = 0
    local ok, err = pcall(function()
      while done < batchSize do
        local chunk = math.min(maxBatch, batchSize - done)
        local stockItems = Stock.getItemsForRecipe(recipe, chunk)
        Crafting.craft(stockItems, stockInName())
        Crafting.getCraftedItem(stockOutName(), false, catalystSlots)
        done = done + chunk
        if onEach then
          onEach()
        end
      end
    end)

    -- Always return catalysts to stock after the batch (or on error)
    if #catalysts > 0 then
      local stockOut = Utils.wrapPeripheral(stockOutName())
      local tasks = {}
      for _, cat in ipairs(catalysts) do
        local slot = cat.crafterSlot
        tasks[#tasks + 1] = function()
          stockOut.pullItems(getCrafter(), slot)
        end
      end
      Utils.runParallel(tasks)
    end

    if not ok then
      error(err, 0)
    end
  end

  Logger.printSuccess(
    string.format("Crafted '%s' x%d", recipeItem, recipeCount * batchSize)
  )
end

-- Entry point for multi-level crafting: builds a plan and executes it in order.
-- onStep(current, total): called after each individual craft run (per machine cycle or crafter batch).
-- onPlan(plan): called once after the plan is built, before execution starts.
-- onStepDone(): called after each full plan step completes.
function Crafting.craftItem(
  recipeName,
  count,
  onStep,
  onPlan,
  onStepDone,
  rootRecipe
)
  Logger.printInfo(string.format("Planning '%s' x%d..", recipeName, count))

  local totals, maxDmg = Stock.getDurabilityAwareTotals()
  local plan = Planner.buildCraftPlan(recipeName, count, totals, rootRecipe)

  if #plan == 0 then
    Logger.raiseError(string.format("No recipe found for '%s'", recipeName))
  end

  Planner.printPlan(plan)
  if onPlan then
    onPlan(plan)
  end

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
  -- Machine steps contribute craftsCount runs; crafter steps contribute
  -- ceil(craftsCount / maxBatch) chunks (one progress tick per chunk).
  local totalRuns = 0
  for _, step in ipairs(plan) do
    if (step.recipe.type or "crafter") == "machine" then
      totalRuns = totalRuns + step.craftsCount
    else
      local maxBatch = Stock.getMaxBatchForRecipe(step.recipe)
      totalRuns = totalRuns + math.ceil(step.craftsCount / maxBatch)
    end
  end

  local doneRuns = 0
  for _, step in ipairs(plan) do
    Logger.printInfo(
      string.format(
        "Crafting '%s' x%d craft(s) as one batch..",
        step.name,
        step.craftsCount
      )
    )
    Crafting.processCraft(step.recipe, step.craftsCount, function()
      doneRuns = doneRuns + 1
      if onStep then
        onStep(doneRuns, totalRuns)
      end
    end)
    if onStepDone then
      onStepDone()
    end
  end

  Logger.printSuccess(
    string.format("Done! Crafted '%s' x%d", recipeName, count)
  )
end

-- Builds and returns the craft plan without executing it (for UI preview).
function Crafting.buildPlan(recipeName, count, rootRecipe)
  local totals = Stock.getDurabilityAwareTotals()
  return Planner.buildCraftPlan(recipeName, count, totals, rootRecipe)
end

return Crafting

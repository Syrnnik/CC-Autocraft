local Config = require("lib.config")
local Fluids = require("lib.fluids")
local Labels = require("lib.labels")
local Logger = require("lib.logger")
local MultiInv = require("lib.multi_inv")
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
-- Stock In/Out may span several peripherals; both come back as one
-- (possibly virtual) inventory. Raises when the role is not configured.
local function stockInInv()
  local inv = MultiInv.forRole("stock_in")
  if not inv then
    Logger.raiseError("Role 'Stock In' is not configured")
  end
  return inv
end
local function stockOutInv()
  local inv = MultiInv.forRole("stock_out")
  if not inv then
    Logger.raiseError("Role 'Stock Out' is not configured")
  end
  return inv
end

local networkEvents = Config.NETWORK_EVENTS

local Crafting = {}

-- Stock totals with fluid pool levels merged in under prefixed names, the
-- shape the planner expects ("fluid:minecraft:lava" = mB).
local function mergedTotals()
  local totals, maxDmg = Stock.getDurabilityAwareTotals()
  for name, mb in pairs(Fluids.getTotals()) do
    totals[Fluids.PREFIX .. name] = mb
  end
  return totals, maxDmg
end

-- Human-readable name for a missing-ingredient report line.
local function missingLine(name, count)
  if Fluids.isFluidName(name) then
    local fluid = Fluids.stripPrefix(name)
    local display = fluid:match("^[^:]+:(.+)") or fluid
    return "- " .. display .. " x" .. count .. "mB"
  end
  local display = name:match("^[^:]+:(.+)") or name
  return "- " .. display .. " x" .. count
end

-- Pushes a machine recipe's fluids (scaled by batchSize) from the pool into
-- their processors. Raises a truthful error when the pool cannot cover the
-- request or a transfer under-delivers.
local function pushRecipeFluids(recipe, batchSize, resolvePort)
  for _, fluid in ipairs(recipe.fluids or {}) do
    if not fluid.processor then
      Logger.raiseError(
        string.format(
          "No machine assigned for fluid '%s' in recipe",
          fluid.name
        )
      )
    end
    local need = fluid.mb * batchSize
    local have = Fluids.count(fluid.name)
    if have < need then
      Logger.raiseError(
        string.format(
          "Not enough fluid '%s': need %dmB, have %dmB",
          fluid.name,
          need,
          have
        )
      )
    end
    local port = resolvePort(fluid.processor)
    Logger.printInfo(
      string.format("Pushing %dmB of '%s' to '%s'", need, fluid.name, port)
    )
    local moved = Fluids.extractTo(port, fluid.name, need)
    if moved < need then
      -- Return what did move so a failed step doesn't strand fluid in the
      -- machine, then report the real shortfall.
      Fluids.depositFrom(port, fluid.name, moved)
      Logger.raiseError(
        string.format(
          "Failed to move fluid '%s' to '%s': moved %d/%dmB"
            .. " (machine tank full or incompatible?)",
          fluid.name,
          port,
          moved,
          need
        )
      )
    end
  end
end

-- Returns leftover input fluids from every fluid processor back to the pool
-- (used after a cycle or a failed/timed-out craft).
local function reclaimRecipeFluids(recipe, resolvePort)
  local seen = {}
  for _, fluid in ipairs(recipe.fluids or {}) do
    if fluid.processor then
      local port = resolvePort(fluid.processor)
      local key = port .. "\0" .. fluid.name
      if not seen[key] then
        seen[key] = true
        pcall(Fluids.depositFrom, port, fluid.name)
      end
    end
  end
end

-- ── Cooperative locks for pipelined plan execution ──────────
-- Plan steps run as parallel coroutines (see craftItem). Multitasking in CC
-- is cooperative, so a check-and-set with no yield in between is atomic.

-- Serialises the stock claim+push phase: getItemsFor*Recipe lists stock
-- slots and claims counts from them, so two steps doing that concurrently
-- could claim the same items.
local stockBusy = false
local function lockStock()
  while stockBusy do
    os.sleep(0.05)
  end
  stockBusy = true
end
local function unlockStock()
  stockBusy = false
end

-- Per-machine exclusivity: two steps sharing a machine would mix their
-- inputs and confuse result polling. Keys are resolved port names, acquired
-- in sorted order so steps with overlapping machine sets can't deadlock.
local machineBusy = {}
local function lockMachines(ports)
  table.sort(ports)
  for _, port in ipairs(ports) do
    while machineBusy[port] do
      os.sleep(0.05)
    end
    machineBusy[port] = true
  end
end
local function unlockMachines(ports)
  for _, port in ipairs(ports) do
    machineBusy[port] = nil
  end
end

local function patternSlots()
  local slots = {}
  for row = 0, Config.PATTERN_SIZE - 1 do
    local rowStart = Config.PATTERN_START
      + Config.NEW_RECIPE_INTERFACE_ROW_SIZE * row
    for slot = rowStart, rowStart + Config.PATTERN_SIZE - 1 do
      table.insert(slots, slot)
    end
  end
  return slots
end

function Crafting.getSlotToPutItem()
  return math.ceil(Config.NEW_RECIPE_INTERFACE_ROW_SIZE / 2)
    + Config.NEW_RECIPE_INTERFACE_ROW_SIZE
      * math.floor(Config.PATTERN_SIZE / 2)
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
        Utils.portLabel(fromInterfaceName),
        failedItem.slot,
        getCrafter(),
        failedItem.crafterSlot
      )
    )
  end
end

function Crafting.returnRecipeItems(items, toInterfaceName)
  local toInterface = Utils.wrapPeripheral(toInterfaceName)

  Logger.printWarning(
    string.format("Returning items to '%s'", Utils.portLabel(toInterfaceName))
  )

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
        Utils.portLabel(toInterfaceName)
      )
    )
  end
end

-- skipSlots: optional set { [crafterSlot] = true } of slots to leave in the crafter.
function Crafting.getCraftedItem(toInterfaceName, isSpecificSlot, skipSlots)
  local toInterface = Utils.wrapPeripheral(toInterfaceName)

  Logger.printInfo(
    string.format(
      "Getting crafted item from '%s'",
      Utils.portLabel(toInterfaceName)
    )
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
        Utils.portLabel(toInterfaceName)
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
  if Config.CLEAR_CRAFTER_BEFORE_CRAFT then
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

  Network.sendEvent(Config.CRAFTER_NETWORK_ID, networkEvents.CRAFT)

  Logger.printDebug("Waiting for crafter..")
  local senderID, msg = Network.receiveEvent(Config.CRAFT_TIMEOUT)

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

-- Push machineItems from the recipe interface (and machineFluids from the
-- fluid pool) to their processors, wait for a result to appear in
-- resultProcessor, pull it back, then clear all machines.
--
-- machineFluids: optional list of { name, mb, processor(port) }.
-- The result may be an item (returned as getItemDetail table, as before) or
-- a fluid: when no item appears but the amount of some fluid in the result
-- machine grows, the craft result is that growth, returned as
-- { isFluid = true, name = <fluid id>, count = <mB produced> }.
function Crafting.craftNewMachineRecipe(
  machineItems,
  resultProcessor,
  machineFluids
)
  local interface = Utils.wrapPeripheral(interfaceName())
  machineFluids = machineFluids or {}

  -- Items placed directly into the result machine (ignored during polling
  -- until they are transformed into the actual result).
  local inputsToResult = {}
  for _, item in pairs(machineItems) do
    if item.processor == resultProcessor then
      inputsToResult[item.name] = true
    end
  end
  -- Same for fluids routed into the result machine.
  local fluidsToResult = {}
  for _, fluid in ipairs(machineFluids) do
    if fluid.processor == resultProcessor then
      fluidsToResult[fluid.name] = true
    end
  end

  -- Snapshot of the result machine's tanks BEFORE any push: fluid output is
  -- measured as growth above this baseline.
  local fluidBaseline = Fluids.tankLevels(resultProcessor)

  -- Check fluid availability up front so nothing moves on a shortage.
  for _, fluid in ipairs(machineFluids) do
    local have = Fluids.count(fluid.name)
    if have < fluid.mb then
      Logger.raiseError(
        string.format(
          "Not enough fluid '%s': need %dmB, have %dmB",
          fluid.name,
          fluid.mb,
          have
        )
      )
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

  local failedFluid = nil
  if not failedItem then
    for _, fluid in ipairs(machineFluids) do
      Logger.printInfo(
        string.format(
          "Pushing %dmB of '%s' to '%s'",
          fluid.mb,
          fluid.name,
          fluid.processor
        )
      )
      local moved = Fluids.extractTo(fluid.processor, fluid.name, fluid.mb)
      if moved < fluid.mb then
        failedFluid = { fluid = fluid, moved = moved }
        break
      end
    end
  end

  -- Poll: wait until a non-input item appears in resultProcessor, or some
  -- fluid in it grows above the baseline. A growing fluid is sampled until
  -- it stops changing (two stable polls) so slow machines report the full
  -- per-craft amount, not a snapshot mid-fill.
  local crafted = nil
  if not failedItem and not failedFluid then
    local steps = math.ceil(Config.MACHINE_CRAFT_TIMEOUT / 0.5)
    local destSlot = Crafting.getSlotToPutItem()

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

      local grownFluid, grownBy = nil, 0
      for name, level in pairs(Fluids.tankLevels(resultProcessor)) do
        local delta = level - (fluidBaseline[name] or 0)
        if delta > 0 and not fluidsToResult[name] then
          grownFluid, grownBy = name, delta
          break
        end
      end
      if grownFluid then
        local stable = 0
        while stable < 2 do
          os.sleep(0.5)
          local level = Fluids.tankLevels(resultProcessor)[grownFluid] or 0
          local delta = level - (fluidBaseline[grownFluid] or 0)
          if delta > grownBy then
            grownBy = delta
            stable = 0
          else
            stable = stable + 1
          end
        end
        crafted = { isFluid = true, name = grownFluid, count = grownBy }
        -- Bank the produced fluid into the pool (baseline stays untouched).
        Fluids.depositFrom(resultProcessor, grownFluid, grownBy)
        break
      end

      os.sleep(0.5)
    end
  end

  -- Always clear all machines (whether success or timeout); one concurrent
  -- task per machine. Leftover input fluids go back to the pool too.
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
  local seenFluid = {}
  for _, fluid in ipairs(machineFluids) do
    local key = fluid.processor .. "\0" .. fluid.name
    if not seenFluid[key] then
      seenFluid[key] = true
      pcall(Fluids.depositFrom, fluid.processor, fluid.name)
    end
  end

  if failedItem then
    Logger.raiseError(
      string.format(
        "Failed to push '%s' to '%s'",
        failedItem.name,
        failedItem.processor
      )
    )
  end
  if failedFluid then
    Logger.raiseError(
      string.format(
        "Failed to move fluid '%s' to '%s': moved %d/%dmB",
        failedFluid.fluid.name,
        failedFluid.fluid.processor,
        failedFluid.moved,
        failedFluid.fluid.mb
      )
    )
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
-- batchSize: how many recipe cycles to run in one call.
--   Items are pushed to processors all at once; results are pulled one by one.
-- onEach(craftsDone): called after each individual result is collected (for
--   progress tracking); craftsDone is the number of recipe cycles completed.
function Crafting.craftMachine(recipe, batchSize, onEach)
  batchSize = batchSize or 1
  local stockIn = stockInInv()
  local stockOut = stockOutInv()

  -- Resolve labels → port names once (Utils.wrapPeripheral will error if not found)
  local resultPort = Labels.resolvePort(recipe.resultProcessor)
  local portCache = {}
  local function resolveItemPort(proc)
    if not portCache[proc] then
      portCache[proc] = Labels.resolvePort(proc)
    end
    return portCache[proc]
  end

  -- Hold every machine involved for the whole cycle (push → poll → clear):
  -- a concurrent step pushing into the same machine would mix inputs.
  local lockPorts = { resultPort }
  do
    local seenPort = { [resultPort] = true }
    for _, item in pairs(recipe.items) do
      if item.processor then
        local port = resolveItemPort(item.processor)
        if not seenPort[port] then
          seenPort[port] = true
          lockPorts[#lockPorts + 1] = port
        end
      end
    end
    for _, fluid in ipairs(recipe.fluids or {}) do
      if fluid.processor then
        local port = resolveItemPort(fluid.processor)
        if not seenPort[port] then
          seenPort[port] = true
          lockPorts[#lockPorts + 1] = port
        end
      end
    end
  end
  lockMachines(lockPorts)

  local okBody, errBody = pcall(function()
    Crafting.runMachineCycle(
      recipe,
      batchSize,
      onEach,
      stockIn,
      stockOut,
      resultPort,
      resolveItemPort
    )
  end)

  unlockMachines(lockPorts)
  if not okBody then
    error(errBody, 0)
  end
end

-- Waits for a fluid-result machine recipe to produce its fluid, draining the
-- result machine's tank into the pool as the fluid appears (so a small
-- machine tank never stalls a big batch). `baseline` is the amount of the
-- result fluid already in the machine before inputs were pushed: it stays
-- untouched, only growth above it counts as output.
local function collectFluidResult(
  recipe,
  batchSize,
  onEach,
  resultPort,
  baseline
)
  local fluidName = recipe.name
  local perCraft = recipe.count or 1
  local totalNeeded = batchSize * perCraft
  local steps = math.ceil(Config.MACHINE_CRAFT_TIMEOUT / 0.5)
  local produced = 0 -- mB banked into the pool so far
  local cyclesDone = 0

  while produced < totalNeeded do
    local moved = 0
    for _ = 1, steps do
      local level = Fluids.tankLevels(resultPort)[fluidName] or 0
      local drainable = level - baseline
      if drainable > 0 then
        moved = Fluids.depositFrom(resultPort, fluidName, drainable)
        if moved > 0 then
          break
        end
        -- The fluid is sitting in the machine but no pool tank accepts it.
        Logger.raiseError(
          string.format(
            "Fluid storage full: could not deposit %dmB of '%s' (got %d/%dmB)",
            drainable,
            fluidName,
            produced,
            totalNeeded
          )
        )
      end
      os.sleep(0.5)
    end
    if moved == 0 then
      Logger.raiseError(
        string.format(
          "Machine craft timed out: got %d/%dmB of '%s' from %s",
          produced,
          totalNeeded,
          fluidName,
          resultPort
        )
      )
    end
    produced = produced + moved
    local newCycles = math.min(
      batchSize - cyclesDone,
      math.floor(produced / perCraft) - cyclesDone
    )
    cyclesDone = cyclesDone + newCycles
    for _ = 1, newCycles do
      if onEach then
        onEach(1)
      end
    end
  end
end

-- Body of one machine craft cycle; assumes the involved machines are already
-- locked by craftMachine.
function Crafting.runMachineCycle(
  recipe,
  batchSize,
  onEach,
  stockIn,
  stockOut,
  resultPort,
  resolveItemPort
)
  -- Items placed directly into the result machine (ignored during polling)
  local inputsToResult = {}
  for _, item in pairs(recipe.items) do
    if item.processor == recipe.resultProcessor then
      inputsToResult[item.name] = true
    end
  end

  local isFluidResult = recipe.resultType == "fluid"
  -- Snapshot BEFORE any push: an input fluid routed into the result machine
  -- must not be mistaken for output.
  local fluidBaseline = 0
  if isFluidResult then
    fluidBaseline = Fluids.tankLevels(resultPort)[recipe.name] or 0
  end

  -- Claim stock slots (and pool fluids) and push the full batch under the
  -- stock lock so a concurrent step can't claim the same resources.
  lockStock()
  local okPush, errPush = pcall(function()
    -- Claim items first: getItemsForMachineRecipe raises on shortage before
    -- anything moves, so a missing item can't strand fluid in a machine.
    local pushList = Stock.getItemsForMachineRecipe(recipe, batchSize)
    for _, item in pairs(pushList) do
      if not item.processor then
        Logger.raiseError(
          string.format("No processor assigned for '%s' in recipe", item.name)
        )
      end
    end
    pushRecipeFluids(recipe, batchSize, resolveItemPort)
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
        string.format(
          "Failed to push '%s' to '%s'",
          failedItem.name,
          failedPort
        )
      )
    end
  end)
  unlockStock()
  if not okPush then
    -- A partial push may have left fluid in the machines; return it.
    reclaimRecipeFluids(recipe, resolveItemPort)
    error(errPush, 0)
  end

  local okCollect, errCollect = pcall(function()
    if isFluidResult then
      collectFluidResult(recipe, batchSize, onEach, resultPort, fluidBaseline)
      return
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
              onEach(1)
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
  end)

  -- Always clear all machines (success or timeout); one concurrent task per
  -- machine. Leftover input fluids go back to the pool the same way.
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
  reclaimRecipeFluids(recipe, resolveItemPort)

  if not okCollect then
    error(errCollect, 0)
  end
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
  local stock = stockOutInv()
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
-- onEach(craftsDone): called after each individual machine cycle (craftsDone=1),
--   or once after each crafter chunk (craftsDone=chunk size).
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
    -- The crafter and the stock claim+push cycle stay exclusive for the
    -- whole batch: catalysts sit in the crafter between chunks and every
    -- chunk lists stock and claims slots from it.
    lockStock()
    local okBatch, errBatch = pcall(function()
      local stockIn = stockInInv()
      local stockOut = stockOutInv()

      local catalysts = Stock.getCatalystItemsForRecipe(recipe)
      local catalystSlots = {}
      for _, cat in ipairs(catalysts) do
        catalystSlots[cat.crafterSlot] = true
      end

      if #catalysts > 0 then
        Crafting.pushItemsToCrafter(catalysts, stockIn)
      end

      local maxBatch = Stock.getMaxBatchForRecipe(recipe)
      local done = 0
      local ok, err = pcall(function()
        while done < batchSize do
          local chunk = math.min(maxBatch, batchSize - done)
          local stockItems = Stock.getItemsForRecipe(recipe, chunk)
          Crafting.craft(stockItems, stockIn)
          Crafting.getCraftedItem(stockOut, false, catalystSlots)
          done = done + chunk
          if onEach then
            onEach(chunk)
          end
        end
      end)

      -- Always return catalysts to stock after the batch (or on error)
      if #catalysts > 0 then
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
    end)
    unlockStock()
    if not okBatch then
      error(errBatch, 0)
    end
  end

  Logger.printSuccess(
    string.format("Crafted '%s' x%d", recipeItem, recipeCount * batchSize)
  )
end

-- Entry point for multi-level crafting: builds a plan and executes it.
-- Execution is pipelined: independent steps run concurrently (the crafter
-- keeps working while a machine smelts); a step waits only for the earlier
-- steps that produce its ingredients.
-- onStep(current, total, stepName, craftsDone): called after each individual
--   craft run (per machine cycle or crafter chunk). stepName is the plan step
--   that progressed; craftsDone is how many recipe cycles it just completed.
-- onPlan(plan): called once after the plan is built, before execution starts.
-- onStepDone(stepName): called after each full plan step completes. Steps can
--   finish out of plan order.
function Crafting.craftItem(
  recipeName,
  count,
  onStep,
  onPlan,
  onStepDone,
  rootRecipe
)
  Logger.printInfo(string.format("Planning '%s' x%d..", recipeName, count))

  local totals, maxDmg = mergedTotals()
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
      table.insert(lines, missingLine(item.name, item.count))
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

  -- ── Pipelined execution ─────────────────────────────────────
  -- Every plan step runs as a coroutine and starts once all earlier steps
  -- that produce one of its ingredients have finished. Peripheral safety
  -- comes from the stock/machine locks above. UI callbacks may draw on a
  -- monitor (peripheral calls yield), so they are serialised to keep two
  -- steps from interleaving a redraw.
  local doneRuns = 0
  local doneSteps = {}
  local failed = nil

  local uiBusy = false
  local function notify(fn, ...)
    if not fn then
      return
    end
    while uiBusy do
      os.sleep(0.05)
    end
    uiBusy = true
    local ok, err = pcall(fn, ...)
    uiBusy = false
    if not ok then
      error(err, 0)
    end
  end

  local runners = {}
  for i, step in ipairs(plan) do
    -- Earlier plan steps that produce one of this step's ingredients
    -- (fluids included: their plan-space names line up via the prefix).
    local deps = {}
    for _, ingredient in ipairs(Planner.getAllIngredients(step.recipe)) do
      for j = 1, i - 1 do
        if plan[j].name == ingredient.name then
          deps[#deps + 1] = ingredient.name
          break
        end
      end
    end

    runners[i] = function()
      -- Wait for producers; bail out early if another step failed.
      while true do
        if failed then
          return
        end
        local ready = true
        for _, dep in ipairs(deps) do
          if not doneSteps[dep] then
            ready = false
            break
          end
        end
        if ready then
          break
        end
        os.sleep(0.1)
      end

      Logger.printInfo(
        string.format(
          "Crafting '%s' x%d craft(s) as one batch..",
          step.name,
          step.craftsCount
        )
      )
      local ok, err = pcall(
        Crafting.processCraft,
        step.recipe,
        step.craftsCount,
        function(craftsDone)
          notify(function()
            doneRuns = doneRuns + 1
            if onStep then
              onStep(doneRuns, totalRuns, step.name, craftsDone or 1)
            end
          end)
        end
      )
      if not ok then
        failed = failed or err
        return
      end
      doneSteps[step.name] = true
      notify(onStepDone, step.name)
    end
  end

  parallel.waitForAll(table.unpack(runners))
  if failed then
    error(failed, 0)
  end

  Logger.printSuccess(
    string.format("Done! Crafted '%s' x%d", recipeName, count)
  )
end

-- Builds and returns the craft plan without executing it (for UI preview).
function Crafting.buildPlan(recipeName, count, rootRecipe)
  local totals = mergedTotals()
  return Planner.buildCraftPlan(recipeName, count, totals, rootRecipe)
end

return Crafting

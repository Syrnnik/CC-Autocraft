local Labels  = require("lib.labels")
local Logger  = require("lib.logger")
local Recipes = require("lib.recipes")
local Roles   = require("lib.roles")

local Stock = {}

-- Returns slot-indexed item listing from a peripheral.
-- Prefers stock() over list() when available.
local function listItems(p)
  if p.stock then return p.stock() end
  return p.list()
end

local function getStockView()
  local name = Roles.getPort("stock_view")
  return name and peripheral.wrap(name) or nil
end

-- Returns item detail from a peripheral, preferring getStockItemDetail (ME/custom
-- storage systems) over the standard getItemDetail.
local function getItemDetail(p, slot)
  if p.getStockItemDetail then return p.getStockItemDetail(slot) end
  return p.getItemDetail(slot)
end

local function getStockIn()
  local name = Roles.getPort("stock_in")
  return name and peripheral.wrap(name) or nil
end

function Stock.getMissingItems(items)
  local view = getStockView()
  if not view then
    local missing = {}
    for _, item in pairs(items) do
      table.insert(missing, { name = item.name, count = item.count })
    end
    return {}, missing
  end
  -- Sum totals across all stock slots (handles split stacks)
  local stockTotals = {}
  local stockFirstSlot = {}
  for slot, stockItem in pairs(listItems(view)) do
    local name = stockItem.name
    stockTotals[name] = (stockTotals[name] or 0) + stockItem.count
    if not stockFirstSlot[name] then
      stockFirstSlot[name] = slot
    end
  end

  local stockItems = {}
  local missingItems = {}

  for _, item in pairs(items) do
    local name = item.name
    local needed = item.count
    local available = stockTotals[name] or 0

    if available >= needed then
      Logger.printDebug(
        string.format(
          "Stock has '%s' x%d (x%d required)",
          name,
          available,
          needed
        )
      )
      table.insert(stockItems, {
        name = name,
        count = needed,
        slot = stockFirstSlot[name],
      })
    else
      if available == 0 then
        Logger.printError(string.format("Stock has no '%s'", name))
      else
        Logger.printError(
          string.format(
            "Stock has not enough '%s' (x%d, required x%d)",
            name,
            available,
            needed
          )
        )
      end
      table.insert(missingItems, { name = name, count = needed })
    end
  end

  return stockItems, missingItems
end

-- batchSize: how many times to replicate the recipe in one craft call.
-- Multiplies each slot's item count so the turtle crafts batchSize results at once.
function Stock.getItemsForRecipe(recipe, batchSize)
  batchSize = batchSize or 1
  local requiredItems = Recipes.getRequiredItemsPlainList(recipe)
  -- Scale totals check to full batch amount
  local scaledItems = {}
  for _, item in pairs(requiredItems) do
    table.insert(scaledItems, { name = item.name, count = item.count * batchSize })
  end
  local _, missingItems = Stock.getMissingItems(scaledItems)
  if #missingItems > 0 then
    Logger.raiseError("Not enough items for craft")
  end

  -- Index all stock slots by item name, tracking remaining count per slot.
  -- This allows recipe positions to be spread across multiple source slots
  -- when the total needed exceeds what any single slot holds.
  local slotsByName = {}
  local stockIn = getStockIn()
  for slot, item in pairs(listItems(stockIn)) do
    local name = item.name
    if not slotsByName[name] then
      slotsByName[name] = {}
    end
    table.insert(slotsByName[name], { slot = slot, remaining = item.count })
  end

  -- Assign a stock slot to each recipe grid position individually.
  local pushList = {}
  for _, recipeItem in pairs(recipe.items) do
    local name = recipeItem.name
    local needed = recipeItem.count * batchSize
    local slots = slotsByName[name] or {}

    local crafterSlot = Recipes.countCrafterSlot(recipeItem.slot)
    local remaining = needed
    for _, entry in ipairs(slots) do
      if remaining <= 0 then break end
      local take = math.min(entry.remaining, remaining)
      if take > 0 then
        entry.remaining = entry.remaining - take
        remaining = remaining - take
        table.insert(pushList, {
          name = name,
          count = take,
          slot = entry.slot,
          crafterSlot = crafterSlot,
        })
      end
    end

    if remaining > 0 then
      Logger.raiseError(
        string.format("Not enough '%s' in stock for batch", name)
      )
    end
  end

  return pushList
end

-- Returns push list for machine recipes scaled by batchSize,
-- spreading items across multiple stock slots when needed.
function Stock.getItemsForMachineRecipe(recipe, batchSize)
  batchSize = batchSize or 1
  local slotsByName = {}
  local stockIn2 = getStockIn()
  for slot, item in pairs(listItems(stockIn2)) do
    local name = item.name
    if not slotsByName[name] then
      slotsByName[name] = {}
    end
    table.insert(slotsByName[name], { slot = slot, remaining = item.count })
  end

  local pushList = {}
  for _, recipeItem in pairs(recipe.items) do
    local name     = recipeItem.name
    local needed   = recipeItem.count * batchSize
    local slots    = slotsByName[name] or {}
    local remaining = needed

    for _, entry in ipairs(slots) do
      if remaining <= 0 then break end
      local take = math.min(entry.remaining, remaining)
      if take > 0 then
        entry.remaining = entry.remaining - take
        remaining       = remaining - take
        table.insert(pushList, {
          name      = name,
          count     = take,
          slot      = entry.slot,
          processor = recipeItem.processor,
        })
      end
    end

    if remaining > 0 then
      Logger.raiseError(string.format("Not enough '%s' in stock for machine batch", name))
    end
  end

  return pushList
end

-- Returns the maximum safe batchSize for a crafter recipe based on item stack sizes.
-- Each recipe slot maps to one crafter slot, so count*batch must not exceed maxCount.
function Stock.getMaxBatchForRecipe(recipe)
  local stockIn = getStockIn()
  if not stockIn then return 1 end
  local slotForName = {}
  for slot, item in pairs(listItems(stockIn)) do
    if not slotForName[item.name] then
      slotForName[item.name] = slot
    end
  end
  local maxBatch = math.huge
  for _, item in pairs(recipe.items) do
    local slot = slotForName[item.name]
    if slot and item.count > 0 then
      local detail = stockIn.getItemDetail(slot)
      if detail and detail.maxCount then
        local limit = math.floor(detail.maxCount / item.count)
        if limit < maxBatch then maxBatch = limit end
      end
    end
  end
  return math.max(1, maxBatch == math.huge and 1 or maxBatch)
end

-- Returns the maximum batch size for a machine recipe based on how many
-- items each processor can hold (empty slots × stack size per item).
function Stock.getMaxBatchForMachineRecipe(recipe)
  local portCache = {}
  local function getPeripheral(processor)
    local port = Labels.resolvePort(processor)
    if not portCache[port] then
      local p = peripheral.wrap(port)
      if not p then
        Logger.raiseError(
          string.format("Processor '%s' not found (port: %s)", processor, tostring(port))
        )
      end
      portCache[port] = p
    end
    return portCache[port]
  end

  local maxBatch = math.huge
  for _, item in ipairs(recipe.items) do
    if item.count > 0 then
      local p = getPeripheral(item.processor)
      if p then
        local list  = p.list()
        local size  = p.size and p.size() or 9
        local capacity = 0
        for slot = 1, size do
          local slotItem = list[slot]
          if not slotItem then
            -- Empty slot: assume default stack size of 64
            capacity = capacity + 64
          elseif slotItem.name == item.name then
            -- Same item: remaining stack space
            local maxCount = 64
            if p.getItemDetail then
              local detail = p.getItemDetail(slot)
              if detail and detail.maxCount then maxCount = detail.maxCount end
            end
            capacity = capacity + (maxCount - slotItem.count)
          end
          -- Slot occupied by a different item: no space for our item
        end
        local limit = math.floor(capacity / item.count)
        if limit < maxBatch then maxBatch = limit end
      end
    end
  end

  return math.max(1, maxBatch == math.huge and 1 or maxBatch)
end

function Stock.getTotals()
  local stock = getStockView()
  if not stock then return {} end
  local totals = {}
  for _, item in pairs(listItems(stock)) do
    local name = item.name
    totals[name] = (totals[name] or 0) + item.count
  end
  return totals
end

-- Like getTotals(), but damageable items are counted by remaining uses
-- (maxDamage - damage) instead of item count.
-- Also returns maxDmg map { [name] = maxDamage } for damageable items,
-- used to convert a use-shortage back to an item count.
function Stock.getDurabilityAwareTotals()
  local stock = getStockView()
  if not stock then return {}, {} end
  local totals = {}
  local maxDmg = {}

  for slot, item in pairs(listItems(stock)) do
    -- Damageable items cannot stack, so skip getItemDetail for count > 1.
    if item.count > 1 then
      totals[item.name] = (totals[item.name] or 0) + item.count
    else
      local detail = getItemDetail(stock, slot)
      if detail then
        local md = detail.maxDamage or 0
        if maxDmg[detail.name] == nil then
          maxDmg[detail.name] = md
        end
        if md > 0 then
          totals[detail.name] = (totals[detail.name] or 0)
            + (md - (detail.damage or 0))
        else
          totals[detail.name] = (totals[detail.name] or 0) + 1
        end
      end
    end
  end

  return totals, maxDmg
end

-- Returns all checklist items with their status relative to current stock and recipes.
-- Each entry: { name, needed, status }
-- status: "done" | "in_stock" | "to_craft" | "missing"
-- Returns nil if no clipboard found.
function Stock.getChecklistStatus()
  local clipboard = peripheral.find("create:clipboard")
  if not clipboard then return nil end

  local rawItems = clipboard.getItemEntries()
  if not rawItems then return {} end

  local totals     = Stock.getTotals()
  local allRecipes = Recipes.getAllRecipes()

  local result = {}
  for _, entry in ipairs(rawItems) do
    local name   = entry.item.name
    local needed = entry.itemAmount or 0
    local status
    if entry.checked then
      status = "done"
    elseif (totals[name] or 0) >= needed then
      status = "in_stock"
    elseif allRecipes[name] then
      status = "to_craft"
    else
      status = "missing"
    end
    table.insert(result, { name = name, needed = needed, status = status })
  end

  return result
end

-- Pulls "in_stock" checklist items from stock_in and pushes them to materials_out.
-- Transfers as much as available; partial transfers are silently accepted.
-- Returns transferred ({ name, count }) and notFound ({ name, count }) lists.
function Stock.transferChecklistItems()
  local items = Stock.getChecklistStatus()
  if items == nil then
    Logger.raiseError("No clipboard found (create:clipboard)")
  end

  local stockIn = getStockIn()
  if not stockIn then Logger.raiseError("No stock_in configured") end

  local outName = Roles.getPort("materials_out")
  if not outName then Logger.raiseError("No materials_out configured") end

  local slotsByName = {}
  for slot, item in pairs(listItems(stockIn)) do
    local name = item.name
    if not slotsByName[name] then slotsByName[name] = {} end
    table.insert(slotsByName[name], { slot = slot, remaining = item.count })
  end

  local transferred = {}
  local notFound = {}

  for _, item in ipairs(items) do
    if item.status == "in_stock" then
      local name = item.name
      local needed = item.needed
      local slots = slotsByName[name] or {}
      local remaining = needed

      for _, entry in ipairs(slots) do
        if remaining <= 0 then break end
        local take = math.min(entry.remaining, remaining)
        if take > 0 then
          local moved = stockIn.pushItems(outName, entry.slot, take)
          entry.remaining = entry.remaining - moved
          remaining = remaining - moved
        end
      end

      local moved = needed - remaining
      if moved > 0 then table.insert(transferred, { name = name, count = moved }) end
      if remaining > 0 then table.insert(notFound, { name = name, count = remaining }) end
    end
  end

  return transferred, notFound
end

return Stock

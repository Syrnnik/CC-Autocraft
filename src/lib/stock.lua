local Config = require("lib.config")
local Logger = require("lib.logger")
local Recipes = require("lib.recipes")

local stockName = Config.STOCK_NAME

local Stock = {}

local function getStock()
  return peripheral.wrap(stockName)
end

function Stock.getMissingItems(items)
  -- Sum totals across all stock slots (handles split stacks)
  local stockTotals = {}
  local stockFirstSlot = {}
  for slot, stockItem in pairs(getStock().list()) do
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
  for slot, item in pairs(getStock().list()) do
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

    local assigned = false
    for _, entry in ipairs(slots) do
      if entry.remaining >= needed then
        entry.remaining = entry.remaining - needed
        table.insert(pushList, {
          name = name,
          count = needed,
          slot = entry.slot,
          crafterSlot = Recipes.countCrafterSlot(recipeItem.slot),
        })
        assigned = true
        break
      end
    end

    if not assigned then
      Logger.raiseError(
        string.format("Not enough '%s' in a single stock slot for batch", name)
      )
    end
  end

  return pushList
end

-- Returns push list for machine recipes: one slot per recipe item,
-- routed to the item's assigned processor.
function Stock.getItemsForMachineRecipe(recipe)
  local slotsByName = {}
  for slot, item in pairs(getStock().list()) do
    local name = item.name
    if not slotsByName[name] then
      slotsByName[name] = {}
    end
    table.insert(slotsByName[name], { slot = slot, remaining = item.count })
  end

  local pushList = {}
  for _, recipeItem in pairs(recipe.items) do
    local name = recipeItem.name
    local slots = slotsByName[name] or {}

    local assigned = false
    for _, entry in ipairs(slots) do
      if entry.remaining >= 1 then
        entry.remaining = entry.remaining - 1
        table.insert(pushList, {
          name = name,
          count = 1,
          slot = entry.slot,
          processor = recipeItem.processor,
        })
        assigned = true
        break
      end
    end

    if not assigned then
      Logger.raiseError(string.format("Stock has no '%s'", name))
    end
  end

  return pushList
end

function Stock.getTotals()
  local totals = {}
  for _, item in pairs(getStock().list()) do
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
  local stock = getStock()
  local totals = {}
  local maxDmg = {}

  for slot, item in pairs(stock.list()) do
    -- Damageable items cannot stack, so skip getItemDetail for count > 1.
    if item.count > 1 then
      totals[item.name] = (totals[item.name] or 0) + item.count
    else
      local detail = stock.getItemDetail(slot)
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

return Stock

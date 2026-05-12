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

function Stock.getItemsForRecipe(recipe)
  local requiredItems = Recipes.getRequiredItemsPlainList(recipe)
  local _, missingItems = Stock.getMissingItems(requiredItems)
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
    local needed = recipeItem.count
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
        string.format("Not enough '%s' in a single stock slot", name)
      )
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

return Stock

local DisplayNames = require("lib.display_names")
local Logger = require("lib.logger")
local MultiInv = require("lib.multi_inv")
local Recipes = require("lib.recipes")
local Roles = require("lib.roles")
local Utils = require("lib.utils")

local Stock = {}

-- Returns slot-indexed item listing from a peripheral.
-- Prefers stock() over list() when available.
local function listItems(p)
  if p.stock then
    return p.stock()
  end
  return p.list()
end

local function getStockView()
  -- pcall keeps the old graceful behavior: an unset role or a disconnected
  -- port yields nil (empty stock) instead of an error.
  local ok, inv = pcall(MultiInv.forRole, "stock_view")
  if not ok then
    return nil
  end
  return inv
end

-- Returns item detail from a peripheral, preferring getStockItemDetail (ME/custom
-- storage systems) over the standard getItemDetail.
local function getItemDetail(p, slot)
  if p.getStockItemDetail then
    return p.getStockItemDetail(slot)
  end
  return p.getItemDetail(slot)
end

local function getStockIn()
  return (MultiInv.forRole("stock_in"))
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
    if not item.catalyst then
      table.insert(
        scaledItems,
        { name = item.name, count = item.count * batchSize }
      )
    end
  end
  local _, missingItems = Stock.getMissingItems(scaledItems)
  if #missingItems > 0 then
    Logger.raiseError("Not enough items for craft")
  end

  -- Index all stock slots by item name, tracking remaining count per slot.
  -- This allows recipe positions to be spread across multiple source slots
  -- when the total needed exceeds what any single slot holds.
  local stockIn = getStockIn()
  if not stockIn then
    Logger.raiseError("Role 'Stock In' is not configured")
  end

  local slotsByName = {}
  for slot, item in pairs(listItems(stockIn)) do
    local name = item.name
    if not slotsByName[name] then
      slotsByName[name] = {}
    end
    table.insert(slotsByName[name], { slot = slot, remaining = item.count })
  end

  -- Assign a stock slot to each recipe grid position individually.
  -- Catalyst items are pushed separately (once per batch) and skipped here.
  local pushList = {}
  for _, recipeItem in pairs(recipe.items) do
    if recipeItem.catalyst then
      goto continue
    end
    local name = recipeItem.name
    local needed = recipeItem.count * batchSize
    local slots = slotsByName[name] or {}

    local crafterSlot = Recipes.countCrafterSlot(recipeItem.slot)
    local remaining = needed
    for _, entry in ipairs(slots) do
      if remaining <= 0 then
        break
      end
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
    ::continue::
  end

  return pushList
end

-- Returns push list for catalyst items only (count=1 each, from stock_in).
-- Catalysts are pushed to the crafter once per batch and returned afterwards.
function Stock.getCatalystItemsForRecipe(recipe)
  local stockIn = getStockIn()
  if not stockIn then
    Logger.raiseError("Role 'Stock In' is not configured")
  end

  local slotsByName = {}
  for slot, item in pairs(listItems(stockIn)) do
    if not slotsByName[item.name] then
      slotsByName[item.name] = slot
    end
  end

  local pushList = {}
  for _, recipeItem in ipairs(recipe.items) do
    if recipeItem.catalyst then
      local name = recipeItem.name
      local crafterSlot = Recipes.countCrafterSlot(recipeItem.slot)
      local stockSlot = slotsByName[name]
      if not stockSlot then
        Logger.raiseError(
          string.format("Catalyst '%s' not found in stock", name)
        )
      end
      table.insert(pushList, {
        name = name,
        count = 1,
        slot = stockSlot,
        crafterSlot = crafterSlot,
      })
    end
  end
  return pushList
end

-- Returns push list for machine recipes scaled by batchSize,
-- spreading items across multiple stock slots when needed.
function Stock.getItemsForMachineRecipe(recipe, batchSize)
  batchSize = batchSize or 1
  local stockIn2 = getStockIn()
  if not stockIn2 then
    Logger.raiseError("Role 'Stock In' is not configured")
  end

  local slotsByName = {}
  for slot, item in pairs(listItems(stockIn2)) do
    local name = item.name
    if not slotsByName[name] then
      slotsByName[name] = {}
    end
    table.insert(slotsByName[name], { slot = slot, remaining = item.count })
  end

  local pushList = {}
  for _, recipeItem in pairs(recipe.items) do
    local name = recipeItem.name
    local needed = recipeItem.count * batchSize
    local slots = slotsByName[name] or {}
    local remaining = needed

    for _, entry in ipairs(slots) do
      if remaining <= 0 then
        break
      end
      local take = math.min(entry.remaining, remaining)
      if take > 0 then
        entry.remaining = entry.remaining - take
        remaining = remaining - take
        table.insert(pushList, {
          name = name,
          count = take,
          slot = entry.slot,
          processor = recipeItem.processor,
        })
      end
    end

    if remaining > 0 then
      Logger.raiseError(
        string.format("Not enough '%s' in stock for machine batch", name)
      )
    end
  end

  return pushList
end

-- Returns the maximum safe batchSize for a crafter recipe based on item stack sizes.
-- Each recipe slot maps to one crafter slot, so count*batch must not exceed maxCount.
-- The output item's maxCount is also checked: results accumulate in one crafter slot
-- and will overflow (dropping to the world) if batch*recipe.count exceeds it.
function Stock.getMaxBatchForRecipe(recipe)
  local stockIn = getStockIn()
  if not stockIn then
    return 1
  end
  local slotForName = {}
  for slot, item in pairs(listItems(stockIn)) do
    if not slotForName[item.name] then
      slotForName[item.name] = slot
    end
  end
  local maxBatch = math.huge
  for _, item in pairs(recipe.items) do
    if item.catalyst then
      goto continue
    end
    local slot = slotForName[item.name]
    if slot and item.count > 0 then
      local detail = stockIn.getItemDetail(slot)
      if detail and detail.maxCount then
        local limit = math.floor(detail.maxCount / item.count)
        if limit < maxBatch then
          maxBatch = limit
        end
      end
    end
    ::continue::
  end

  -- Limit by output item's max stack size (results must fit in one crafter output slot).
  local outputCount = recipe.count or 1
  if outputCount > 0 then
    local outMaxCount = recipe.maxCount -- saved at recipe creation time (most reliable)
    if not outMaxCount then
      local view = getStockView() -- full storage view has the broadest coverage
      if view then
        for slot, item in pairs(listItems(view)) do
          if item.name == recipe.name then
            local detail = getItemDetail(view, slot)
            if detail and detail.maxCount then
              outMaxCount = detail.maxCount
            end
            break
          end
        end
      end
    end
    if not outMaxCount then -- fallback: check stock_in
      local inSlot = slotForName[recipe.name]
      if inSlot then
        local detail = stockIn.getItemDetail(inSlot)
        if detail and detail.maxCount then
          outMaxCount = detail.maxCount
        end
      end
    end
    if outMaxCount then
      local limit = math.floor(outMaxCount / outputCount)
      if limit < maxBatch then
        maxBatch = limit
      end
    end
  end

  return math.max(1, maxBatch == math.huge and 1 or maxBatch)
end

-- Returns the maximum batch size for a machine recipe.
-- Each ingredient occupies exactly one slot in the machine, so the limit
-- is floor(maxStackSize / count_per_cycle) — the number of recipe cycles
-- whose items still fit in a single stack.
function Stock.getMaxBatchForMachineRecipe(recipe)
  local stockIn = getStockIn()

  -- Build a map of item name → count_per_cycle for recipe items only.
  local needed = {}
  for _, item in ipairs(recipe.items) do
    if item.count > 0 then
      needed[item.name] = item.count
    end
  end

  -- Call getItemDetail only for recipe items, not all items in stock.
  local maxCountFor = {}
  if stockIn then
    for slot, item in pairs(listItems(stockIn)) do
      local name = item.name
      if needed[name] and not maxCountFor[name] then
        local detail = stockIn.getItemDetail(slot)
        maxCountFor[name] = (detail and detail.maxCount) or 64
      end
    end
  end

  local maxBatch = math.huge
  for _, item in ipairs(recipe.items) do
    if item.count > 0 then
      local maxCount = maxCountFor[item.name] or 64
      local limit = math.floor(maxCount / item.count)
      if limit < maxBatch then
        maxBatch = limit
      end
    end
  end

  return math.max(1, maxBatch == math.huge and 1 or maxBatch)
end

function Stock.getTotals()
  local stock = getStockView()
  if not stock then
    return {}
  end
  local totals = {}
  for _, item in pairs(listItems(stock)) do
    local name = item.name
    totals[name] = (totals[name] or 0) + item.count
  end
  return totals
end

-- Returns a slot-addressable inventory facing the storage, plus its
-- peripheral name (needed for self-directed pushItems). Tries the Stock View
-- first; custom view peripherals may not expose size/list, so it falls back
-- to Stock Out, which faces the same storage.
local function slotInventory()
  -- pcall: a disconnected Stock View port falls through to Stock Out
  -- (same as the old wrap-returns-nil behavior) instead of erroring.
  local ok, inv, name = pcall(MultiInv.forRole, "stock_view")
  if not ok then
    inv, name = nil, nil
  end
  if not (inv and inv.size and inv.list) then
    inv, name = MultiInv.forRole("stock_out")
  end
  if not (inv and inv.size and inv.list) then
    Logger.raiseError(
      "Neither Stock View nor Stock Out exposes slots (size/list)"
    )
  end
  return inv, name
end

local function sumCounts(slots)
  local total = 0
  for _, s in ipairs(slots) do
    total = total + s.count
  end
  return total
end

-- Returns slot usage of the storage: total, used and free slot counts.
-- size() gives the full slot count and list() the occupied slots, so empty
-- slots are accounted for without polling each slot individually.
function Stock.getSlotUsage()
  local inv = slotInventory()

  local total = inv.size()
  local used = 0
  for _ in pairs(inv.list()) do
    used = used + 1
  end

  return total, used, total - used
end

-- Runs tasks in parallel batches, keeping coroutine counts sane when there
-- are hundreds of lookups.
local function runParallelBatched(tasks, batch)
  batch = batch or 128
  for i = 1, #tasks, batch do
    local chunk = {}
    for k = i, math.min(i + batch - 1, #tasks) do
      chunk[#chunk + 1] = tasks[k]
    end
    Utils.runParallel(chunk)
  end
end

-- Groups occupied slots by item identity: name + displayName. Same id with
-- different display names (e.g. three conduit types sharing one item id) are
-- different items and must not be merged; same display name with different
-- hidden data (e.g. stored energy) stays in one group so it shows up in the
-- report (the user can normalise such items so they stack).
-- displayName needs getItemDetail, so details are fetched only for slots of
-- items occupying 2+ slots -- single-slot items can't be fragmented.
-- Returns map key -> { name, displayName, maxCount, slots = {{slot,count}} }.
local function groupFragmentCandidates(inv)
  local byName = {}
  for slot, item in pairs(inv.list()) do
    byName[item.name] = byName[item.name] or {}
    table.insert(byName[item.name], { slot = slot, count = item.count })
  end

  local groups = {}
  local tasks = {}
  for name, slots in pairs(byName) do
    if #slots > 1 then
      for _, entry in ipairs(slots) do
        tasks[#tasks + 1] = function()
          local detail = inv.getItemDetail(entry.slot)
          if detail then
            local key = name .. "\0" .. (detail.displayName or "")
            local group = groups[key]
            if not group then
              group = {
                name = name,
                displayName = detail.displayName,
                maxCount = detail.maxCount or 64,
                slots = {},
              }
              groups[key] = group
            end
            table.insert(group.slots, entry)
          end
        end
      end
    end
  end
  runParallelBatched(tasks)

  return groups
end

-- Finds items spread across more slots than their counts require (partial
-- stacks that could be merged). Returns wastedTotal and rows
-- { name, displayName, slots, ideal, wasted } sorted by wasted desc.
function Stock.analyzeSlotFragmentation()
  local inv = slotInventory()
  local groups = groupFragmentCandidates(inv)

  local rows = {}
  local wastedTotal = 0
  for _, group in pairs(groups) do
    if #group.slots > 1 then
      local total = sumCounts(group.slots)
      local ideal = math.ceil(total / math.max(1, group.maxCount))
      local wasted = #group.slots - ideal
      if wasted > 0 then
        wastedTotal = wastedTotal + wasted
        table.insert(rows, {
          name = group.name,
          displayName = group.displayName,
          slots = #group.slots,
          ideal = ideal,
          wasted = wasted,
        })
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.wasted ~= b.wasted then
      return a.wasted > b.wasted
    end
    return a.name < b.name
  end)

  return wastedTotal, rows
end

-- Merges partial stacks so every item occupies its minimal slot count.
-- Groups are compacted concurrently (moves within a group stay sequential
-- because each move updates the same slots). Returns slots freed.
function Stock.fixSlotFragmentation()
  local inv, invName = slotInventory()
  local groups = groupFragmentCandidates(inv)

  local freed = 0
  local mergeTasks = {}
  for _, group in pairs(groups) do
    local maxCount = math.max(1, group.maxCount)
    local slots = group.slots
    if #slots > math.ceil(sumCounts(slots) / maxCount) then
      mergeTasks[#mergeTasks + 1] = function()
        -- Fullest stacks first as merge targets, smallest as sources.
        table.sort(slots, function(a, b)
          return a.count > b.count
        end)
        local i, j = 1, #slots
        while i < j do
          local dst, src = slots[i], slots[j]
          local space = maxCount - dst.count
          if space <= 0 then
            i = i + 1
          elseif src.count <= 0 then
            j = j - 1
          else
            local moved = inv.pushItems(
              invName,
              src.slot,
              math.min(space, src.count),
              dst.slot
            )
            if moved == 0 then
              -- Same display name but unstackable data (stored energy,
              -- damage, ...) or the slot changed under us: skip this
              -- source and try the next one.
              j = j - 1
            else
              dst.count = dst.count + moved
              src.count = src.count - moved
              if src.count <= 0 then
                freed = freed + 1
                j = j - 1
              end
              if dst.count >= maxCount then
                i = i + 1
              end
            end
          end
        end
      end
    end
  end
  runParallelBatched(mergeTasks)

  return freed
end

-- Like getTotals(), but damageable items are counted by remaining uses
-- (maxDamage - damage) instead of item count.
-- Also returns maxDmg map { [name] = maxDamage } for damageable items,
-- used to convert a use-shortage back to an item count.
function Stock.getDurabilityAwareTotals()
  local stock = getStockView()
  if not stock then
    return {}, {}
  end
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
  if not clipboard then
    return nil
  end

  local rawItems = clipboard.getItemEntries()
  if not rawItems then
    return {}
  end

  local totals = Stock.getTotals()
  local allRecipes = Recipes.getAllRecipes()

  local result = {}
  for _, entry in ipairs(rawItems) do
    local name = entry.item.name
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
  if not stockIn then
    Logger.raiseError("No stock_in configured")
  end

  local outName = Roles.getPort("materials_out")
  if not outName then
    Logger.raiseError("No materials_out configured")
  end

  local slotsByName = {}
  for slot, item in pairs(listItems(stockIn)) do
    local name = item.name
    if not slotsByName[name] then
      slotsByName[name] = {}
    end
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
        if remaining <= 0 then
          break
        end
        local take = math.min(entry.remaining, remaining)
        if take > 0 then
          local moved = stockIn.pushItems(outName, entry.slot, take)
          entry.remaining = entry.remaining - moved
          remaining = remaining - moved
        end
      end

      local moved = needed - remaining
      if moved > 0 then
        table.insert(transferred, { name = name, count = moved })
      end
      if remaining > 0 then
        table.insert(notFound, { name = name, count = remaining })
      end
    end
  end

  return transferred, notFound
end

-- Scans Stock View, resolving the displayName of every distinct item present,
-- and persists the results to the DisplayNames store.
-- wanted: optional set { [id] = true } of item ids we expect. Ids in `wanted`
--         that are not present in stock are returned in `notFound` (sorted).
-- Returns: found (map id -> displayName), foundCount, notFound (list of ids).
function Stock.scanDisplayNames(wanted)
  local view = getStockView()
  if not view then
    Logger.raiseError("Role 'Stock View' is not configured")
  end

  local found = {}
  local foundCount = 0
  for slot, item in pairs(listItems(view)) do
    if not found[item.name] then
      local detail = getItemDetail(view, slot)
      local displayName = detail and detail.displayName
      if displayName then
        found[item.name] = displayName
        foundCount = foundCount + 1
      end
    end
  end

  DisplayNames.setMany(found)

  local notFound = {}
  if wanted then
    for id in pairs(wanted) do
      if not found[id] then
        table.insert(notFound, id)
      end
    end
    table.sort(notFound)
  end

  return found, foundCount, notFound
end

return Stock

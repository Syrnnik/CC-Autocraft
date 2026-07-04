local Logger = require("lib.logger")
local Recipes = require("lib.recipes")
local Stock = require("lib.stock")

local Planner = {}

-- Recursively builds an ordered craft plan (sub-crafts first, target last).
-- Takes a stock snapshot once and tracks virtual consumption during planning,
-- so items already in stock are not crafted unnecessarily.
-- Items without a recipe are treated as base materials (must be in stock).
-- Returns list of { name, craftsCount, recipe }.
function Planner.buildCraftPlan(recipeName, neededCount, totals)
  local plan = {}
  -- Virtual stock: real stock minus items already allocated to plan steps.
  -- Surplus from crafts (e.g. recipe yields 4, only 3 needed) is tracked too.
  -- Damageable items are counted in remaining uses, not item count.
  local src = totals or Stock.getDurabilityAwareTotals()
  local available = {}
  for k, v in pairs(src) do
    available[k] = v
  end

  -- useStock: for sub-crafts, consume from virtual stock first, craft only
  -- the remainder. For the root item always craft the full requested amount.
  local function expand(name, count, useStock)
    local stillNeeded = count

    if useStock then
      local inStock = available[name] or 0
      stillNeeded = math.max(0, count - inStock)
      if stillNeeded == 0 then
        available[name] = inStock - count
        return
      end
      available[name] = 0
    end

    local ok, recipe = pcall(Recipes.getRecipe, name)
    if not ok then
      -- Base material: no recipe, must come from stock.
      return
    end

    local craftsCount = math.ceil(stillNeeded / recipe.count)
    -- Surplus produced by this batch goes back into virtual stock.
    available[name] = (available[name] or 0)
      + craftsCount * recipe.count
      - stillNeeded

    local ingredients = Recipes.getRequiredItemsPlainList(recipe)
    for _, ingredient in pairs(ingredients) do
      local needed = ingredient.catalyst and 1 or ingredient.count * craftsCount
      expand(ingredient.name, needed, true)
    end

    table.insert(
      plan,
      { name = name, craftsCount = craftsCount, recipe = recipe }
    )
  end

  expand(recipeName, neededCount, false)

  -- Merge duplicate steps: the same recipe can be reached through several
  -- branches of the tree (e.g. two sub-crafts each needing glass). Combine them
  -- into one step so the item is crafted all at once instead of in scattered
  -- batches. The merged step keeps the position of its FIRST occurrence, which
  -- still sits after all of its ingredients and before every consumer, so the
  -- plan order (sub-crafts first, target last) stays valid.
  local merged = {}
  local indexByName = {}
  for _, step in ipairs(plan) do
    local at = indexByName[step.name]
    if at then
      merged[at].craftsCount = merged[at].craftsCount + step.craftsCount
    else
      table.insert(merged, step)
      indexByName[step.name] = #merged
    end
  end

  return merged
end

-- Simulates plan execution against current stock and collects all shortfalls.
-- Returns list of { name, count } for every item that would be missing.
function Planner.validatePlan(plan, totals, maxDmg)
  local missingByName = {}
  local virtual
  if totals then
    virtual = {}
    for k, v in pairs(totals) do
      virtual[k] = v
    end
  else
    virtual, maxDmg = Stock.getDurabilityAwareTotals()
  end

  for _, step in ipairs(plan) do
    local craftsCount = step.craftsCount
    local ingredients = Recipes.getRequiredItemsPlainList(step.recipe)

    for _, ingredient in pairs(ingredients) do
      local needed = ingredient.catalyst and 1 or ingredient.count * craftsCount
      local have = virtual[ingredient.name] or 0

      if have < needed then
        local shortage = needed - have
        -- For damageable items: shortage is in uses; convert to item count.
        local md = maxDmg[ingredient.name] or 0
        local itemShortage = md > 0 and math.ceil(shortage / md) or shortage
        missingByName[ingredient.name] = (missingByName[ingredient.name] or 0)
          + itemShortage
        if not ingredient.catalyst then
          virtual[ingredient.name] = 0
        end
      elseif not ingredient.catalyst then
        virtual[ingredient.name] = have - needed
      end
    end

    -- Account for items produced by this step
    local name = step.recipe.name
    virtual[name] = (virtual[name] or 0) + step.recipe.count * craftsCount
  end

  local missing = {}
  for name, count in pairs(missingByName) do
    table.insert(missing, { name = name, count = count })
  end
  table.sort(missing, function(a, b)
    return a.name < b.name
  end)

  return missing
end

function Planner.printPlan(plan)
  Logger.printInfo(string.format("Craft plan (%d steps):", #plan))
  for i, step in ipairs(plan) do
    Logger.printInfo(
      string.format("  %d. '%s' x%d craft(s)", i, step.name, step.craftsCount)
    )
  end
end

return Planner

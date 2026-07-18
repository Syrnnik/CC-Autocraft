local Fluids = require("lib.fluids")
local Logger = require("lib.logger")
local Recipes = require("lib.recipes")
local Stock = require("lib.stock")
local Utils = require("lib.utils")

local Planner = {}

-- Fluids share the planner's virtual-stock tables with items, keyed as
-- "fluid:<id>" so a fluid can never collide with an item of the same id.
-- Amounts for fluid entries are mB, not item counts. Same-id NBT variants
-- are keyed "name\0nbt" (matching Stock.getDurabilityAwareTotals), so a
-- shortage names the exact variant instead of the shared id total.

-- Combined ingredient list of a recipe: items (variant-keyed, with their
-- displayName for messages) plus fluids under their prefixed names. Every
-- planner/validator/scheduler pass uses this so fluid and variant
-- requirements flow through the exact same accounting as plain items.
function Planner.getAllIngredients(recipe)
  local list = {}
  for _, item in ipairs(Recipes.getRequiredItemsPlainList(recipe)) do
    table.insert(list, {
      name = Utils.variantKey(item.name, item.nbt),
      count = item.count,
      catalyst = item.catalyst,
      displayName = item.displayName,
    })
  end
  for _, fluid in ipairs(Recipes.getRequiredFluidsPlainList(recipe)) do
    table.insert(list, { name = Fluids.PREFIX .. fluid.name, count = fluid.mb })
  end
  return list
end

-- Recipe lookup that understands prefixed fluid names and variant keys.
-- "fluid:" names resolve to fluid-result recipes. "name\0nbt" keys resolve
-- to the recipe producing that exact variant: by output nbt when the recipe
-- recorded one, else by the variant's displayName (recipes learned before
-- output-nbt tracking still resolve this way). Plain names prefer recipes
-- without an output nbt, falling back to any recipe with that item id.
local function resolveRecipe(recipes, name, displayName)
  if Fluids.isFluidName(name) then
    local fluidName = Fluids.stripPrefix(name)
    for _, recipe in pairs(recipes) do
      if recipe.resultType == "fluid" and recipe.name == fluidName then
        return recipe
      end
    end
    return nil
  end
  local base, nbt = name:match("^([^\0]+)\0(.+)$")
  if base then
    for _, recipe in pairs(recipes) do
      if
        recipe.name == base
        and recipe.nbt == nbt
        and recipe.resultType ~= "fluid"
      then
        return recipe
      end
    end
    if displayName then
      for _, recipe in pairs(recipes) do
        if
          recipe.name == base
          and recipe.displayName == displayName
          and recipe.resultType ~= "fluid"
        then
          return recipe
        end
      end
    end
    return nil
  end
  local fallback = nil
  local exact = recipes[name]
  if exact and exact.name == name and exact.resultType ~= "fluid" then
    if exact.nbt == nil then
      return exact
    end
    fallback = exact
  end
  for _, recipe in pairs(recipes) do
    if recipe.name == name and recipe.resultType ~= "fluid" then
      if recipe.nbt == nil then
        return recipe
      end
      fallback = fallback or recipe
    end
  end
  return fallback
end

-- Plan-space name of what a recipe produces: "fluid:<id>" for fluid
-- results, "name\0nbt" for variant outputs, plain name otherwise.
local function producedName(recipe)
  if recipe.resultType == "fluid" then
    return Fluids.PREFIX .. recipe.name
  end
  return Utils.variantKey(recipe.name, recipe.nbt)
end

-- Recursively builds an ordered craft plan (sub-crafts first, target last).
-- Takes a stock snapshot once and tracks virtual consumption during planning,
-- so items already in stock are not crafted unnecessarily.
-- Items without a recipe are treated as base materials (must be in stock).
-- Returns list of { name, craftsCount, recipe }.
-- rootRecipe: optional exact recipe for the target item. When the target name
-- has several variants (same name, different displayName), pass the specific
-- one to craft so the root resolves to it instead of an arbitrary variant.
-- Sub-crafts are still resolved by name (recipe.items carry no displayName).
function Planner.buildCraftPlan(recipeName, neededCount, totals, rootRecipe)
  local plan = {}
  -- Virtual stock: real stock minus items already allocated to plan steps.
  -- Surplus from crafts (e.g. recipe yields 4, only 3 needed) is tracked too.
  -- Damageable items are counted in remaining uses, not item count.
  local src = totals or Stock.getDurabilityAwareTotals()
  local available = {}
  for k, v in pairs(src) do
    available[k] = v
  end

  -- One recipe snapshot per plan build: getRecipe re-reads and parses the
  -- whole recipes file on every call, which multiplied across the tree made
  -- planning slow. Loading once here turns every lookup below into a plain
  -- table read, and a fresh snapshot per plan still picks up recipe edits.
  local allRecipes = Recipes.getAllRecipes()

  -- Items currently being expanded (the path from the root down to here). Used
  -- to break reversible-recipe cycles like gold_ingot <-> gold_block.
  local onStack = {}

  -- useStock: for sub-crafts, consume from virtual stock first, craft only
  -- the remainder. For the root item always craft the full requested amount.
  -- displayName: the ingredient's variant name, used to resolve variant
  -- recipes that predate output-nbt tracking.
  local function expand(name, count, useStock, explicitRecipe, displayName)
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

    local recipe = explicitRecipe
      or resolveRecipe(allRecipes, name, displayName)
    if not recipe then
      -- Base material: no recipe, must come from stock.
      return
    end

    local ingredients = Planner.getAllIngredients(recipe)

    -- Cycle guard: if crafting `name` would need an ingredient that is already
    -- being expanded higher up the tree, we'd recurse forever (e.g. an ingot
    -- crafted from a block that is crafted from ingots). Treat `name` as a base
    -- material instead: whatever stock can't cover is reported as missing for
    -- `name`. So crafting an ingot reports missing blocks, and crafting a block
    -- reports missing ingots -- the loop is cut at the first re-entry.
    for _, ingredient in pairs(ingredients) do
      if onStack[ingredient.name] then
        return
      end
    end

    local craftsCount = math.ceil(stillNeeded / recipe.count)
    -- Surplus produced by this batch goes back into virtual stock.
    available[name] = (available[name] or 0)
      + craftsCount * recipe.count
      - stillNeeded

    onStack[name] = true
    for _, ingredient in pairs(ingredients) do
      local needed = ingredient.catalyst and 1 or ingredient.count * craftsCount
      expand(ingredient.name, needed, true, nil, ingredient.displayName)
    end
    onStack[name] = nil

    table.insert(
      plan,
      { name = name, craftsCount = craftsCount, recipe = recipe }
    )
  end

  -- Root: fluid recipes plan under their prefixed name so consumers of the
  -- fluid (and the virtual-stock bookkeeping) line up with the plan step.
  local rootPlanName = recipeName
  do
    local root = rootRecipe or resolveRecipe(allRecipes, recipeName)
    if not root and not Fluids.isFluidName(recipeName) then
      -- The name may belong to a fluid-only recipe (crafted from the
      -- RECIPES tab, which passes the bare fluid id).
      root = resolveRecipe(allRecipes, Fluids.PREFIX .. recipeName)
    end
    if root and root.resultType == "fluid" then
      rootPlanName = Fluids.PREFIX .. Fluids.stripPrefix(recipeName)
    elseif root and root.nbt then
      -- Variant output: plan under its variant key so consumers and the
      -- virtual-stock bookkeeping line up.
      rootPlanName = Utils.variantKey(recipeName, root.nbt)
    end
  end
  expand(rootPlanName, neededCount, false, rootRecipe)

  -- Group duplicate steps: the same item can be reached through several
  -- branches of the tree (e.g. many sub-crafts each needing printed_silicon),
  -- so craft each item once as a single batch. Quantities are summed per item.
  --
  -- Ordering matters and a first-occurrence merge is NOT safe: when an item is
  -- partly covered by stock, its early consumers draw it from stock and create
  -- no craft step, so the item's first craft step lands AFTER those consumers.
  -- Placing the merged batch there leaves a consumer before its producer, which
  -- validatePlan then reports as a false shortage. Instead emit one step per
  -- item in dependency order (every crafted ingredient before its consumers)
  -- via a topological sort. Cycles can't occur -- the expand guard above breaks
  -- reversible recipes -- but the in-progress mark guards against them anyway.
  local aggregated = {}
  local order = {}
  for _, step in ipairs(plan) do
    local a = aggregated[step.name]
    if a then
      a.craftsCount = a.craftsCount + step.craftsCount
    else
      aggregated[step.name] = {
        name = step.name,
        craftsCount = step.craftsCount,
        recipe = step.recipe,
      }
      order[#order + 1] = step.name
    end
  end

  local sorted = {}
  local mark = {} -- nil = unseen, 1 = in progress, 2 = done
  local function visit(name)
    local a = aggregated[name]
    if not a or mark[name] then
      return
    end
    mark[name] = 1
    for _, ingredient in ipairs(Planner.getAllIngredients(a.recipe)) do
      if aggregated[ingredient.name] then
        visit(ingredient.name)
      end
    end
    mark[name] = 2
    sorted[#sorted + 1] = a
  end
  for _, name in ipairs(order) do
    visit(name)
  end

  return sorted
end

-- Simulates plan execution against current stock and collects all shortfalls.
-- Returns list of { name, count, displayName } for every item that would be
-- missing (name may be a variant key or a "fluid:" name; displayName is the
-- variant's friendly name when the recipe recorded one).
function Planner.validatePlan(plan, totals, maxDmg)
  local missingByName = {}
  local missingDisplay = {}
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
    local ingredients = Planner.getAllIngredients(step.recipe)

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
        missingDisplay[ingredient.name] = missingDisplay[ingredient.name]
          or ingredient.displayName
        if not ingredient.catalyst then
          virtual[ingredient.name] = 0
        end
      elseif not ingredient.catalyst then
        virtual[ingredient.name] = have - needed
      end
    end

    -- Account for what this step produces under its PLAN-SPACE name (the
    -- key consumers reference) -- a variant step resolved via displayName
    -- fallback produces the requested variant even though the stored
    -- recipe carries no output nbt.
    local name = step.name or producedName(step.recipe)
    virtual[name] = (virtual[name] or 0) + step.recipe.count * craftsCount
  end

  local missing = {}
  for name, count in pairs(missingByName) do
    table.insert(
      missing,
      { name = name, count = count, displayName = missingDisplay[name] }
    )
  end
  table.sort(missing, function(a, b)
    return a.name < b.name
  end)

  return missing
end

-- Rough duration estimate for a plan, in seconds: runs * avgTime summed
-- over all steps (a chunked crafter batch counts chunks, a machine batch
-- counts cycles -- the same units craft progress uses). Recipes with no
-- measured avgTime yet fall back to defaults (crafter ~2s/chunk, machine
-- ~10s/cycle), so first-run numbers are approximate and tighten as
-- measurements accumulate. Steps are summed sequentially, so for pipelined
-- plans this is an upper bound.
function Planner.estimateTime(plan)
  local total = 0
  for _, step in ipairs(plan) do
    local recipe = step.recipe
    local isMachine = (recipe.type or "crafter") == "machine"
    local runs
    if isMachine then
      runs = step.craftsCount
    else
      local ok, maxBatch = pcall(Stock.getMaxBatchForRecipe, recipe)
      if not ok or not maxBatch or maxBatch < 1 then
        maxBatch = 1
      end
      runs = math.ceil(step.craftsCount / maxBatch)
    end
    local avg = recipe.avgTime or (isMachine and 10 or 2)
    total = total + runs * avg
  end
  return total
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

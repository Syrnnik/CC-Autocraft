local Config = require("lib.config")
local DisplayNames = require("lib.display_names")
local Labels = require("lib.labels")
local Logger = require("lib.logger")
local Roles = require("lib.roles")

-- Returns the label for a peripheral port if one is set, else returns the port as-is.
local function toLabelOrPort(port)
  if not port then
    return nil
  end
  return Labels.get(port) or port
end

local recipesPath = Config.RECIPES_PATH

local Recipes = {}

function Recipes.countRecipeSlot(
  slot,
  row,
  patternOffset,
  rowSize,
  newPatternSize
)
  local recipeSlot = slot
  -- Convert absolute interface slot into position relative to pattern start
  recipeSlot = recipeSlot - patternOffset
  -- Remove offset caused by full interface rows
  -- After this, recipeSlot contains position inside current pattern row
  recipeSlot = recipeSlot - rowSize * row
  -- Add row offset for recipe grid
  recipeSlot = recipeSlot + newPatternSize * row

  return recipeSlot
end

function Recipes.countCrafterSlot(slot)
  local row = math.floor((slot - 1) / Config.PATTERN_SIZE)
  -- Offset by patterns diff in each row
  local patternsDiff = math.abs(Config.PATTERN_SIZE - Config.CRAFTER_ROW_SIZE)
  return slot + row * patternsDiff + 1
end

function Recipes.getNewRecipeItems(interfaceName)
  local recipeItems = {}

  local interface = peripheral.wrap(interfaceName)

  -- Iterate rows in interface
  for row = 0, Config.PATTERN_SIZE - 1 do
    local offset = Config.NEW_RECIPE_INTERFACE_ROW_SIZE * row
    local rowStart = Config.PATTERN_START + offset
    local rowEnd = rowStart + Config.PATTERN_SIZE - 1

    -- Iterate slots in row
    for slot = rowStart, rowEnd do
      local item = interface.getItemDetail(slot)

      -- Save recipe item
      if item then
        local itemName = item.name
        local itemCount = item.count
        Logger.printDebug(
          string.format("Slot %d has '%s' x%d ", slot, itemName, itemCount)
        )

        local recipeSlot = Recipes.countRecipeSlot(
          slot,
          row,
          Config.PATTERN_START - 1,
          Config.NEW_RECIPE_INTERFACE_ROW_SIZE,
          Config.PATTERN_SIZE
        )
        local crafterSlot = Recipes.countCrafterSlot(recipeSlot)
        table.insert(recipeItems, {
          slot = slot,
          recipeSlot = recipeSlot,
          crafterSlot = crafterSlot,
          name = itemName,
          count = itemCount,
        })
      else
        Logger.printDebug(string.format("Slot %d is empty", slot))
      end
    end
  end

  return recipeItems
end

function Recipes.getRequiredItemsPlainList(recipe)
  local itemName = recipe.name
  Logger.printDebug(string.format("To craft '%s' need", itemName))

  local recipeItems = recipe.items
  local requiredItems = {}

  for _, recipeItem in pairs(recipeItems) do
    local recipeItemName = recipeItem.name
    local recipeItemCount = recipeItem.count

    local isExists = false
    for i, requiredItem in pairs(requiredItems) do
      if recipeItemName == requiredItem.name then
        isExists = true
        if not recipeItem.catalyst then
          requiredItems[i].count = requiredItem.count + recipeItemCount
        end
        break
      end
    end

    if not isExists then
      table.insert(requiredItems, {
        name = recipeItemName,
        count = recipeItem.catalyst and 1 or recipeItemCount,
        catalyst = recipeItem.catalyst or nil,
      })
    end
  end

  for _, item in pairs(requiredItems) do
    Logger.printDebug(string.format("- '%s' x%d", item.name, item.count))
  end

  return requiredItems
end

-- Aggregates recipe.fluids by fluid name (mB summed). Returns a list of
-- { name, mb }; empty when the recipe uses no fluids.
function Recipes.getRequiredFluidsPlainList(recipe)
  local required = {}
  for _, fluid in ipairs(recipe.fluids or {}) do
    local found = false
    for _, entry in ipairs(required) do
      if entry.name == fluid.name then
        entry.mb = entry.mb + fluid.mb
        found = true
        break
      end
    end
    if not found then
      table.insert(required, { name = fluid.name, mb = fluid.mb })
    end
  end
  return required
end

function Recipes.getAllRecipes()
  local craftsFile = fs.open(recipesPath, "r")
  local crafts = {}

  if craftsFile then
    local content = craftsFile.readAll()
    craftsFile.close()
    if content and #content > 0 then
      crafts = textutils.unserializeJSON(content) or {}
    end
  end

  return crafts
end

function Recipes.getAllRecipesItems()
  local allRecipes = Recipes.getAllRecipes()

  local items = {}
  for _, recipe in pairs(allRecipes) do
    table.insert(items, recipe.name)
  end

  return items
end

function Recipes.saveAllRecipes(recipes)
  local file = fs.open(recipesPath, "w")

  if file then
    file.write(textutils.serializeJSON(recipes))
    file.close()
    Logger.printSuccess(string.format("Recipe saved to '%s'", recipesPath))
  else
    Logger.printError(
      string.format("Failed to open '%s' for writing", recipesPath)
    )
  end
end

-- Locates the actual storage key for a recipe identity token: either an exact
-- key returned by getAllRecipes, or a bare item name (matching the first
-- variant with that name). Returns nil when nothing matches.
local function resolveStoredKey(recipes, token)
  if recipes[token] then
    return token
  end
  for key, recipe in pairs(recipes) do
    if recipe.name == token then
      return key
    end
  end
  return nil
end

function Recipes.addNewRecipe(newRecipe)
  local recipes = Recipes.getAllRecipes()

  local name = newRecipe.name
  local displayName = newRecipe.displayName

  -- Recipe identity is (name, displayName, resultType): reuse the existing
  -- slot only when ALL match, so a same-name item with a different
  -- displayName -- or a fluid recipe whose fluid id happens to equal an item
  -- id -- is stored as a separate recipe instead of overwriting the old one.
  local key
  for k, recipe in pairs(recipes) do
    if
      recipe.name == name
      and recipe.displayName == displayName
      and recipe.resultType == newRecipe.resultType
    then
      key = k
      break
    end
  end

  -- No matching variant yet: take the bare name, or name~N when the name is
  -- already occupied by a different-displayName variant. The suffix is opaque —
  -- recipes are always located by identity or by their stored key, never by
  -- parsing it — so it stays JSON-safe (no exotic separators in map keys).
  if not key then
    if recipes[name] == nil then
      key = name
    else
      local i = 1
      while recipes[name .. "~" .. i] ~= nil do
        i = i + 1
      end
      key = name .. "~" .. i
    end
  end

  recipes[key] = newRecipe
  Recipes.saveAllRecipes(recipes)
end

-- recipeFluids: optional list of { name, mb, processor } (machine type only).
-- craftedItem.isFluid marks a fluid result: the recipe is stored with
-- resultType = "fluid", name = fluid id and count = mB produced per craft.
function Recipes.saveRecipe(
  recipeItems,
  craftedItem,
  type,
  processor,
  resultProcessor,
  recipeFluids
)
  local items = {}

  if type == "machine" then
    for _, item in ipairs(recipeItems) do
      table.insert(items, {
        name = item.name,
        count = item.count,
        processor = toLabelOrPort(item.processor),
      })
    end
  else
    for _, item in ipairs(recipeItems) do
      local entry = {
        name = item.name,
        count = item.count,
        slot = item.recipeSlot,
      }
      if item.catalyst then
        entry.catalyst = true
      end
      table.insert(items, entry)
    end
  end

  local recipe = {
    name = craftedItem.name,
    displayName = craftedItem.displayName or nil,
    count = craftedItem.count,
    maxCount = craftedItem.maxCount or nil,
    items = items,
    type = type or "crafter",
  }

  if craftedItem.isFluid then
    recipe.resultType = "fluid"
    recipe.maxCount = nil
  end

  if type == "machine" then
    recipe.resultProcessor = toLabelOrPort(resultProcessor)
    if recipeFluids and #recipeFluids > 0 then
      recipe.fluids = {}
      for _, fluid in ipairs(recipeFluids) do
        table.insert(recipe.fluids, {
          name = fluid.name,
          mb = fluid.mb,
          processor = toLabelOrPort(fluid.processor),
        })
      end
    end
  else
    recipe.processor = toLabelOrPort(processor or Roles.get("crafter"))
  end

  -- Mirror the crafted item's displayName into the shared store so tables can
  -- show a friendly name without re-scanning stock. Fluids have no
  -- displayName (tanks() reports ids only), so there is nothing to mirror.
  if not craftedItem.isFluid then
    DisplayNames.set(craftedItem.name, craftedItem.displayName)
  end

  Recipes.addNewRecipe(recipe)
end

-- Updates type, processor(s), and resultProcessor of an existing recipe.
-- itemProcessors: { [itemName] = processorName } for machine recipes.
-- recipeFluids: optional replacement fluid list { name, mb, processor }
-- for machine recipes (nil leaves the stored fluids untouched).
function Recipes.updateRecipeProcessor(
  key,
  type,
  processor,
  resultProcessor,
  itemProcessors,
  recipeFluids
)
  local recipes = Recipes.getAllRecipes()
  local storeKey = resolveStoredKey(recipes, key)

  if not storeKey then
    Logger.raiseError(string.format("Recipe '%s' not found", key))
  end

  local recipe = recipes[storeKey]
  recipe.type = type

  if type == "machine" then
    recipe.resultProcessor = toLabelOrPort(resultProcessor)
    recipe.processor = nil
    for _, item in ipairs(recipe.items) do
      local proc = itemProcessors and itemProcessors[item.name]
      item.processor = proc and toLabelOrPort(proc) or nil
    end
    if recipeFluids then
      if #recipeFluids > 0 then
        recipe.fluids = {}
        for _, fluid in ipairs(recipeFluids) do
          table.insert(recipe.fluids, {
            name = fluid.name,
            mb = fluid.mb,
            processor = toLabelOrPort(fluid.processor),
          })
        end
      else
        recipe.fluids = nil
      end
    end
  else
    recipe.processor = toLabelOrPort(processor or Roles.get("crafter"))
    recipe.resultProcessor = nil
    recipe.fluids = nil
  end

  Recipes.saveAllRecipes(recipes)
  Logger.printSuccess(string.format("Processor updated for '%s'", recipe.name))
end

function Recipes.deleteRecipe(key)
  local recipes = Recipes.getAllRecipes()
  local storeKey = resolveStoredKey(recipes, key)

  if not storeKey then
    Logger.raiseError(string.format("Recipe '%s' not found", key))
  end

  recipes[storeKey] = nil
  Recipes.saveAllRecipes(recipes)
  Logger.printSuccess(string.format("Recipe '%s' deleted", storeKey))
end

-- Looks up a recipe by item name (used by the planner and CLI, which only know
-- the name). When several variants share a name, returns the first one found.
function Recipes.getRecipe(recipeName)
  local allRecipes = Recipes.getAllRecipes()
  local key = resolveStoredKey(allRecipes, recipeName)
  local recipe = key and allRecipes[key]

  if not recipe then
    Logger.raiseError(string.format("Recipe '%s' not found", recipeName))
  end

  return recipe
end

-- Exact lookup by the storage key from getAllRecipes: identifies a single
-- name+displayName variant. Unlike getRecipe it returns nil when missing
-- instead of raising.
function Recipes.getRecipeByKey(key)
  local allRecipes = Recipes.getAllRecipes()
  local storeKey = resolveStoredKey(allRecipes, key)
  return storeKey and allRecipes[storeKey] or nil
end

-- Resolves a recipe from an already-loaded recipes table (as returned by
-- getAllRecipes) without re-reading the file. Same lookup semantics as
-- getRecipe: exact storage key first, then the first variant matching the
-- item name. Returns nil when nothing matches. Callers that do many lookups
-- (the planner) load one snapshot and use this instead of getRecipe, which
-- parses the whole recipes file on every call.
function Recipes.getFromSnapshot(recipes, name)
  local key = resolveStoredKey(recipes, name)
  return key and recipes[key] or nil
end

-- Finds an existing recipe that matches BOTH the item id (name) and the
-- displayName. Returns the recipe and its storage key, or nil if none matches.
function Recipes.findExisting(name, displayName)
  local recipes = Recipes.getAllRecipes()

  for key, recipe in pairs(recipes) do
    if
      recipe.name == name
      and recipe.displayName == displayName
      and recipe.resultType ~= "fluid"
    then
      return recipe, key
    end
  end

  return nil
end

-- Finds an existing fluid-result recipe for the given fluid id.
-- Returns the recipe and its storage key, or nil if none matches.
function Recipes.findExistingFluid(name)
  local recipes = Recipes.getAllRecipes()

  for key, recipe in pairs(recipes) do
    if recipe.resultType == "fluid" and recipe.name == name then
      return recipe, key
    end
  end

  return nil
end

return Recipes

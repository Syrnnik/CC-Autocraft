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

local patternSize = Config.PATTERN_SIZE
local crafterRowSize = Config.CRAFTER_ROW_SIZE
local patternsDiff = math.abs(patternSize - crafterRowSize)

local interfaceRowSize = Config.NEW_RECIPE_INTERFACE_ROW_SIZE
local patternStart = Config.PATTERN_START

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
  local row = math.floor((slot - 1) / patternSize)
  -- Offset by patterns diff in each row
  return slot + row * patternsDiff + 1
end

function Recipes.getNewRecipeItems(interfaceName)
  local recipeItems = {}

  local interface = peripheral.wrap(interfaceName)

  -- Iterate rows in interface
  for row = 0, patternSize - 1 do
    local offset = interfaceRowSize * row
    local rowStart = patternStart + offset
    local rowEnd = rowStart + patternSize - 1

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
          patternStart - 1,
          interfaceRowSize,
          patternSize
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

  -- Recipe identity is (name, displayName): reuse the existing slot only when
  -- BOTH match, so a same-name item with a different displayName is stored as a
  -- separate recipe instead of overwriting the old one.
  local key
  for k, recipe in pairs(recipes) do
    if recipe.name == name and recipe.displayName == displayName then
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

function Recipes.saveRecipe(
  recipeItems,
  craftedItem,
  type,
  processor,
  resultProcessor
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

  if type == "machine" then
    recipe.resultProcessor = toLabelOrPort(resultProcessor)
  else
    recipe.processor = toLabelOrPort(processor or Roles.get("crafter"))
  end

  -- Mirror the crafted item's displayName into the shared store so tables can
  -- show a friendly name without re-scanning stock.
  DisplayNames.set(craftedItem.name, craftedItem.displayName)

  Recipes.addNewRecipe(recipe)
end

-- Updates type, processor(s), and resultProcessor of an existing recipe.
-- itemProcessors: { [itemName] = processorName } for machine recipes.
function Recipes.updateRecipeProcessor(
  key,
  type,
  processor,
  resultProcessor,
  itemProcessors
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
  else
    recipe.processor = toLabelOrPort(processor or Roles.get("crafter"))
    recipe.resultProcessor = nil
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

-- Finds an existing recipe that matches BOTH the item id (name) and the
-- displayName. Returns the recipe and its storage key, or nil if none matches.
function Recipes.findExisting(name, displayName)
  local recipes = Recipes.getAllRecipes()

  for key, recipe in pairs(recipes) do
    if recipe.name == name and recipe.displayName == displayName then
      return recipe, key
    end
  end

  return nil
end

return Recipes

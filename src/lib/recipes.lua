local Config = require("lib.config")
local Logger = require("lib.logger")

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
        requiredItems[i].count = requiredItem.count + recipeItemCount

        break
      end
    end

    if not isExists then
      table.insert(requiredItems, {
        name = recipeItemName,
        count = recipeItemCount,
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

function Recipes.addNewRecipe(newRecipe)
  local recipes = Recipes.getAllRecipes()

  local recipeName = newRecipe.name

  -- * This variant store one recipe for each item
  recipes[recipeName] = newRecipe

  -- * This variant can store many recipes for each item (future)
  -- if not recipes[recipeName] then
  --   recipes[recipeName] = {}
  -- end
  -- table.insert(recipes[recipeName], newRecipe)

  Recipes.saveAllRecipes(recipes)
end

function Recipes.saveRecipe(recipeItems, craftedItem)
  local items = {}

  for _, item in ipairs(recipeItems) do
    table.insert(items, {
      name = item.name,
      count = item.count,
      slot = item.recipeSlot,
    })
  end

  local recipe = {
    name = craftedItem.name,
    count = craftedItem.count,
    items = items,
  }

  Recipes.addNewRecipe(recipe)
end

function Recipes.getRecipe(recipeName)
  local allRecipes = Recipes.getAllRecipes()
  local recipe = allRecipes[recipeName]

  if not recipe then
    Logger.raiseError(string.format("Recipe '%s' not found", recipeName))
  end

  return recipe
end

return Recipes

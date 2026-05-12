local Config = require("lib.config")
local Crafting = require("lib.crafting")
local Network = require("lib.network")
local Recipes = require("lib.recipes")
local Stock = require("lib.stock")

local UI = {}

local mon, W, H
local buttons = {}
local pendingTask = nil

local state = {
  tab = "recipes",
  page = 1,
  recipes = {}, -- { name, count }
  selected = nil,
  craftCount = 1,
  msg = nil,
  msgIsErr = false,
  pendingRecipe = nil, -- { items, craftedItem, name, alreadyExists }
  deleteTarget = nil, -- recipe name pending deletion
  editTarget = nil, -- recipe name being edited (display hint)
  stockItems = {}, -- { name, count } sorted by name
  stockPage = 1,
  type = "crafter", -- "crafter" | "machine"
  availableMachines = {}, -- populated by reloadMachines()
  -- machine recipe state
  machineItems = {}, -- { name, count, slot, processor } scanned from barrel
  selectedItemIdx = nil, -- index in machineItems for inline machine picker
  resultProcessor = nil, -- machine to pull result from
  resultPickerOpen = false,
}

local L = 2 -- left margin
local HEADER_H = 5 -- pixel-art header height
local SEP_ROW = HEADER_H + 1 -- 6  decorative separator
local TABS_ROW = HEADER_H + 2 -- 7
local BODY_ROW = TABS_ROW + 1 -- 8  (first content row)

-- ── Drawing primitives ──────────────────────────────────────

local function fill(y, bg)
  mon.setCursorPos(1, y)
  mon.setBackgroundColor(bg)
  mon.clearLine()
end

local function at(x, y, text, fg, bg)
  mon.setCursorPos(x, y)
  mon.setBackgroundColor(bg)
  mon.setTextColor(fg)
  mon.write(text)
end

local function mkBtn(x, y, label, fg, bg, action)
  local text = " " .. label .. " "
  at(x, y, text, fg, bg)
  table.insert(buttons, { x1 = x, x2 = x + #text - 1, y = y, fn = action })
end

-- Button with no padding — label rendered as-is, hit area = label width.
local function mkBtnTight(x, y, label, fg, bg, action)
  at(x, y, label, fg, bg)
  table.insert(buttons, { x1 = x, x2 = x + #label - 1, y = y, fn = action })
end

local function truncate(s, maxLen)
  if #s <= maxLen then
    return s
  end
  return s:sub(1, maxLen - 3) .. "..."
end

local reloadRecipes
local reloadStock
local reloadMachines
local reloadMachineItems

-- ── Sections ───────────────────────────────────────────────

local function drawHeader()
  -- Pixel-art "SyrOS". Each pixel = 2 chars wide. Black background.
  -- '#' = on (yellow), '.' = off (black).
  local font = {
    S = { ".###", "#...", ".##.", "...#", "###." },
    y = { "#..#", "#..#", ".###", "...#", ".##." },
    r = { ".##", "#.#", "#..", "#..", "#.." },
    O = { ".###.", "#...#", "#...#", "#...#", ".###." },
  }
  local chars = { "S", "y", "r", "O", "S" }
  local pixW = 2 -- pixels per cell (horizontal)
  local gap = 2 -- chars between characters

  -- Compute total rendered width for centering
  local totalW = 0
  for i, ch in ipairs(chars) do
    totalW = totalW + #font[ch][1] * pixW
    if i < #chars then
      totalW = totalW + gap
    end
  end

  local startX = math.floor((W - totalW) / 2) + 1

  for row = 1, HEADER_H do
    fill(row, colors.black)
  end

  local x = startX
  for _, ch in ipairs(chars) do
    local bitmap = font[ch]
    local charW = #bitmap[1]
    for row = 1, HEADER_H do
      local pattern = bitmap[row]
      for col = 1, charW do
        if pattern:sub(col, col) == "#" then
          at(x + (col - 1) * pixW, row, "  ", colors.black, colors.yellow)
        end
      end
    end
    x = x + charW * pixW + gap
  end
end

local function drawSeparator()
  fill(SEP_ROW, colors.black)
  mon.setCursorPos(1, SEP_ROW)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.yellow)
  mon.write(string.rep("-", W))
end

local function drawTabs()
  fill(TABS_ROW, colors.black)
  local x = L

  local tabs = {
    { id = "recipes", label = " RECIPES " },
    { id = "stock", label = " STOCK " },
    { id = "new_recipe", label = " +RECIPE " },
  }

  for _, tab in ipairs(tabs) do
    local active = state.tab == tab.id
    at(
      x,
      TABS_ROW,
      tab.label,
      active and colors.black or colors.gray,
      active and colors.yellow or colors.black
    )
    local x1, x2 = x, x + #tab.label - 1
    table.insert(buttons, {
      x1 = x1,
      x2 = x2,
      y = TABS_ROW,
      fn = function()
        if tab.id == "recipes" then
          state.tab = "recipes"
          state.selected = nil
          state.msg = nil
          state.page = 1
          state.pendingRecipe = nil
          state.deleteTarget = nil
          state.editTarget = nil
        elseif tab.id == "stock" then
          state.tab = "stock"
          state.stockPage = 1
          reloadStock()
        elseif tab.id == "new_recipe" then
          state.tab = "new_recipe"
          state.msg = nil
          state.pendingRecipe = nil
          state.editTarget = nil
          reloadMachines()
          if state.type == "machine" then
            reloadMachineItems()
          end
        end
      end,
    })
    x = x + #tab.label + 1
  end
end

-- ── Recipes tab ─────────────────────────────────────────────

local function drawRecipesList()
  local headerY = BODY_ROW
  local listStart = BODY_ROW + 1
  local paginationY = H
  local listH = paginationY - listStart

  for y = headerY, H do
    fill(y, colors.black)
  end

  -- Column layout derived from the longest recipe name.
  --
  -- Right zone (fixed widths, left-to-right):
  --   count col  : 6 chars  (xCount .. xCount+5)
  --   [ Craft ]  : 7 chars  + 1 gap = 8
  --   [ Edit ]   : 6 chars  + 1 gap = 7
  --   [ Del ]    : 5 chars  (flush right)
  -- Total right  : 6 + 8 + 7 + 5 = 26 chars
  -- Gap name→count: 1
  -- itemW = min(longest name, W - L - 27)
  --
  -- Inline controls (25 chars, xCraft .. xCraft+24):
  --   <<<  sp  <<  sp  <  sp  CCC  sp  >  sp  >>  sp  >>>  sp   X
  --    3   1    2   1   1   1   3   1   1   1   2   1    3   1  [3]

  local maxNameLen = 0
  for _, r in ipairs(state.recipes) do
    if #r.name > maxNameLen then
      maxNameLen = #r.name
    end
  end
  local itemW = math.max(0, math.min(maxNameLen, W - L - 27))
  local xCount = L + itemW + 1
  local xCraft = xCount + 6
  local xEdit = xCraft + 8
  local xDel = xEdit + 7

  -- Header row: gray bg normally; replaced by status message when crafting
  if state.msg then
    local fg = state.msgIsErr and colors.red or colors.yellow
    fill(headerY, colors.black)
    at(L, headerY, truncate(state.msg, W - L), fg, colors.black)
  else
    fill(headerY, colors.gray)
    at(xCount - #"ITEM" - 1, headerY, "ITEM", colors.lightGray, colors.gray)
    at(xCount, headerY, "COUNT", colors.lightGray, colors.gray)
  end

  local total = #state.recipes
  local totalPages = math.max(1, math.ceil(total / listH))
  state.page = math.min(state.page, totalPages)

  local startIdx = (state.page - 1) * listH + 1
  local endIdx = math.min(startIdx + listH - 1, total)

  if total == 0 then
    at(L, listStart + 1, "No recipes yet", colors.gray, colors.black)
  else
    for i = startIdx, endIdx do
      local recipe = state.recipes[i]
      local row = listStart + (i - startIdx)
      local captured = recipe.name

      local name = truncate(recipe.name, itemW)
      at(
        math.max(L, xCount - #name - 1),
        row,
        name,
        colors.lightGray,
        colors.black
      )
      at(xCount, row, "x" .. recipe.count, colors.yellow, colors.black)

      if captured == state.deleteTarget then
        mkBtn(xCraft, row, "Delete", colors.white, colors.red, function()
          local ok, err = pcall(Recipes.deleteRecipe, captured)
          if ok then
            state.deleteTarget = nil
            state.msg = nil
          else
            state.msg = tostring(err)
            state.msgIsErr = true
            state.deleteTarget = nil
          end
          reloadRecipes()
        end)
        mkBtn(xCraft + 10, row, "Cancel", colors.white, colors.gray, function()
          state.deleteTarget = nil
        end)
      elseif captured == state.selected then
        -- Inline controls (25 chars, starting at xCraft or pulled left to fit).
        --
        --  +0  <<<  (3)   +3  sp
        --  +4  <<   (2)   +6  sp
        --  +7  <    (1)   +8  sp
        --  +9  CCC  (3, yellow = craft confirm)  +12 sp
        --  +13 >    (1)   +14 sp
        --  +15 >>   (2)   +17 sp
        --  +18 >>>  (3)   +21 sp
        --  +22 " X "  (3)
        local xb = math.min(xCraft, W - 24)
        local cnt = state.craftCount

        mkBtnTight(xb, row, "<<<", colors.lightGray, colors.gray, function()
          state.craftCount = math.max(1, state.craftCount - 100)
        end)
        mkBtnTight(xb + 4, row, "<<", colors.lightGray, colors.gray, function()
          state.craftCount = math.max(1, state.craftCount - 10)
        end)
        mkBtnTight(xb + 7, row, "<", colors.lightGray, colors.gray, function()
          state.craftCount = math.max(1, state.craftCount - 1)
        end)

        at(xb + 9, row, string.format("%3d", cnt), colors.black, colors.yellow)
        local craftName = captured
        local craftCount = cnt
        table.insert(buttons, {
          x1 = xb + 9,
          x2 = xb + 11,
          y = row,
          fn = function()
            state.msg = "Crafting " .. craftName .. " x" .. craftCount .. "..."
            state.msgIsErr = false
            pendingTask = function()
              local ok, err = pcall(Crafting.craftItem, craftName, craftCount)
              if ok then
                state.selected = nil
                state.craftCount = 1
                state.msg = nil
              else
                state.msg = tostring(err)
                state.msgIsErr = true
              end
              reloadRecipes()
            end
          end,
        })

        mkBtnTight(xb + 13, row, ">", colors.lightGray, colors.gray, function()
          state.craftCount = state.craftCount + 1
        end)
        mkBtnTight(xb + 15, row, ">>", colors.lightGray, colors.gray, function()
          state.craftCount = state.craftCount + 10
        end)
        mkBtnTight(
          xb + 18,
          row,
          ">>>",
          colors.lightGray,
          colors.gray,
          function()
            state.craftCount = state.craftCount + 100
          end
        )

        mkBtn(xb + 22, row, "X", colors.white, colors.red, function()
          state.selected = nil
          state.craftCount = 1
          state.msg = nil
        end)
      else
        mkBtn(xCraft, row, "Craft", colors.black, colors.yellow, function()
          state.selected = captured
          state.craftCount = 1
          state.msg = nil
        end)
        mkBtn(xEdit, row, "Edit", colors.white, colors.gray, function()
          state.tab = "new_recipe"
          state.editTarget = captured
          state.msg = nil
          state.pendingRecipe = nil
        end)
        mkBtn(xDel, row, "Del", colors.white, colors.red, function()
          state.deleteTarget = captured
          state.msg = nil
        end)
      end
    end
  end

  -- Pagination row: yellow background
  fill(paginationY, colors.yellow)
  if totalPages > 1 then
    local pageText = state.page .. " / " .. totalPages
    at(L, paginationY, pageText, colors.black, colors.yellow)
    local btnX = L + #pageText + 1
    mkBtn(btnX, paginationY, "^", colors.black, colors.orange, function()
      if state.page > 1 then
        state.page = state.page - 1
      end
    end)
    mkBtn(btnX + 5, paginationY, "v", colors.black, colors.orange, function()
      if state.page < totalPages then
        state.page = state.page + 1
      end
    end)
  end
end

-- ── +RECIPE tab ─────────────────────────────────────────────

-- Draw word-wrapped machine selector buttons.
-- selected: currently selected machine name (or nil)
-- onSelect: callback(name) called when a button is tapped
-- Returns the last y used.
local function drawMachineList(startY, selected, onSelect)
  if #state.availableMachines == 0 then
    at(L, startY, "No machines found", colors.gray, colors.black)
    return startY
  end

  local x = L
  local y = startY
  for _, name in ipairs(state.availableMachines) do
    local btnW = #name + 2
    if x > L and x + btnW - 1 > W then
      y = y + 1
      x = L
    end
    mkBtn(
      x,
      y,
      name,
      colors.black,
      name == selected and colors.cyan or colors.gray,
      function()
        onSelect(name)
      end
    )
    x = x + btnW + 1
  end
  return y
end

local function drawNewRecipe()
  for y = BODY_ROW, H do
    fill(y, colors.black)
  end
  fill(BODY_ROW, colors.gray)
  at(L, BODY_ROW, "Add / Edit Recipe", colors.white, colors.gray)

  local cur = BODY_ROW + 2

  -- ── Craft type selector ──────────────────────────────────────
  at(L, cur, "Craft type:", colors.lightGray, colors.black)
  local xType = L + #"Craft type: "
  mkBtn(
    xType,
    cur,
    "Crafter",
    colors.black,
    state.type == "crafter" and colors.green or colors.gray,
    function()
      state.type = "crafter"
      state.selectedItemIdx = nil
    end
  )
  mkBtn(
    xType + #" Crafter " + 1,
    cur,
    "Machine",
    colors.black,
    state.type == "machine" and colors.green or colors.gray,
    function()
      if state.type ~= "machine" then
        state.type = "machine"
        state.resultPickerOpen = false
        reloadMachineItems()
      end
    end
  )
  cur = cur + 2 -- craft type row + empty gap

  -- ── Middle section (differs by type) ────────────────────────
  if state.type == "machine" then
    -- Items in interface
    fill(cur, colors.gray)
    at(
      L,
      cur,
      "Items in " .. Config.NEW_RECIPE_INTERFACE_NAME .. ":",
      colors.white,
      colors.gray
    )
    cur = cur + 1

    if #state.machineItems == 0 then
      at(
        L,
        cur,
        Config.NEW_RECIPE_INTERFACE_NAME .. " is empty",
        colors.gray,
        colors.black
      )
      cur = cur + 1
    else
      for i, item in ipairs(state.machineItems) do
        local isSelected = state.selectedItemIdx == i
        local captI = i

        -- Item row: "  name" or "  name > machine"
        local lineText
        if item.processor then
          lineText = "  " .. item.name .. " > " .. item.processor
        else
          lineText = "  " .. item.name
        end
        local padded = truncate(lineText, W - L)
        padded = padded .. string.rep(" ", math.max(0, W - L - #padded))
        mkBtnTight(L, cur, padded, colors.lightGray, colors.black, function()
          state.selectedItemIdx = (state.selectedItemIdx == captI) and nil
            or captI
        end)
        cur = cur + 1

        -- Inline machine picker (appears below item row when selected)
        if isSelected then
          local x = L + 2
          for _, mname in ipairs(state.availableMachines) do
            local btnW = #mname + 2
            if x > L + 2 and x + btnW - 1 > W then
              cur = cur + 1
              x = L + 2
            end
            local captM = mname
            mkBtn(x, cur, mname, colors.black, colors.gray, function()
              state.machineItems[captI].processor = captM
              state.selectedItemIdx = nil
            end)
            x = x + btnW + 1
          end
          cur = cur + 1
        end
      end
    end

    -- Result machine selector
    cur = cur + 1
    at(L, cur, "Result from:", colors.lightGray, colors.black)
    if state.resultProcessor and not state.resultPickerOpen then
      -- Collapsed: show selected machine on the same line as label
      local xLabel = L + #"Result from: "
      mkBtn(
        xLabel,
        cur,
        state.resultProcessor,
        colors.black,
        colors.cyan,
        function()
          state.resultPickerOpen = true
        end
      )
      cur = cur + 2
    else
      -- Expanded: machine list on next line(s)
      cur = cur + 1
      cur = drawMachineList(cur, state.resultProcessor, function(name)
        state.resultProcessor = name
        state.resultPickerOpen = false
      end)
      cur = cur + 2
    end
  else
    -- Crafter: hint text
    if state.editTarget then
      at(
        L,
        cur,
        "Editing: " .. truncate(state.editTarget, W - L - 9),
        colors.yellow,
        colors.black
      )
    else
      at(
        L,
        cur,
        "Place items in the recipe interface.",
        colors.lightGray,
        colors.black
      )
    end
    cur = cur + 2 -- hint + empty gap
  end

  -- ── Action buttons ───────────────────────────────────────────
  local testLabel = "Test Craft"
  mkBtn(L, cur, testLabel, colors.black, colors.lightBlue, function()
    if state.type == "machine" then
      if #state.machineItems == 0 then
        state.msg = "Barrel is empty"
        state.msgIsErr = true
        return
      end
      for _, item in ipairs(state.machineItems) do
        if not item.processor then
          state.msg = "Assign machine to all items"
          state.msgIsErr = true
          return
        end
      end
      if not state.resultProcessor then
        state.msg = "Select result machine"
        state.msgIsErr = true
        return
      end
    end
    state.msg = "Crafting test item..."
    state.msgIsErr = false
    state.pendingRecipe = nil
    pendingTask = function()
      local recipeItems, craftedItem
      if state.type == "machine" then
        local ok, result = pcall(
          Crafting.craftNewMachineRecipe,
          state.machineItems,
          state.resultProcessor
        )
        if not ok then
          state.msg = tostring(result)
          state.msgIsErr = true
          return
        end
        recipeItems, craftedItem = state.machineItems, result
      else
        local ok, a, b = pcall(Crafting.craftNewRecipe)
        if not ok then
          state.msg = tostring(a)
          state.msgIsErr = true
          return
        end
        recipeItems, craftedItem = a, b
      end
      local name = craftedItem.name
      local exists = pcall(Recipes.getRecipe, name)
      state.pendingRecipe = {
        items = recipeItems,
        craftedItem = craftedItem,
        name = name,
        alreadyExists = exists,
      }
      state.msg = nil
      reloadRecipes()
    end
  end)

  local clearX = L + #testLabel + 3
  mkBtn(clearX, cur, "Clear", colors.white, colors.red, function()
    state.msg = nil
    state.msgIsErr = false
    state.pendingRecipe = nil
    pendingTask = function()
      local ok, err
      if state.type == "machine" then
        ok, err = pcall(Crafting.clearRecipeInterface)
        if ok then
          reloadMachineItems()
        end
      else
        ok, err = pcall(function()
          Crafting.clearCrafter()
          Crafting.clearRecipeInterface()
        end)
      end
      if not ok then
        state.msg = tostring(err)
        state.msgIsErr = true
      end
    end
  end)

  if state.editTarget then
    mkBtn(
      clearX + #" Clear " + 1,
      cur,
      "Save",
      colors.white,
      colors.gray,
      function()
        if state.type == "machine" then
          if not state.resultProcessor then
            state.msg = "Select result machine"
            state.msgIsErr = true
            return
          end
          local itemProcessors = {}
          for _, item in ipairs(state.machineItems) do
            itemProcessors[item.name] = item.processor
          end
          local ok, err = pcall(
            Recipes.updateRecipeProcessor,
            state.editTarget,
            state.type,
            nil,
            state.resultProcessor,
            itemProcessors
          )
          if ok then
            state.msg = "Saved: " .. state.editTarget
            state.msgIsErr = false
          else
            state.msg = tostring(err)
            state.msgIsErr = true
          end
        else
          local ok, err = pcall(
            Recipes.updateRecipeProcessor,
            state.editTarget,
            state.type,
            Config.CRAFTER_NAME,
            nil,
            nil
          )
          if ok then
            state.msg = "Saved: " .. state.editTarget
            state.msgIsErr = false
          else
            state.msg = tostring(err)
            state.msgIsErr = true
          end
        end
      end
    )
  end

  local hasResult = state.msg ~= nil or state.pendingRecipe ~= nil
  if not hasResult then
    return
  end

  -- ── Result section ───────────────────────────────────────────
  local resultY = cur + 2
  fill(resultY, colors.gray)
  at(L, resultY, "Result:", colors.white, colors.gray)

  if state.msg ~= nil then
    local fg = state.msgIsErr and colors.red or colors.yellow
    at(L + 2, resultY + 1, truncate(state.msg, W - L - 2), fg, colors.black)
    return
  end

  local pr = state.pendingRecipe
  local resultText = pr.name .. " x" .. pr.craftedItem.count
  at(
    L + 2,
    resultY + 1,
    truncate(resultText, W - L - 2),
    colors.lime,
    colors.black
  )

  if pr.alreadyExists then
    at(L, resultY + 3, "Recipe exists. Overwrite?", colors.yellow, colors.black)
  else
    at(L, resultY + 3, "Save this recipe?", colors.white, colors.black)
  end

  local saveY = resultY + 4
  mkBtn(L, saveY, "Save", colors.black, colors.yellow, function()
    if state.type == "machine" then
      for _, item in ipairs(pr.items) do
        if not item.processor then
          state.msg = "Assign machine to all items"
          state.msgIsErr = true
          return
        end
      end
      if not state.resultProcessor then
        state.msg = "Select result machine"
        state.msgIsErr = true
        return
      end
    end
    local processor = state.type ~= "machine" and Config.CRAFTER_NAME or nil
    local ok, err = pcall(
      Recipes.saveRecipe,
      pr.items,
      pr.craftedItem,
      state.type,
      processor,
      state.resultProcessor
    )
    if ok then
      state.pendingRecipe = nil
      state.editTarget = nil
      state.msg = nil
      reloadRecipes()
    else
      state.msg = tostring(err)
      state.msgIsErr = true
      state.pendingRecipe = nil
    end
  end)
  mkBtn(L + #"Save" + 3, saveY, "Cancel", colors.white, colors.gray, function()
    state.pendingRecipe = nil
    state.editTarget = nil
    state.msg = nil
  end)
end

-- ── Stock tab ───────────────────────────────────────────────

local function drawStockList()
  local headerY = BODY_ROW
  local listStart = BODY_ROW + 1
  local paginationY = H
  local listH = paginationY - listStart

  for y = headerY, H do
    fill(y, colors.black)
  end

  -- Dynamic name width; count zone = 8 chars ("x999999" + 1 gap)
  local maxNameLen = 0
  for _, item in ipairs(state.stockItems) do
    if #item.name > maxNameLen then
      maxNameLen = #item.name
    end
  end
  local itemW = math.max(0, math.min(maxNameLen, W - L - 9))
  local xCount = L + itemW + 1

  fill(headerY, colors.gray)
  at(xCount - #"ITEM" - 1, headerY, "ITEM", colors.lightGray, colors.gray)
  at(xCount, headerY, "COUNT", colors.lightGray, colors.gray)

  local total = #state.stockItems
  local totalPages = math.max(1, math.ceil(total / listH))
  state.stockPage = math.min(state.stockPage, totalPages)

  local startIdx = (state.stockPage - 1) * listH + 1
  local endIdx = math.min(startIdx + listH - 1, total)

  if total == 0 then
    at(L, listStart + 1, "Stock is empty", colors.gray, colors.black)
  else
    for i = startIdx, endIdx do
      local item = state.stockItems[i]
      local row = listStart + (i - startIdx)
      local name = truncate(item.name, itemW)
      at(
        math.max(L, xCount - #name - 1),
        row,
        name,
        colors.lightGray,
        colors.black
      )
      at(xCount, row, "x" .. item.count, colors.yellow, colors.black)
    end
  end

  fill(paginationY, colors.yellow)
  if totalPages > 1 then
    local pageText = state.stockPage .. " / " .. totalPages
    at(L, paginationY, pageText, colors.black, colors.yellow)
    local btnX = L + #pageText + 1
    mkBtn(btnX, paginationY, "^", colors.black, colors.orange, function()
      if state.stockPage > 1 then
        state.stockPage = state.stockPage - 1
      end
    end)
    mkBtn(btnX + 5, paginationY, "v", colors.black, colors.orange, function()
      if state.stockPage < totalPages then
        state.stockPage = state.stockPage + 1
      end
    end)
  end
end

-- ── Full redraw ─────────────────────────────────────────────

local function drawScreen()
  buttons = {}
  mon.setBackgroundColor(colors.black)
  mon.clear()
  drawHeader()
  drawSeparator()
  drawTabs()
  if state.tab == "recipes" then
    drawRecipesList()
  elseif state.tab == "stock" then
    drawStockList()
  else
    drawNewRecipe()
  end
end

reloadRecipes = function()
  local all = Recipes.getAllRecipes()
  local list = {}
  for _, recipe in pairs(all) do
    table.insert(list, { name = recipe.name, count = recipe.count })
  end
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  state.recipes = list
end

reloadStock = function()
  local totals = Stock.getTotals()
  local list = {}
  for name, count in pairs(totals) do
    table.insert(list, { name = name, count = count })
  end
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  state.stockItems = list
end

reloadMachines = function()
  local known = {
    [Config.STOCK_NAME] = true,
    [Config.CRAFTER_NAME] = true,
    [Config.MONITOR_NAME] = true,
    [Config.NEW_RECIPE_INTERFACE_NAME] = true,
  }
  local machines = {}
  for _, name in ipairs(peripheral.getNames()) do
    if
      not known[name]
      and name:find(":", 1, true)
      and peripheral.hasType(name, "inventory")
    then
      table.insert(machines, name)
    end
  end
  table.sort(machines)
  state.availableMachines = machines
end

reloadMachineItems = function()
  -- Preserve existing processor assignments across rescans
  local existing = {}
  for _, item in ipairs(state.machineItems) do
    if item.processor then
      existing[item.name] = item.processor
    end
  end

  local ok, items = pcall(Crafting.getInterfaceItems)
  if not ok then
    state.machineItems = {}
    return
  end

  state.machineItems = {}
  state.selectedItemIdx = nil
  state.resultPickerOpen = false
  for _, item in ipairs(items) do
    table.insert(state.machineItems, {
      name = item.name,
      count = item.count,
      slot = item.slot,
      processor = existing[item.name],
    })
  end
end

-- ── Entry ───────────────────────────────────────────────────

function UI.run(monitorName)
  mon = peripheral.wrap(monitorName)
  if not mon then
    error("Monitor '" .. monitorName .. "' not found")
  end

  mon.setTextScale(Config.MONITOR_TEXT_SCALE)
  W, H = mon.getSize()

  Network.prepareModem("bottom", false)
  reloadRecipes()
  reloadMachines()
  reloadMachineItems()
  drawScreen()

  while true do
    local _, side, x, y = os.pullEvent("monitor_touch")
    if side == monitorName then
      for _, btn in ipairs(buttons) do
        if y == btn.y and x >= btn.x1 and x <= btn.x2 then
          btn.fn()
          drawScreen()
          if pendingTask then
            local task = pendingTask
            pendingTask = nil
            task()
            drawScreen()
          end
          break
        end
      end
    end
  end
end

return UI

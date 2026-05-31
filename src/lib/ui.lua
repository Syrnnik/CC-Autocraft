local Config = require("lib.config")
local Crafting = require("lib.crafting")
local Labels = require("lib.labels")
local Roles  = require("lib.roles")
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
  mods = {}, -- sorted list of mod prefixes found in recipes
  modTab = "all", -- currently selected mod filter ("all" or mod name)
  modTabOffset = 0, -- scroll offset for mod tabs (index of first visible tab - 1)
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
  -- search state
  searchQuery = "",
  searchMode = false,
  -- setup tab state
  setupPickerRole  = nil,
  setupCustomMode  = false,
  setupCustomInput = "",
  -- labels tab state
  labelsPage = 1,
  labelItems = {}, -- { name (peripheral), label }
  labelEditTarget = nil,
  labelInput = "",
  labelInputMode = false,
  -- new_recipe tab state
  msg = nil,
  msgIsErr = false,
  pendingRecipe = nil,
  -- craft screen state
  craftItem = nil, -- full item name being crafted
  craftCount = 1,
  craftMsg = nil,
  craftMsgIsErr = false,
  craftMsgIsDone = false,
  craftProgress = 0, -- 0-100
  craftPlanning = false, -- true while plan is being built
  craftPlan = nil, -- list of { name, craftsCount, recipe } for display
}

local L = 2 -- left margin
local TABS_ROW = 1
local BODY_ROW = TABS_ROW + 1 -- 2  (first content row)

-- ── Mod helpers ────────────────────────────────────────────

local function getMod(name)
  return name:match("^([^:]+):") or "other"
end

local function stripMod(name)
  return name:match("^[^:]+:(.+)") or name
end

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

-- ── Shared item table ───────────────────────────────────────
-- Draws a paginated two-column table (ITEM | COUNT) with alternating rows.
-- opts fields:
--   topY          : first row (header)
--   items         : list of { name, count } (count unused if countText provided)
--   page          : current page number
--   setPage       : function(p) — updates page state
--   displayName   : function(name) -> display string (default: identity)
--   rightW        : chars reserved right of the name (gap + count + any buttons)
--   emptyMsg      : shown when items is empty
--   drawActions   : optional function(item, row, rowBg, xCount)
--   headerName    : left column header text (default "ITEM")
--   headerCount   : right column header text (default "COUNT")
--   countText     : optional function(item) -> string, overrides "x"..count display
--   countColor    : optional function(item) -> color, overrides colors.yellow
--   alwaysShowPage: always render "N / M" even when only 1 page
local function drawTable(opts)
  local headerY  = opts.topY
  local listStart = opts.topY + 1
  local paginationY = H
  local listH = paginationY - listStart
  local items = opts.items
  local displayName = opts.displayName or function(n) return n end
  local rightW = opts.rightW or 9

  local hName  = opts.headerName  or "ITEM"
  local maxNameLen = #hName  -- minimum: header must always fit
  for _, item in ipairs(items) do
    local dn = displayName(item.name)
    if #dn > maxNameLen then maxNameLen = #dn end
  end
  local itemW = math.max(0, math.min(maxNameLen, W - L - rightW))
  local xCount = L + itemW + 1

  local hCount = opts.headerCount or "COUNT"
  fill(headerY, colors.gray)
  at(math.max(L, xCount - #hName - 1), headerY, hName,  colors.lightGray, colors.gray)
  at(xCount,                           headerY, hCount, colors.lightGray, colors.gray)

  local total = #items
  local totalPages = math.max(1, math.ceil(total / listH))
  local page = math.min(opts.page, totalPages)
  opts.setPage(page)

  local startIdx = (page - 1) * listH + 1
  local endIdx = math.min(startIdx + listH - 1, total)

  if total == 0 then
    at(L, listStart + 1, opts.emptyMsg or "No items", colors.gray, colors.black)
  else
    for i = startIdx, endIdx do
      local item = items[i]
      local row = listStart + (i - startIdx)
      local rowBg = (((i - startIdx) % 2) == 0) and colors.black or colors.gray

      fill(row, rowBg)

      local dn = truncate(displayName(item.name), itemW)
      at(math.max(L, xCount - #dn - 1), row, dn, colors.white, rowBg)
      local countStr   = opts.countText  and opts.countText(item)  or ("x" .. item.count)
      local countColor = opts.countColor and opts.countColor(item) or colors.yellow
      at(xCount, row, countStr, countColor, rowBg)

      if opts.drawActions then
        opts.drawActions(item, row, rowBg, xCount)
      end
    end
  end

  fill(paginationY, colors.yellow)

  -- Page nav + Search button (left side, together)
  local afterNav = L
  if totalPages > 1 or opts.alwaysShowPage then
    local pageText = page .. " / " .. totalPages
    at(L, paginationY, pageText, colors.black, colors.yellow)
    local btnX = L + #pageText + 1
    if totalPages > 1 then
      mkBtn(btnX, paginationY, "^", colors.black, colors.orange, function()
        if page > 1 then opts.setPage(page - 1) end
      end)
      mkBtn(btnX + 5, paginationY, "v", colors.black, colors.orange, function()
        if page < totalPages then opts.setPage(page + 1) end
      end)
      afterNav = btnX + 10
    else
      afterNav = btnX
    end
  end

  local searchBtnW
  if state.searchMode then
    mkBtn(afterNav, paginationY, "x", colors.white, colors.red, function()
      state.searchQuery = ""
      state.searchMode = false
      state.page = 1
      state.stockPage = 1
    end)
    searchBtnW = #(" x ")
  else
    mkBtn(afterNav, paginationY, "Search", colors.black, colors.orange, function()
      state.searchMode = true
    end)
    searchBtnW = #(" Search ")
  end

  -- Query display (after Search/x button)
  if state.searchQuery ~= "" or state.searchMode then
    local queryStart = afterNav + searchBtnW + 1
    local display = state.searchQuery .. (state.searchMode and "_" or "")
    if queryStart <= W then
      at(queryStart, paginationY, truncate(display, W - queryStart + 1),
         colors.black, colors.yellow)
    end
  end
end

local reloadRecipes
local reloadStock
local reloadMachines
local reloadMachineItems
local reloadLabels

-- ── Sections ───────────────────────────────────────────────

local function drawTabs()
  fill(TABS_ROW, colors.black)
  local x = L

  local tabs = {
    { id = "recipes",    label = " RECIPES " },
    { id = "stock",      label = " STOCK " },
    { id = "new_recipe", label = " +RECIPE " },
    { id = "labels",     label = " LABELS " },
    { id = "setup",      label = " SETUP " },
  }

  for _, tab in ipairs(tabs) do
    local active = state.tab == tab.id
      or (tab.id == "recipes" and state.tab == "craft")
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
        state.searchQuery = ""
        state.searchMode = false
        state.labelInputMode = false
        state.setupPickerRole  = nil
        state.setupCustomMode  = false
        if tab.id == "setup" then
          state.tab = "setup"
          reloadLabels()
        elseif tab.id == "labels" then
          state.tab = "labels"
          state.labelsPage = 1
          reloadLabels()
        elseif tab.id == "recipes" then
          state.tab = "recipes"
          state.page = 1
          state.deleteTarget = nil
          state.editTarget = nil
          state.craftItem = nil
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
  local modTabsY = BODY_ROW
  local headerY  = BODY_ROW + 1
  local listStart = BODY_ROW + 2
  local paginationY = H
  local listH = paginationY - listStart

  for y = modTabsY, H do
    fill(y, colors.black)
  end

  -- Mod sub-tabs row.
  -- "All" is always pinned at the left. Scroll buttons < > control which
  -- mod-specific tabs are visible; they scroll freely regardless of active tab.
  do
    -- Draw fixed "All" tab
    local allActive = state.modTab == "all"
    at(L, modTabsY, "All",
       allActive and colors.black or colors.gray,
       allActive and colors.yellow or colors.black)
    table.insert(buttons, {
      x1 = L, x2 = L + 2, y = modTabsY,
      fn = function()
        state.modTab = "all"
        state.modTabOffset = 0
        state.page = 1
      end,
    })

    if #state.mods > 0 then
      -- Layout: "All" ends at L+2. Gap at L+3.
      -- Scroll buttons (when needed): "<" at L+4, gap, mods from L+6 to W-2, gap, ">" at W.
      -- No scroll: mods from L+4 to W.
      local scrollL = L + 4  -- x of "<" button
      local modsNoScroll = L + 4  -- mods start when no scroll
      local modsWithScroll = L + 6  -- mods start when scroll present (after "< ")

      -- Compute total mods width
      local totalModW = 0
      for i, mod in ipairs(state.mods) do
        totalModW = totalModW + #mod + (i > 1 and 1 or 0)
      end

      local spaceNoScroll = W - modsNoScroll + 1
      local needsScroll = totalModW > spaceNoScroll
      local modsStart = needsScroll and modsWithScroll or modsNoScroll
      local modsEnd = needsScroll and (W - 2) or W
      local spaceForMods = modsEnd - modsStart + 1

      -- Clamp offset so we never scroll past the last mod
      state.modTabOffset = math.max(0, state.modTabOffset)

      -- Find last visible mod index from current offset
      local function calcLastVisible(offset)
        local used = 0
        local last = offset
        for i = offset + 1, #state.mods do
          local w = #state.mods[i] + (used > 0 and 1 or 0)
          if used + w > spaceForMods then break end
          used = used + w
          last = i
        end
        return last
      end

      local lastVisibleIdx = calcLastVisible(state.modTabOffset)
      -- If nothing visible, clamp offset back
      if lastVisibleIdx == state.modTabOffset and state.modTabOffset > 0 then
        state.modTabOffset = math.max(0, state.modTabOffset - 1)
        lastVisibleIdx = calcLastVisible(state.modTabOffset)
      end

      -- Page-based scroll: < goes to the previous full page of mods, > to the next.
      -- ">" sets offset = lastVisibleIdx (first mod of next page).
      -- "<" finds the largest page-start offset O < current such that calcLastVisible(O) == current offset.
      local function prevPageOffset()
        local prevO = 0
        local o = 0
        while true do
          local lv = calcLastVisible(o)
          local nextO = lv
          if nextO >= state.modTabOffset then break end
          prevO = o
          o = nextO
        end
        return prevO
      end

      if needsScroll then
        local canLeft = state.modTabOffset > 0
        at(scrollL, modTabsY, "<",
           canLeft and colors.white or colors.gray, colors.black)
        if canLeft then
          table.insert(buttons, {
            x1 = scrollL, x2 = scrollL, y = modTabsY,
            fn = function() state.modTabOffset = prevPageOffset() end,
          })
        end
      end

      -- Draw visible mod tabs
      local x = modsStart
      for i = state.modTabOffset + 1, lastVisibleIdx do
        local mod = state.mods[i]
        local active = state.modTab == mod
        at(x, modTabsY, mod,
           active and colors.black or colors.gray,
           active and colors.yellow or colors.black)
        local x1, x2 = x, x + #mod - 1
        local captId = mod
        table.insert(buttons, {
          x1 = x1, x2 = x2, y = modTabsY,
          fn = function()
            state.modTab = captId
            state.page = 1
          end,
        })
        x = x + #mod + 1
      end

      if needsScroll then
        local canRight = lastVisibleIdx < #state.mods
        at(W, modTabsY, ">",
           canRight and colors.white or colors.gray, colors.black)
        if canRight then
          table.insert(buttons, {
            x1 = W, x2 = W, y = modTabsY,
            -- Jump to next page: first mod after current last visible
            fn = function() state.modTabOffset = lastVisibleIdx end,
          })
        end
      end
    end
  end

  -- Build filtered list
  local sq = state.searchQuery:lower()
  local filtered = {}
  for _, r in ipairs(state.recipes) do
    if state.modTab == "all" or getMod(r.name) == state.modTab then
      if sq == "" or stripMod(r.name):lower():find(sq, 1, true) then
        table.insert(filtered, r)
      end
    end
  end

  -- Right zone: 1 gap + 6 count + 8 Craft + 7 Edit + 5 Del = 27
  drawTable({
    topY        = headerY,
    items       = filtered,
    page        = state.page,
    setPage     = function(p) state.page = p end,
    displayName = stripMod,
    rightW      = 27,
    emptyMsg    = "No recipes yet",
    drawActions = function(item, row, rowBg, xCount)
      local xCraft = xCount + 6
      local xEdit  = xCraft + 8
      local xDel   = xEdit + 7
      local captured = item.name
      if captured == state.deleteTarget then
        mkBtn(xCraft, row, "Delete", colors.white, colors.red, function()
          pcall(Recipes.deleteRecipe, captured)
          state.deleteTarget = nil
          reloadRecipes()
        end)
        mkBtn(xCraft + 10, row, "Cancel", colors.white, colors.gray, function()
          state.deleteTarget = nil
        end)
      else
        mkBtn(xCraft, row, "Craft", colors.black, colors.yellow, function()
          state.craftItem = captured
          state.craftCount = 1
          state.craftMsg = nil
          state.craftMsgIsErr = false
          state.craftMsgIsDone = false
          state.craftProgress = 0
          state.craftPlanning = false
          state.craftPlan = nil
          state.tab = "craft"
        end)
        mkBtn(xEdit, row, "Edit", colors.lightGray, colors.gray, function()
          state.tab        = "new_recipe"
          state.editTarget = captured
          state.pendingRecipe = nil
          state.msg        = nil
          reloadMachines()
          local ok, recipe = pcall(Recipes.getRecipe, captured)
          if ok then
            state.type            = recipe.type or "crafter"
            state.resultProcessor = recipe.resultProcessor
            state.resultPickerOpen = false
            state.selectedItemIdx  = nil
            if state.type == "machine" then
              state.machineItems = {}
              for _, item in ipairs(recipe.items) do
                table.insert(state.machineItems, {
                  name      = item.name,
                  count     = item.count,
                  slot      = item.slot,
                  processor = item.processor,
                })
              end
            end
          end
        end)
        mkBtn(xDel, row, "Del", colors.black, colors.red, function()
          state.deleteTarget = captured
        end)
      end
    end,
  })
end

-- ── +RECIPE tab ─────────────────────────────────────────────

-- Returns the display name for a machine peripheral: label if set, else stripped name.
local function machineLabel(name)
  if not name then return "?" end
  return Labels.get(name) or stripMod(name)
end

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
    local lbl  = machineLabel(name)
    local btnW = #lbl + 2
    if x > L and x + btnW - 1 > W then
      y = y + 1
      x = L
    end
    mkBtn(
      x,
      y,
      lbl,
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
      "Items in " .. Roles.get("recipe_interface") .. ":",
      colors.white,
      colors.gray
    )
    cur = cur + 1

    if #state.machineItems == 0 then
      at(
        L,
        cur,
        Roles.get("recipe_interface") .. " is empty",
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
          lineText = "  " .. item.name .. " > " .. machineLabel(item.processor)
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
            local lbl  = machineLabel(mname)
            local btnW = #lbl + 2
            if x > L + 2 and x + btnW - 1 > W then
              cur = cur + 1
              x = L + 2
            end
            local captM = mname
            mkBtn(x, cur, lbl, colors.black, colors.gray, function()
              state.machineItems[captI].processor = captM
              state.selectedItemIdx = nil
            end)
            x = x + btnW + 1
          end
          cur = cur + 1
        end
      end
    end

    -- Reset button (editing only): re-read items from the interface barrel
    if state.editTarget then
      mkBtn(L, cur, "Reset", colors.white, colors.gray, function()
        reloadMachineItems()
      end)
      cur = cur + 2
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
        machineLabel(state.resultProcessor),
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
      local prefix = "Place items in "
      local portLabel = Labels.get(Roles.get("recipe_interface"))
                     or stripMod(Roles.get("recipe_interface") or "?")
      at(L,            cur, prefix,    colors.lightGray, colors.black)
      at(L + #prefix,  cur, portLabel, colors.yellow,    colors.black)
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
            Roles.get("crafter"),
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
    local processor = state.type ~= "machine" and Roles.get("crafter") or nil
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

-- ── Craft screen ────────────────────────────────────────────

local function drawCraftScreen()
  for y = BODY_ROW, H do
    fill(y, colors.black)
  end

  -- Header row: item name only (user navigates back via RECIPES tab)
  fill(BODY_ROW, colors.gray)
  local itemLabel = state.craftItem or ""
  at(L, BODY_ROW, truncate(itemLabel, W - L), colors.white, colors.gray)

  local cur = BODY_ROW + 2

  -- Count selector: Amount: -100 -10 -1 [  N] +1 +10 +100  (no padding on buttons)
  at(L, cur, "Amount:", colors.lightGray, colors.black)
  local xb = L + 9
  local cnt = state.craftCount

  -- For +N: if count=1 and N>1, set to N instead of N+1 (so 1+10=10, not 11).
  -- For +1: always just add 1.
  local function addCount(delta)
    if delta > 1 and state.craftCount == 1 then
      state.craftCount = delta
    else
      state.craftCount = math.max(1, state.craftCount + delta)
    end
  end

  mkBtnTight(xb,      cur, "-100", colors.lightGray, colors.gray, function() addCount(-100) end)
  mkBtnTight(xb + 5,  cur, "-10",  colors.lightGray, colors.gray, function() addCount(-10)  end)
  mkBtnTight(xb + 9,  cur, "-1",   colors.lightGray, colors.gray, function() addCount(-1)   end)
  at(xb + 12, cur, string.format("%4d", cnt), colors.black, colors.yellow)
  mkBtnTight(xb + 17, cur, "+1",   colors.lightGray, colors.gray, function() addCount(1)    end)
  mkBtnTight(xb + 20, cur, "+10",  colors.lightGray, colors.gray, function() addCount(10)   end)
  mkBtnTight(xb + 24, cur, "+100", colors.lightGray, colors.gray, function() addCount(100)  end)

  cur = cur + 2

  local notStarted = not state.craftPlanning and state.craftPlan == nil

  if notStarted then
    -- No craft in progress: Craft button + Done/error message below
    mkBtn(L, cur, "Craft", colors.black, colors.cyan, function()
      local name = state.craftItem
      local count = state.craftCount
      state.craftMsg = nil
      state.craftMsgIsErr = false
      state.craftMsgIsDone = false
      state.craftProgress = 0
      state.craftPlanning = true
      state.craftPlan = nil
      pendingTask = function(redraw)
        local ok, err = pcall(Crafting.craftItem, name, count,
          function(i, total)
            state.craftProgress = math.floor(i / total * 100)
            if redraw then redraw() end
          end,
          function(plan)
            -- Shallow copy: onStepDone removes from state.craftPlan,
            -- but craftItem iterates the original plan table. Keeping
            -- them as the same reference would corrupt the loop.
            local copy = {}
            for i, v in ipairs(plan) do copy[i] = v end
            state.craftPlan = copy
            state.craftPlanning = false
            if redraw then redraw() end
          end,
          function()
            if state.craftPlan and #state.craftPlan > 0 then
              table.remove(state.craftPlan, 1)
            end
            if redraw then redraw() end
          end
        )
        if ok then
          state.craftPlan = nil
          state.craftMsgIsDone = true
          state.craftMsg = "Done! " .. stripMod(name) .. " x" .. count
          state.craftProgress = 100
        else
          state.craftMsg = tostring(err)
          state.craftMsgIsErr = true
          state.craftMsgIsDone = false
          state.craftPlanning = false
          state.craftPlan = nil
          state.craftProgress = 0
        end
        reloadRecipes()
      end
    end)

    if state.craftMsgIsDone and state.craftMsg then
      at(L, cur + 2, truncate(state.craftMsg, W - L), colors.green, colors.black)
    elseif state.craftMsgIsErr and state.craftMsg then
      local lines = {}
      for line in (state.craftMsg .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
      end
      for i, line in ipairs(lines) do
        local row = cur + 1 + i
        if row > H - 3 then break end
        at(L, row, truncate(line, W - L), colors.red, colors.black)
      end
    end
  else
    -- Craft started: header + content
    fill(cur, colors.gray)
    at(L, cur, "Planned crafts", colors.white, colors.gray)

    local planStart = cur + 1
    local planEnd = H - 3

    if state.craftMsgIsErr and state.craftMsg then
      local lines = {}
      for line in (state.craftMsg .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
      end
      for i, line in ipairs(lines) do
        local row = planStart + i - 1
        if row > planEnd then break end
        at(L, row, truncate(line, W - L), colors.red, colors.black)
      end
    elseif state.craftPlanning then
      at(L, planStart, "Planning...", colors.yellow, colors.black)
    elseif state.craftPlan then
      for i, step in ipairs(state.craftPlan) do
        local row = planStart + i - 1
        if row > planEnd then break end
        local label = "- " .. stripMod(step.name) .. " x" .. (step.craftsCount * step.recipe.count)
        at(L, row, truncate(label, W - L), colors.lightGray, colors.black)
      end
    end
  end

  -- Progress header
  at(L, H - 2, "Progress", colors.gray, colors.black)

  -- Progress bar: pct%[====----]
  local barRow = H - 1
  local pct = string.format("%3d%%", state.craftProgress)
  local barX = L + #pct      -- [ sits right after percent text
  local inner = W - barX - 2 -- bar width; ] lands at W-1 (1 char right margin)
  local filled = math.floor(state.craftProgress / 100 * inner)
  at(L,                 barRow, pct,                              colors.orange, colors.black)
  at(barX,              barRow, "[",                              colors.gray,   colors.black)
  at(barX + 1,          barRow, string.rep("=", filled),          colors.lime,   colors.black)
  at(barX + 1 + filled, barRow, string.rep("-", inner - filled),  colors.gray,   colors.black)
  at(barX + 1 + inner,  barRow, "]",                              colors.gray,   colors.black)
end

-- ── Stock tab ───────────────────────────────────────────────

local function drawStockList()
  for y = BODY_ROW, H do
    fill(y, colors.black)
  end

  local items = state.stockItems
  if state.searchQuery ~= "" then
    local sq = state.searchQuery:lower()
    local filtered = {}
    for _, item in ipairs(items) do
      if stripMod(item.name):lower():find(sq, 1, true) then
        table.insert(filtered, item)
      end
    end
    items = filtered
  end

  drawTable({
    topY        = BODY_ROW,
    items       = items,
    page        = state.stockPage,
    setPage     = function(p) state.stockPage = p end,
    displayName = stripMod,
    rightW      = 9,
    emptyMsg    = "Stock is empty",
  })
end

-- ── Labels tab ──────────────────────────────────────────────

local function drawLabels()
  for y = BODY_ROW, H do fill(y, colors.black) end

  -- rightW=26 layout from xCount:
  --   normal:  [Edit](6) gap(1) label(19)              = 26
  --   editing: [v](3) gap(1) [x](3) gap(1) input(18)  = 26
  drawTable({
    topY           = BODY_ROW,
    items          = state.labelItems,
    page           = state.labelsPage,
    setPage        = function(p) state.labelsPage = p end,
    displayName    = stripMod,
    rightW         = 26,
    emptyMsg       = "No peripherals found",
    headerName     = "Peripheral",
    headerCount    = "Label",
    alwaysShowPage = true,
    countText  = function(_) return "" end,
    countColor = function(_) return colors.black end,
    drawActions = function(item, row, rowBg, xCount)
      local editing   = state.labelInputMode and state.labelEditTarget == item.name
      local captName  = item.name
      local captLabel = item.label
      if editing then
        mkBtn(xCount,     row, "v", colors.black, colors.green, function()
          if state.labelInput ~= "" then
            pcall(Labels.set, state.labelEditTarget, state.labelInput)
          else
            pcall(Labels.delete, state.labelEditTarget)
          end
          state.labelInputMode  = false
          state.labelEditTarget = nil
          reloadLabels()
        end)
        mkBtn(xCount + 4, row, "x", colors.black, colors.red, function()
          state.labelInputMode  = false
          state.labelEditTarget = nil
        end)
        local inputX = xCount + 8
        at(inputX, row, truncate(state.labelInput .. "_", W - inputX),
           colors.yellow, rowBg)
      else
        mkBtn(xCount, row, "Edit", colors.lightGray, colors.gray, function()
          state.labelEditTarget = captName
          state.labelInput      = captLabel
          state.labelInputMode  = true
        end)
        local labelX = xCount + 7
        if item.label ~= "" then
          at(labelX, row, truncate(item.label, W - labelX - 1), colors.yellow, rowBg)
        else
          at(labelX, row, "-", colors.lightGray, rowBg)
        end
      end
    end,
  })
end

-- ── Setup tab ───────────────────────────────────────────────

local function drawSetup()
  for y = BODY_ROW, H do fill(y, colors.black) end

  fill(BODY_ROW, colors.gray)
  at(L, BODY_ROW, "System Roles", colors.white, colors.gray)

  local rolesData = Roles.getAll()
  -- Layout: role name (right-aligned) | [Set] | value
  -- Longest role name = "Recipe Iface" = 12 chars → xSet = L + 14
  local xSet   = L + 14
  local xValue = xSet + #" Set " + 1  -- value starts after [Set] button + gap

  local cur = BODY_ROW + 1

  for _, role in ipairs(Roles.LIST) do
    if cur > H - 1 then break end
    fill(cur, colors.black)

    -- Role display name (right-aligned before [Set])
    local disp = Roles.DISPLAY[role]
    at(math.max(L, xSet - #disp - 1), cur, disp, colors.lightGray, colors.black)

    -- Current assignment (after [Set])
    local explicit = rolesData[role]
    local valueStr, valueColor
    if explicit then
      local lbl = Labels.get(explicit)
      valueStr   = lbl and (lbl .. " (" .. stripMod(explicit) .. ")") or stripMod(explicit)
      valueColor = colors.yellow
    else
      valueStr   = "-"
      valueColor = colors.lightGray
    end
    at(xValue, cur, truncate(valueStr, W - xValue - 1), valueColor, colors.black)

    local captRole = role
    mkBtn(xSet, cur, "Set", colors.black, colors.yellow, function()
      state.setupPickerRole  = captRole
      state.setupCustomMode  = false
      state.setupCustomInput = ""
    end)

    cur = cur + 1

    -- Inline picker
    if state.setupPickerRole == role then
      if state.setupCustomMode then
        if cur <= H - 1 then
          fill(cur, colors.black)
          at(L + 2, cur, truncate(state.setupCustomInput .. "_", W - L - 4),
             colors.yellow, colors.black)
          cur = cur + 1
        end
      else
        -- Labeled peripherals + Custom + Clear in a wrapping row
        local RIGHT = W - 2
        local function nextRow()
          cur = cur + 1
          if cur <= H - 1 then fill(cur, colors.black) end
          return L + 2
        end
        local x = L + 2
        if cur <= H - 1 then fill(cur, colors.black) end

        for _, item in ipairs(state.labelItems) do
          if item.label ~= "" then
            local bw = #item.label + 2
            if x + bw - 1 > RIGHT then x = nextRow() end
            if cur > H - 1 then break end
            local captPerif = item.name
            mkBtn(x, cur, item.label, colors.black, colors.cyan, function()
              pcall(Roles.set, captRole, captPerif)
              state.setupPickerRole = nil
            end)
            x = x + bw + 1
          end
        end

        -- Custom button
        local cbw = #" Custom " + 1
        if x + cbw - 1 > RIGHT then x = nextRow() end
        if cur <= H - 1 then
          mkBtn(x, cur, "Custom", colors.black, colors.gray, function()
            state.setupCustomMode  = true
            state.setupCustomInput = ""
          end)
          x = x + cbw
        end

        -- Clear button (only if explicitly set)
        if explicit and cur <= H - 1 then
          local clbw = #" Clear " + 1
          if x + clbw - 1 > RIGHT then x = nextRow() end
          if cur <= H - 1 then
            mkBtn(x, cur, "Clear", colors.black, colors.red, function()
              pcall(Roles.clear, captRole)
              state.setupPickerRole = nil
            end)
          end
        end

        cur = cur + 1
      end
    end
  end
end

-- ── Full redraw ─────────────────────────────────────────────

local function drawScreen()
  buttons = {}
  mon.setBackgroundColor(colors.black)
  mon.clear()
  drawTabs()
  if state.tab == "recipes" then
    drawRecipesList()
  elseif state.tab == "craft" then
    drawCraftScreen()
  elseif state.tab == "stock" then
    drawStockList()
  elseif state.tab == "labels" then
    drawLabels()
  elseif state.tab == "setup" then
    drawSetup()
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
    return stripMod(a.name) < stripMod(b.name)
  end)
  state.recipes = list

  -- Recompute mod list
  local seen = {}
  local mods = {}
  for _, r in ipairs(list) do
    local mod = getMod(r.name)
    if not seen[mod] then
      seen[mod] = true
      table.insert(mods, mod)
    end
  end
  table.sort(mods)
  state.mods = mods

  -- Reset modTab if it no longer exists
  if state.modTab ~= "all" then
    local found = false
    for _, m in ipairs(mods) do
      if m == state.modTab then
        found = true
        break
      end
    end
    if not found then
      state.modTab = "all"
    end
  end
end

reloadStock = function()
  local totals = Stock.getTotals()
  local list = {}
  for name, count in pairs(totals) do
    table.insert(list, { name = name, count = count })
  end
  table.sort(list, function(a, b)
    return stripMod(a.name) < stripMod(b.name)
  end)
  state.stockItems = list
end

reloadMachines = function()
  local known = {}
  for _, role in ipairs(Roles.LIST) do
    local p = Roles.get(role)
    if p then known[p] = true end
  end
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

reloadLabels = function()
  local perifs = {}
  for _, name in ipairs(peripheral.getNames()) do
    table.insert(perifs, name)
  end
  table.sort(perifs, function(a, b) return stripMod(a) < stripMod(b) end)

  local data = Labels.getAll()
  local items = {}
  for _, name in ipairs(perifs) do
    table.insert(items, { name = name, label = data[name] or "" })
  end
  state.labelItems = items
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
  reloadLabels()
  drawScreen()

  while true do
    local ev = { os.pullEvent() }
    local evType = ev[1]

    if evType == "monitor_touch" and ev[2] == monitorName then
      local x, y = ev[3], ev[4]
      for _, btn in ipairs(buttons) do
        if y == btn.y and x >= btn.x1 and x <= btn.x2 then
          btn.fn()
          drawScreen()
          if pendingTask then
            local task = pendingTask
            pendingTask = nil
            task(drawScreen)
            drawScreen()
          end
          break
        end
      end
    elseif state.searchMode then
      if evType == "char" then
        state.searchQuery = state.searchQuery .. ev[2]
        state.page = 1
        state.stockPage = 1
        drawScreen()
      elseif evType == "key" then
        local key = ev[2]
        if key == keys.backspace then
          if #state.searchQuery > 0 then
            state.searchQuery = state.searchQuery:sub(1, -2)
          end
          state.page = 1
          state.stockPage = 1
          drawScreen()
        elseif key == keys.enter or key == keys.escape then
          state.searchMode = false
          drawScreen()
        end
      end
    elseif state.labelInputMode then
      if evType == "char" then
        state.labelInput = state.labelInput .. ev[2]
        drawScreen()
      elseif evType == "key" then
        local key = ev[2]
        if key == keys.backspace then
          if #state.labelInput > 0 then
            state.labelInput = state.labelInput:sub(1, -2)
          end
          drawScreen()
        elseif key == keys.enter then
          if state.labelInput ~= "" then
            pcall(Labels.set, state.labelEditTarget, state.labelInput)
          else
            pcall(Labels.delete, state.labelEditTarget)
          end
          state.labelInputMode = false
          state.labelEditTarget = nil
          reloadLabels()
          drawScreen()
        elseif key == keys.escape then
          state.labelInputMode = false
          state.labelEditTarget = nil
          drawScreen()
        end
      end
    elseif state.setupCustomMode then
      if evType == "char" then
        state.setupCustomInput = state.setupCustomInput .. ev[2]
        drawScreen()
      elseif evType == "key" then
        local key = ev[2]
        if key == keys.backspace then
          if #state.setupCustomInput > 0 then
            state.setupCustomInput = state.setupCustomInput:sub(1, -2)
          end
          drawScreen()
        elseif key == keys.enter then
          if state.setupCustomInput ~= "" then
            pcall(Roles.set, state.setupPickerRole, state.setupCustomInput)
          end
          state.setupCustomMode = false
          state.setupPickerRole = nil
          drawScreen()
        elseif key == keys.escape then
          state.setupCustomMode = false
          drawScreen()
        end
      end
    end
  end
end

return UI

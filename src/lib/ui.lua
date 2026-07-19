local Config = require("lib.config")
local Crafting = require("lib.crafting")
local DisplayNames = require("lib.display_names")
local Fluids = require("lib.fluids")
local Labels = require("lib.labels")
local Planner = require("lib.planner")
local Roles = require("lib.roles")
local Network = require("lib.network")
local Recipes = require("lib.recipes")
local Stock = require("lib.stock")
local Utils = require("lib.utils")

local UI = {}

local mon, W, H
local buttons = {}
local pendingTask = nil

local state = {
  tab = "recipes",
  page = 1,
  recipes = {}, -- { key, name, displayName, count }
  modTab = "all",
  modTabOffset = 0,
  stockModTab = "all",
  stockModTabOffset = 0,
  deleteTarget = nil, -- recipe storage key pending deletion
  editTarget = nil, -- recipe storage key being edited
  editTargetName = nil, -- item name of the recipe being edited (for display)
  stockItems = {}, -- { name, count } sorted by name
  stockPage = 1,
  stockView = "items", -- "items" | "fluids"
  stockFluids = {}, -- { name, count(mB) } sorted by name
  stockFluidPage = 1,
  stockFluidModTab = "all",
  stockFluidModTabOffset = 0,
  stockScanning = false, -- storage slot scan in progress
  stockScanResult = nil, -- { total, used, free } or { error }
  stockAnalyzing = false, -- fragmentation analysis in progress
  stockAnalysis = nil, -- { wasted, rows, freed? } or { error }
  stockAnalysisPage = 1,
  stockFixing = false, -- slot compaction in progress
  type = "crafter", -- "crafter" | "machine"
  availableMachines = {}, -- populated by reloadMachines()
  -- machine recipe state
  machineItems = {}, -- { name, count, slot, processor } scanned from barrel
  selectedItemIdx = nil, -- index in machineItems for inline machine picker
  resultProcessor = nil, -- machine to pull result from
  resultPickerOpen = false,
  machinePickerOffset = 0, -- horizontal scroll for the inline item->machine picker
  resultPickerOffset = 0, -- horizontal scroll for the "Result from:" picker
  -- recipe fluids state (+Fluids section, machine recipes only)
  recipeFluids = {}, -- { name, mb, processor } added via +Fluids
  availableFluids = {}, -- fluid ids present in Fluid Stock tanks, sorted
  fluidPickerOpen = false, -- +Fluids tapped: fluid list row visible
  fluidPickerOffset = 0, -- horizontal scroll for the fluid list
  setAllPickerOpen = false, -- "Set machine" tapped: assign one machine to all
  setAllPickerOffset = 0, -- horizontal scroll for the set-all picker
  selectedFluidIdx = nil, -- index in recipeFluids of the expanded row
  fluidExpandMode = nil, -- "counter" (mB counter + machines) | "machines"
  fluidMachinePickerOffset = 0, -- scroll for the fluid->machine picker
  -- checklist tab state
  checklistItems = nil, -- nil = not loaded, list = { name, needed, status }
  checklistNoClipboard = false,
  checklistSubTab = "all", -- "all" | "in_stock" | "to_craft" | "done"
  checklistPage = 1,
  checklistMsg = nil,
  checklistMsgIsErr = false,
  checklistMoving = false,
  -- search state
  searchQuery = "",
  searchMode = false,
  -- setup tab state
  setupTab = "roles", -- "roles" | "settings"
  setupPage = 1,
  setupPickerRole = nil,
  setupPickerOffset = 0, -- horizontal scroll for the setup peripheral picker
  setupCustomMode = false,
  setupCustomInput = "",
  settingEditKey = nil, -- Config key being edited via keyboard
  settingInput = "",
  settingBoolKey = nil, -- boolean Config key with an open true/false picker
  -- labels tab state
  labelsPage = 1,
  labelItems = {}, -- { name (peripheral), label }
  labelEditTarget = nil,
  labelInput = "",
  labelInputMode = false,
  labelsScanning = false, -- display-name scan in progress
  labelsScanResult = nil, -- { rows, addedCount, missingCount } or { error }
  labelsScanPage = 1,
  -- new_recipe tab state
  msg = nil,
  msgIsErr = false,
  pendingRecipe = nil,
  -- craft screen state
  craftItem = nil, -- full item name being crafted
  craftKey = nil, -- storage key of the exact recipe variant to craft (or nil)
  craftIsFluid = false, -- crafting a fluid recipe (amount is in mB)
  craftCount = 1,
  craftMsg = nil,
  craftMsgIsErr = false,
  craftMsgIsDone = false,
  craftProgress = 0, -- 0-100
  craftEta = nil, -- seconds left (estimate before start, live rate after)
  craftStartAt = nil, -- os.epoch("utc") when the craft started
  craftPreviewing = false, -- Plan dry run in progress (Craft blocked)
  craftPlanning = false, -- true while plan is being built
  craftPlan = nil, -- list of { name, craftsCount, recipe } for display
  craftQueue = nil, -- { name, count }[] when crafting from checklist queue; nil = single
  craftQueueIdx = 0, -- current position in craftQueue
}

local L = 2 -- left margin
local TABS_ROW = 1
local BODY_ROW = TABS_ROW + 1 -- 2  (first content row)

-- ── Mod helpers ────────────────────────────────────────────

local getMod = Utils.getMod
local stripMod = Utils.stripMod

-- Pretty fallback for ids without a stored displayName:
-- "create:molten_iron" -> "Molten Iron".
local prettifyId = Utils.prettifyId

-- True when a "display name" is actually a raw id / translation key that a
-- mod leaked instead of a real name ("item.avaritia.dur_singularity"):
-- no spaces, but dots or underscores.
local function looksRaw(s)
  return not s:find(" ", 1, true)
    and (s:find(".", 1, true) ~= nil or s:find("_", 1, true) ~= nil)
end

-- Friendly name for an item id: stored displayName if known (and not itself
-- a raw translation key -- those get prettified too), else the id
-- prettified. Plan-space fluid names ("fluid:minecraft:lava") lose their
-- prefix first so they render like any other name. Fluids never get a real
-- displayName (the CC fluid API doesn't report one), so they always use the
-- prettified id -- or a manual entry in data/display_names.json.
local function resolveDisplay(name)
  name = Fluids.stripPrefix(name)
  -- Plan-space variant keys ("name\0nbt") fall back to their base id.
  name = Utils.variantBase(name)
  local dn = DisplayNames.get(name)
  if dn and not looksRaw(dn) then
    return dn
  end
  return prettifyId(dn or name)
end

-- Shared "displayName or resolve" for rows that carry their own displayName
-- (recipes, machine items, scan results). A leaked raw key is prettified
-- IN PLACE -- never fall back to the by-id store: same-id NBT variants
-- (Avaritia singularities) would all collapse to one shared name there.
local function displayOrResolve(dn, name)
  if dn then
    if looksRaw(dn) then
      return prettifyId(dn)
    end
    return dn
  end
  return resolveDisplay(name)
end

-- Duration as "HH:MM:SS" for the craft-time display.
local function fmtTime(seconds)
  seconds = math.max(0, math.floor(seconds + 0.5))
  return string.format(
    "%02d:%02d:%02d",
    math.floor(seconds / 3600),
    math.floor((seconds % 3600) / 60),
    seconds % 60
  )
end

-- Compact mB amount for tables: "500mB", "12.5K mB", "1.2M mB".
local function fmtMb(mb)
  if mb >= 1000000 then
    return string.format("%.1fM mB", mb / 1000000)
  end
  if mb >= 10000 then
    return string.format("%.1fK mB", mb / 1000)
  end
  return mb .. "mB"
end

-- Fuzzy search: splits `query` into whitespace-separated tokens and returns true
-- when every token appears in `text` as a substring, in order. Both are compared
-- lowercased. An empty query matches everything. So "and all" matches both
-- "andesite alloy" and "andesite_alloy".
local function matchesQuery(text, query)
  text = text:lower()
  local pos = 1
  for token in query:lower():gmatch("%S+") do
    local _, e = text:find(token, pos, true)
    if not e then
      return false
    end
    pos = e + 1
  end
  return true
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
--   rowFg         : optional function(item) -> color, overrides colors.white for name text
--   allItems      : optional full list used only for column-width calculation;
--                   useful when `items` is a filtered subset
--   bottomBarRight: optional function(x) drawn at x on the bottom bar instead of Search
local function drawTable(opts)
  local headerY = opts.topY
  local listStart = opts.topY + 1
  local paginationY = H
  local listH = paginationY - listStart
  local items = opts.items
  local displayName = opts.displayName or function(n)
    return n
  end
  local rightW = opts.rightW or 9

  local hName = opts.headerName or "ITEM"
  local maxNameLen = #hName -- minimum: header must always fit
  for _, item in ipairs(opts.allItems or items) do
    local dn = displayName(item.name, item)
    if #dn > maxNameLen then
      maxNameLen = #dn
    end
  end
  local itemW = math.max(0, math.min(maxNameLen, W - L - rightW))
  local xCount = L + itemW + 1

  local hCount = opts.headerCount or "COUNT"
  fill(headerY, colors.gray)
  at(
    math.max(L, xCount - #hName - 1),
    headerY,
    hName,
    colors.lightGray,
    colors.gray
  )
  at(xCount, headerY, hCount, colors.lightGray, colors.gray)

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

      local dn = truncate(displayName(item.name, item), itemW)
      local nameFg = opts.rowFg and opts.rowFg(item) or colors.white
      at(math.max(L, xCount - #dn - 1), row, dn, nameFg, rowBg)
      local countStr = opts.countText and opts.countText(item)
        or ("x" .. item.count)
      local countColor = opts.countColor and opts.countColor(item)
        or colors.yellow
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
        if page > 1 then
          opts.setPage(page - 1)
        end
      end)
      mkBtn(btnX + 5, paginationY, "v", colors.black, colors.orange, function()
        if page < totalPages then
          opts.setPage(page + 1)
        end
      end)
      afterNav = btnX + 10
    else
      afterNav = btnX
    end
  end

  if opts.bottomBarRight then
    opts.bottomBarRight(afterNav)
  else
    local searchBtnW
    if state.searchMode then
      mkBtn(afterNav, paginationY, "x", colors.white, colors.red, function()
        state.searchQuery = ""
        state.searchMode = false
        state.page = 1
        state.stockPage = 1
      end)
      searchBtnW = #" x "
    else
      mkBtn(
        afterNav,
        paginationY,
        "Search",
        colors.black,
        colors.orange,
        function()
          state.searchMode = true
        end
      )
      searchBtnW = #" Search "
    end

    if state.searchQuery ~= "" or state.searchMode then
      local queryStart = afterNav + searchBtnW + 1
      local refreshW = opts.onRefresh and (#" Refresh " + 1) or 0
      local scanW = opts.onScan and (#" Scan " + 1) or 0
      local beforeW = opts.beforeRefresh and (#opts.beforeRefresh.label + 2 + 1)
        or 0
      local display = state.searchQuery .. (state.searchMode and "_" or "")
      if queryStart <= W - refreshW - scanW - beforeW then
        at(
          queryStart,
          paginationY,
          truncate(display, W - refreshW - scanW - beforeW - queryStart),
          colors.black,
          colors.yellow
        )
      end
    end

    local xAfterRefresh = W + 1
    if opts.onRefresh then
      xAfterRefresh = W - #" Refresh " + 1
      mkBtn(
        xAfterRefresh,
        paginationY,
        "Refresh",
        colors.black,
        colors.orange,
        opts.onRefresh
      )
    end
    if opts.onScan then
      xAfterRefresh = xAfterRefresh - #" Scan " - 1
      mkBtn(
        xAfterRefresh,
        paginationY,
        "Scan",
        colors.black,
        colors.orange,
        opts.onScan
      )
    end
    -- Optional extra button left of Scan/Refresh (e.g. the STOCK tab's
    -- Fluids/Items toggle).
    if opts.beforeRefresh then
      mkBtn(
        xAfterRefresh - (#opts.beforeRefresh.label + 2) - 1,
        paginationY,
        opts.beforeRefresh.label,
        colors.black,
        colors.cyan,
        opts.beforeRefresh.fn
      )
    end
  end
end

-- Draws scrollable mod sub-tabs for items whose names follow "mod:item" format.
-- opts: { getTab, setTab, getOffset, setOffset, resetPage }
-- Returns items filtered to the currently selected mod.
local function drawModTabs(y, items, opts)
  local seen, mods = {}, {}
  for _, item in ipairs(items) do
    local mod = getMod(item.name)
    if not seen[mod] then
      seen[mod] = true
      table.insert(mods, mod)
    end
  end
  table.sort(mods)

  local modTab = opts.getTab()

  -- Fall back to "all" when the selected mod isn't in items -- but only for
  -- this frame. The stored selection is kept, so a transiently empty or
  -- shrunken list (e.g. mid-reload) can't permanently kick the user's mod
  -- tab back to All.
  if modTab ~= "all" then
    local found = false
    for _, mod in ipairs(mods) do
      if mod == modTab then
        found = true
        break
      end
    end
    if not found then
      modTab = "all"
    end
  end

  local modOffset = opts.getOffset()

  local allActive = modTab == "all"
  at(
    L,
    y,
    "All",
    allActive and colors.black or colors.gray,
    allActive and colors.yellow or colors.black
  )
  table.insert(buttons, {
    x1 = L,
    x2 = L + 2,
    y = y,
    fn = function()
      opts.setTab("all")
      opts.setOffset(0)
      opts.resetPage()
    end,
  })

  if #mods > 0 then
    local scrollL = L + 4
    local modsNoScroll = L + 4
    local modsWithScroll = L + 6
    local totalModW = 0
    for i, mod in ipairs(mods) do
      totalModW = totalModW + #mod + (i > 1 and 1 or 0)
    end
    local spaceNoScroll = W - modsNoScroll + 1
    local needsScroll = totalModW > spaceNoScroll
    local modsStart = needsScroll and modsWithScroll or modsNoScroll
    local modsEnd = needsScroll and (W - 2) or W
    local spaceForMods = modsEnd - modsStart + 1

    modOffset = math.max(0, modOffset)
    opts.setOffset(modOffset)

    local function calcLastVisible(offset)
      local used, last = 0, offset
      for i = offset + 1, #mods do
        local w = #mods[i] + (used > 0 and 1 or 0)
        if used + w > spaceForMods then
          break
        end
        used = used + w
        last = i
      end
      return last
    end

    local lastVisibleIdx = calcLastVisible(modOffset)
    if lastVisibleIdx == modOffset and modOffset > 0 then
      modOffset = math.max(0, modOffset - 1)
      opts.setOffset(modOffset)
      lastVisibleIdx = calcLastVisible(modOffset)
    end

    local function prevPageOffset()
      local prevO, o = 0, 0
      -- Stop exactly one page back (see drawMachinePager for the reasoning).
      while o < modOffset do
        local lv = calcLastVisible(o)
        if lv <= o then
          break
        end
        prevO = o
        o = lv
      end
      return prevO
    end

    -- Offset of the last page (the one whose window reaches the final mod),
    -- page-aligned like every other offset used here.
    local function lastPageOffset()
      local o = 0
      while calcLastVisible(o) < #mods do
        o = calcLastVisible(o)
      end
      return o
    end

    if needsScroll then
      -- Wrap-around: at the start, "<" jumps to the last page instead of
      -- doing nothing, so the end of the list is one tap away.
      at(scrollL, y, "<", colors.white, colors.black)
      table.insert(buttons, {
        x1 = scrollL,
        x2 = scrollL,
        y = y,
        fn = function()
          if modOffset > 0 then
            opts.setOffset(prevPageOffset())
          else
            opts.setOffset(lastPageOffset())
          end
        end,
      })
    end

    local x = modsStart
    for i = modOffset + 1, lastVisibleIdx do
      local mod = mods[i]
      local active = modTab == mod
      at(
        x,
        y,
        mod,
        active and colors.black or colors.gray,
        active and colors.yellow or colors.black
      )
      local captMod = mod
      table.insert(buttons, {
        x1 = x,
        x2 = x + #mod - 1,
        y = y,
        fn = function()
          opts.setTab(captMod)
          opts.resetPage()
        end,
      })
      x = x + #mod + 1
    end

    if needsScroll then
      -- Wrap-around: at the end, ">" jumps back to the start.
      at(W, y, ">", colors.white, colors.black)
      table.insert(buttons, {
        x1 = W,
        x2 = W,
        y = y,
        fn = function()
          if lastVisibleIdx < #mods then
            opts.setOffset(lastVisibleIdx)
          else
            opts.setOffset(0)
          end
        end,
      })
    end
  end

  if modTab == "all" then
    return items
  end
  local filtered = {}
  for _, item in ipairs(items) do
    if getMod(item.name) == modTab then
      table.insert(filtered, item)
    end
  end
  return filtered
end

local reloadRecipes
local reloadStock
local reloadStockFluids
local reloadMachines
local reloadMachineItems
local reloadFluids
local reloadLabels
local reloadChecklist

-- ── Sections ───────────────────────────────────────────────

local function drawTabs()
  fill(TABS_ROW, colors.black)
  local x = L

  local tabs = {
    { id = "recipes", label = " RECIPES " },
    { id = "stock", label = " STOCK " },
    { id = "new_recipe", label = " +RECIPE " },
    { id = "checklist", label = " CHECKLIST " },
    { id = "labels", label = " LABELS " },
    { id = "setup", label = " SETUP " },
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
        -- The search survives switches within the recipes family (RECIPES,
        -- the craft screen, +RECIPE) in BOTH directions -- clearing only on
        -- the way back proved useless, the query was already wiped when
        -- leaving RECIPES. Any other switch clears it (a STOCK query must
        -- not leak into RECIPES).
        local searchFamily = { recipes = true, craft = true, new_recipe = true }
        local keepSearch = searchFamily[tab.id] and searchFamily[state.tab]
        if not keepSearch then
          state.searchQuery = ""
          state.searchMode = false
        end
        state.labelInputMode = false
        state.setupPickerRole = nil
        state.setupCustomMode = false
        state.settingEditKey = nil
        state.settingBoolKey = nil
        if tab.id == "setup" then
          state.tab = "setup"
          state.setupPage = 1
          reloadLabels()
        elseif tab.id == "labels" then
          state.tab = "labels"
          state.labelsPage = 1
          state.labelsScanResult = nil
          state.labelsScanning = false
          reloadLabels()
        elseif tab.id == "recipes" then
          state.tab = "recipes"
          state.page = 1
          state.deleteTarget = nil
          state.editTarget = nil
          state.editTargetName = nil
          state.craftItem = nil
          state.craftKey = nil
        elseif tab.id == "stock" then
          state.tab = "stock"
          state.stockPage = 1
          state.stockFluidPage = 1
          state.stockScanResult = nil
          state.stockScanning = false
          state.stockAnalysis = nil
          state.stockAnalyzing = false
          state.stockFixing = false
          if state.stockView == "fluids" then
            reloadStockFluids()
          else
            reloadStock()
          end
        elseif tab.id == "checklist" then
          state.tab = "checklist"
          state.checklistPage = 1
          state.checklistMsg = nil
          state.craftQueue = nil
          reloadChecklist()
        elseif tab.id == "new_recipe" then
          state.tab = "new_recipe"
          state.msg = nil
          state.pendingRecipe = nil
          state.editTarget = nil
          state.editTargetName = nil
          state.recipeFluids = {}
          state.fluidPickerOpen = false
          state.setAllPickerOpen = false
          state.selectedFluidIdx = nil
          state.fluidExpandMode = nil
          reloadMachines()
          if state.type == "machine" then
            reloadMachineItems()
            reloadFluids()
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
  local headerY = BODY_ROW + 1
  local listStart = BODY_ROW + 2
  local paginationY = H
  local listH = paginationY - listStart

  for y = modTabsY, H do
    fill(y, colors.black)
  end

  local modFiltered = drawModTabs(modTabsY, state.recipes, {
    getTab = function()
      return state.modTab
    end,
    setTab = function(t)
      state.modTab = t
    end,
    getOffset = function()
      return state.modTabOffset
    end,
    setOffset = function(o)
      state.modTabOffset = o
    end,
    resetPage = function()
      state.page = 1
    end,
  })

  local sq = state.searchQuery
  local filtered = {}
  for _, r in ipairs(modFiltered) do
    if
      sq == ""
      or matchesQuery(stripMod(r.name), sq)
      or matchesQuery(displayOrResolve(r.displayName, r.name), sq)
    then
      table.insert(filtered, r)
    end
  end

  -- Right zone: 1 gap + 8 count + 8 Craft + 7 Edit + 5 Del = 29
  drawTable({
    topY = headerY,
    items = filtered,
    page = state.page,
    setPage = function(p)
      state.page = p
    end,
    displayName = function(name, item)
      return displayOrResolve(item and item.displayName, name)
    end,
    rightW = 29,
    emptyMsg = "No recipes yet",
    onRefresh = reloadRecipes,
    countText = function(item)
      if item.resultType == "fluid" then
        return fmtMb(item.count)
      end
      return "x" .. item.count
    end,
    drawActions = function(item, row, rowBg, xCount)
      local xCraft = xCount + 8
      local xEdit = xCraft + 8
      local xDel = xEdit + 7
      local capturedKey = item.key
      local capturedName = item.name
      if capturedKey == state.deleteTarget then
        mkBtn(xCraft, row, "Delete", colors.white, colors.red, function()
          pcall(Recipes.deleteRecipe, capturedKey)
          state.deleteTarget = nil
          reloadRecipes()
        end)
        mkBtn(xCraft + 10, row, "Cancel", colors.white, colors.gray, function()
          state.deleteTarget = nil
        end)
      else
        local capturedIsFluid = item.resultType == "fluid"
        local capturedCount = item.count
        mkBtn(xCraft, row, "Craft", colors.black, colors.yellow, function()
          state.craftItem = capturedName
          state.craftKey = capturedKey
          state.craftIsFluid = capturedIsFluid
          -- Fluid recipes are ordered in mB; default to one craft's yield.
          state.craftCount = capturedIsFluid and (capturedCount or 1000) or 1
          state.craftMsg = nil
          state.craftMsgIsErr = false
          state.craftMsgIsDone = false
          state.craftProgress = 0
          state.craftEta = nil
          state.craftStartAt = nil
          state.craftPlanning = false
          state.craftPlan = nil
          state.tab = "craft"
        end)
        mkBtn(xEdit, row, "Edit", colors.lightGray, colors.gray, function()
          state.tab = "new_recipe"
          state.editTarget = capturedKey
          state.editTargetName = capturedName
          state.pendingRecipe = nil
          state.msg = nil
          reloadMachines()
          local recipe = Recipes.getRecipeByKey(capturedKey)
          if recipe then
            state.type = recipe.type or "crafter"
            state.resultProcessor = recipe.resultProcessor
            state.resultPickerOpen = false
            state.selectedItemIdx = nil
            state.recipeFluids = {}
            state.fluidPickerOpen = false
            state.setAllPickerOpen = false
            state.selectedFluidIdx = nil
            state.fluidExpandMode = nil
            if state.type == "machine" then
              state.machineItems = {}
              for _, item in ipairs(recipe.items) do
                table.insert(state.machineItems, {
                  name = item.name,
                  displayName = item.displayName,
                  nbt = item.nbt,
                  count = item.count,
                  slot = item.slot,
                  processor = item.processor,
                })
              end
              for _, fluid in ipairs(recipe.fluids or {}) do
                table.insert(state.recipeFluids, {
                  name = fluid.name,
                  mb = fluid.mb,
                  processor = fluid.processor,
                })
              end
              reloadFluids()
            end
          end
        end)
        mkBtn(xDel, row, "Del", colors.black, colors.red, function()
          state.deleteTarget = capturedKey
        end)
      end
    end,
  })
end

-- ── +RECIPE tab ─────────────────────────────────────────────

-- Returns the display name for a machine peripheral: label if set, else stripped name.
local function machineLabel(name)
  if not name then
    return "?"
  end
  return Labels.get(name) or stripMod(name)
end

-- Draws machine selector buttons on a single row `y` with horizontal
-- pagination (< / > arrows appear when the buttons overflow the width), the
-- same scrolling scheme used by the mod sub-tabs.
--   machines : list of peripheral names (rendered via machineLabel)
--   selected : currently selected machine name, or a set
--              { [name] = true } when several can be selected at once
--   getOffset/setOffset : accessors for this picker's scroll offset
--   onSelect : callback(name) when a button is tapped
--   emptyMsg : optional text when `machines` is empty
--   labelFn  : optional label renderer (default machineLabel); lets the
--              same pager list fluids or any other named things
local function drawMachinePager(
  y,
  machines,
  selected,
  getOffset,
  setOffset,
  onSelect,
  emptyMsg,
  labelFn
)
  if #machines == 0 then
    at(L, y, emptyMsg or "No machines found", colors.gray, colors.black)
    return
  end

  local function isSelected(name)
    if type(selected) == "table" then
      return selected[name] == true
    end
    return name == selected
  end

  -- mkBtn renders " label " → hit width is #label + 2.
  labelFn = labelFn or machineLabel
  local labels = {}
  local totalW = 0
  for i, name in ipairs(machines) do
    labels[i] = labelFn(name)
    totalW = totalW + (#labels[i] + 2) + (i > 1 and 1 or 0)
  end

  local spaceNoScroll = W - L + 1
  local needsScroll = totalW > spaceNoScroll
  local startX = needsScroll and (L + 2) or L
  local endX = needsScroll and (W - 2) or W
  local space = endX - startX + 1

  local offset = math.max(0, getOffset())

  local function calcLastVisible(o)
    local used, last = 0, o
    for i = o + 1, #labels do
      local w = (#labels[i] + 2) + (used > 0 and 1 or 0)
      if used + w > space then
        break
      end
      used = used + w
      last = i
    end
    return last
  end

  local lastVisible = calcLastVisible(offset)
  if lastVisible == offset and offset > 0 then
    offset = math.max(0, offset - 1)
    setOffset(offset)
    lastVisible = calcLastVisible(offset)
  end

  local function prevPageOffset()
    local prevO, o = 0, 0
    -- Walk page boundaries (0, calcLastVisible(0), ...) up to the current
    -- offset and return the one just before it. Using `o < offset` (not
    -- `lv >= offset`) stops exactly one page back, not two.
    while o < offset do
      local lv = calcLastVisible(o)
      if lv <= o then
        break
      end
      prevO = o
      o = lv
    end
    return prevO
  end

  -- Offset of the last page (the one whose window reaches the final label),
  -- page-aligned like every other offset used here.
  local function lastPageOffset()
    local o = 0
    while calcLastVisible(o) < #labels do
      o = calcLastVisible(o)
    end
    return o
  end

  if needsScroll then
    -- Wrap-around: at the start, "<" jumps to the last page instead of doing
    -- nothing, so the end of the list is one tap away.
    at(L, y, "<", colors.white, colors.black)
    table.insert(buttons, {
      x1 = L,
      x2 = L,
      y = y,
      fn = function()
        if offset > 0 then
          setOffset(prevPageOffset())
        else
          setOffset(lastPageOffset())
        end
      end,
    })
  end

  local x = startX
  for i = offset + 1, lastVisible do
    local capt = machines[i]
    mkBtn(
      x,
      y,
      labels[i],
      colors.black,
      isSelected(capt) and colors.cyan or colors.gray,
      function()
        onSelect(capt)
      end
    )
    x = x + (#labels[i] + 2) + 1
  end

  if needsScroll then
    -- Wrap-around: at the end, ">" jumps back to the start.
    at(W, y, ">", colors.white, colors.black)
    table.insert(buttons, {
      x1 = W,
      x2 = W,
      y = y,
      fn = function()
        if lastVisible < #labels then
          setOffset(lastVisible)
        else
          setOffset(0)
        end
      end,
    })
  end
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
        reloadFluids()
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

        -- Item row: "  name x2" or "  name x2 > machine". Per-slot
        -- displayName first: same-id NBT variants must show their own
        -- names.
        local itemName = displayOrResolve(item.displayName, item.name)
          .. " x"
          .. (item.count or 1)
        local lineText
        if item.processor then
          lineText = "  " .. itemName .. " > " .. machineLabel(item.processor)
        else
          lineText = "  " .. itemName
        end
        local padded = truncate(lineText, W - L)
        padded = padded .. string.rep(" ", math.max(0, W - L - #padded))
        mkBtnTight(L, cur, padded, colors.lightGray, colors.black, function()
          state.selectedItemIdx = (state.selectedItemIdx == captI) and nil
            or captI
          state.machinePickerOffset = 0
        end)
        cur = cur + 1

        -- Inline machine picker (single paginated row below the item row)
        if isSelected then
          drawMachinePager(
            cur,
            state.availableMachines,
            state.machineItems[captI].processor,
            function()
              return state.machinePickerOffset
            end,
            function(o)
              state.machinePickerOffset = o
            end,
            function(mname)
              state.machineItems[captI].processor = mname
              state.selectedItemIdx = nil
            end
          )
          cur = cur + 1
        end
      end
    end

    -- ── Fluids section ─────────────────────────────────────────
    -- Fluid ingredients added via +Fluids. Tap the red x at the row start to
    -- remove the fluid, tap the fluid NAME to pick the machine it goes into,
    -- tap the AMOUNT to open the mB counter.
    for i, fluid in ipairs(state.recipeFluids) do
      local isSelected = state.selectedFluidIdx == i
      local captI = i

      mkBtnTight(L, cur, "x", colors.white, colors.red, function()
        table.remove(state.recipeFluids, captI)
        state.selectedFluidIdx = nil
        state.fluidExpandMode = nil
      end)

      local xName = L + 2
      local nameText = resolveDisplay(fluid.name)
      mkBtnTight(
        xName,
        cur,
        nameText,
        colors.lightBlue,
        colors.black,
        function()
          if
            state.selectedFluidIdx == captI
            and state.fluidExpandMode == "machines"
          then
            state.selectedFluidIdx = nil
            state.fluidExpandMode = nil
          else
            state.selectedFluidIdx = captI
            state.fluidExpandMode = "machines"
            state.fluidMachinePickerOffset = 0
          end
        end
      )

      local xAmount = xName + #nameText + 1
      local amountText = fluid.mb .. "mB"
      mkBtnTight(
        xAmount,
        cur,
        amountText,
        colors.yellow,
        colors.black,
        function()
          if
            state.selectedFluidIdx == captI
            and state.fluidExpandMode == "counter"
          then
            state.selectedFluidIdx = nil
            state.fluidExpandMode = nil
          else
            state.selectedFluidIdx = captI
            state.fluidExpandMode = "counter"
            state.fluidMachinePickerOffset = 0
          end
        end
      )

      local xAfter = xAmount + #amountText + 1
      if fluid.processor then
        local machineText = "> " .. machineLabel(fluid.processor)
        at(
          xAfter,
          cur,
          truncate(machineText, math.max(0, W - xAfter)),
          colors.lightGray,
          colors.black
        )
      end
      cur = cur + 1

      if isSelected then
        if state.fluidExpandMode == "counter" then
          -- -1000 -100 -10 -1 <value>mB +1 +10 +100 +1000
          -- Tapping the value collapses the row.
          -- Same quirk as the craft-amount counter: from the minimum, a
          -- +10/+100/+1000 tap sets that value instead of adding to 1.
          local function addMb(delta)
            local f = state.recipeFluids[captI]
            if delta > 1 and f.mb == 1 then
              f.mb = delta
            else
              f.mb = math.max(1, f.mb + delta)
            end
          end
          local xb = L + 2
          mkBtnTight(xb, cur, "-1000", colors.lightGray, colors.gray, function()
            addMb(-1000)
          end)
          mkBtnTight(
            xb + 6,
            cur,
            "-100",
            colors.lightGray,
            colors.gray,
            function()
              addMb(-100)
            end
          )
          mkBtnTight(
            xb + 11,
            cur,
            "-10",
            colors.lightGray,
            colors.gray,
            function()
              addMb(-10)
            end
          )
          mkBtnTight(
            xb + 15,
            cur,
            "-1",
            colors.lightGray,
            colors.gray,
            function()
              addMb(-1)
            end
          )
          local valueText = string.format("%5d", fluid.mb) .. "mB"
          mkBtnTight(
            xb + 18,
            cur,
            valueText,
            colors.black,
            colors.yellow,
            function()
              state.selectedFluidIdx = nil
              state.fluidExpandMode = nil
            end
          )
          local xPlus = xb + 18 + #valueText + 1
          mkBtnTight(xPlus, cur, "+1", colors.lightGray, colors.gray, function()
            addMb(1)
          end)
          mkBtnTight(
            xPlus + 3,
            cur,
            "+10",
            colors.lightGray,
            colors.gray,
            function()
              addMb(10)
            end
          )
          mkBtnTight(
            xPlus + 7,
            cur,
            "+100",
            colors.lightGray,
            colors.gray,
            function()
              addMb(100)
            end
          )
          mkBtnTight(
            xPlus + 12,
            cur,
            "+1000",
            colors.lightGray,
            colors.gray,
            function()
              addMb(1000)
            end
          )
          cur = cur + 1
        end

        -- Machine picker: below the counter when it is open, alone otherwise.
        drawMachinePager(
          cur,
          state.availableMachines,
          state.recipeFluids[captI].processor,
          function()
            return state.fluidMachinePickerOffset
          end,
          function(o)
            state.fluidMachinePickerOffset = o
          end,
          function(mname)
            state.recipeFluids[captI].processor = mname
            state.selectedFluidIdx = nil
            state.fluidExpandMode = nil
          end
        )
        cur = cur + 1
      end
    end

    -- Action row: [Set machine] [+Fluids]. "Set machine" assigns one machine
    -- to every recipe item and fluid at once; +Fluids toggles a one-line
    -- list of fluids available in Fluid Stock tanks. The two pickers are
    -- mutually exclusive.
    mkBtn(
      L,
      cur,
      "Set machine",
      colors.black,
      state.setAllPickerOpen and colors.green or colors.lightGray,
      function()
        if state.setAllPickerOpen then
          state.setAllPickerOpen = false
        else
          state.setAllPickerOpen = true
          state.setAllPickerOffset = 0
          state.fluidPickerOpen = false
          state.selectedFluidIdx = nil
          state.fluidExpandMode = nil
          state.selectedItemIdx = nil
        end
      end
    )
    mkBtn(
      L + #" Set machine " + 1,
      cur,
      "+Fluids",
      colors.black,
      state.fluidPickerOpen and colors.green or colors.lightGray,
      function()
        if state.fluidPickerOpen then
          state.fluidPickerOpen = false
        else
          reloadFluids()
          state.fluidPickerOpen = true
          state.fluidPickerOffset = 0
          state.setAllPickerOpen = false
          state.selectedFluidIdx = nil
          state.fluidExpandMode = nil
        end
      end
    )
    cur = cur + 1

    if state.setAllPickerOpen then
      -- Highlight the machine only when every item and fluid already agrees.
      local common = nil
      do
        local same = true
        local function check(processor)
          if not processor then
            same = false
          elseif common == nil then
            common = processor
          elseif common ~= processor then
            same = false
          end
        end
        for _, item in ipairs(state.machineItems) do
          check(item.processor)
        end
        for _, fluid in ipairs(state.recipeFluids) do
          check(fluid.processor)
        end
        if not same then
          common = nil
        end
      end

      drawMachinePager(cur, state.availableMachines, common, function()
        return state.setAllPickerOffset
      end, function(o)
        state.setAllPickerOffset = o
      end, function(mname)
        for _, item in ipairs(state.machineItems) do
          item.processor = mname
        end
        for _, fluid in ipairs(state.recipeFluids) do
          fluid.processor = mname
        end
        state.setAllPickerOpen = false
      end)
      cur = cur + 1
    end

    if state.fluidPickerOpen then
      drawMachinePager(cur, state.availableFluids, nil, function()
        return state.fluidPickerOffset
      end, function(o)
        state.fluidPickerOffset = o
      end, function(fname)
        table.insert(
          state.recipeFluids,
          { name = fname, mb = 1000, processor = nil }
        )
        state.fluidPickerOpen = false
        state.selectedFluidIdx = #state.recipeFluids
        state.fluidExpandMode = "counter"
        state.fluidMachinePickerOffset = 0
      end, "No fluids in Fluid Stock", resolveDisplay)
      cur = cur + 1
    end

    -- Reset button (editing only): re-read items from the interface barrel
    if state.editTarget then
      mkBtn(L, cur, "Reset", colors.white, colors.gray, function()
        reloadMachineItems()
      end)
      cur = cur + 1
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
          state.resultPickerOffset = 0
        end
      )
      cur = cur + 2
    else
      -- Expanded: single paginated machine row on the next line
      cur = cur + 1
      drawMachinePager(
        cur,
        state.availableMachines,
        state.resultProcessor,
        function()
          return state.resultPickerOffset
        end,
        function(o)
          state.resultPickerOffset = o
        end,
        function(name)
          state.resultProcessor = name
          state.resultPickerOpen = false
        end
      )
      cur = cur + 2
    end
  else
    -- Crafter: hint text
    if state.editTarget then
      at(
        L,
        cur,
        "Editing: "
          .. truncate(
            resolveDisplay(state.editTargetName or state.editTarget),
            W - L - 9
          ),
        colors.yellow,
        colors.black
      )
    else
      local prefix = "Place items in "
      local portLabel = Labels.get(Roles.get("recipe_interface"))
        or stripMod(Roles.get("recipe_interface") or "?")
      at(L, cur, prefix, colors.lightGray, colors.black)
      at(L + #prefix, cur, portLabel, colors.yellow, colors.black)
    end
    cur = cur + 2 -- hint + empty gap
  end

  -- Saves the freshly test-crafted recipe (state.pendingRecipe). Shared by the
  -- always-visible Save button in the action row and the Save in the Result
  -- section below (which can scroll off-screen when a machine recipe has many
  -- item rows).
  local function savePendingRecipe()
    local pr = state.pendingRecipe
    if not pr then
      return
    end
    if state.type == "machine" then
      for _, item in ipairs(pr.items) do
        if not item.processor then
          state.msg = "Assign machine to all items"
          state.msgIsErr = true
          return
        end
      end
      for _, fluid in ipairs(pr.fluids or {}) do
        if not fluid.processor then
          state.msg = "Assign machine to all fluids"
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
      state.resultProcessor,
      pr.fluids
    )
    if ok then
      state.pendingRecipe = nil
      state.editTarget = nil
      state.editTargetName = nil
      state.msg = nil
      state.recipeFluids = {}
      state.fluidPickerOpen = false
      state.setAllPickerOpen = false
      state.selectedFluidIdx = nil
      state.fluidExpandMode = nil
      reloadRecipes()
    else
      state.msg = tostring(err)
      state.msgIsErr = true
      state.pendingRecipe = nil
    end
  end

  -- ── Action buttons ───────────────────────────────────────────
  local testLabel = "Test Craft"
  mkBtn(L, cur, testLabel, colors.black, colors.lightBlue, function()
    if state.type == "machine" then
      if #state.machineItems == 0 and #state.recipeFluids == 0 then
        state.msg = "No items or fluids for recipe"
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
      for _, fluid in ipairs(state.recipeFluids) do
        if not fluid.processor then
          state.msg = "Assign machine to all fluids"
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
      local recipeItems, craftedItem, recipeFluids
      if state.type == "machine" then
        local ok, result = pcall(
          Crafting.craftNewMachineRecipe,
          state.machineItems,
          state.resultProcessor,
          state.recipeFluids
        )
        if not ok then
          state.msg = tostring(result)
          state.msgIsErr = true
          return
        end
        recipeItems, craftedItem = state.machineItems, result
        recipeFluids = state.recipeFluids
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
      local exists
      if craftedItem.isFluid then
        exists = Recipes.findExistingFluid(name) ~= nil
      else
        exists = Recipes.findExisting(name, craftedItem.displayName) ~= nil
      end
      state.pendingRecipe = {
        items = recipeItems,
        fluids = recipeFluids,
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
    state.recipeFluids = {}
    state.fluidPickerOpen = false
    state.setAllPickerOpen = false
    state.selectedFluidIdx = nil
    state.fluidExpandMode = nil
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

  -- Slot after Clear: while a recipe is pending (post Test Craft) show an
  -- always-visible Save for it -- [Test Craft] [Clear] [Save] -- so it stays
  -- reachable even when the Result-section Save scrolls off-screen. Otherwise,
  -- when editing an existing recipe, this slot updates its machine assignment.
  local afterClearX = clearX + #" Clear " + 1
  if state.pendingRecipe then
    mkBtn(
      afterClearX,
      cur,
      "Save",
      colors.black,
      colors.yellow,
      savePendingRecipe
    )
  elseif state.editTarget then
    mkBtn(afterClearX, cur, "Save", colors.white, colors.gray, function()
      if state.type == "machine" then
        if not state.resultProcessor then
          state.msg = "Select result machine"
          state.msgIsErr = true
          return
        end
        for _, fluid in ipairs(state.recipeFluids) do
          if not fluid.processor then
            state.msg = "Assign machine to all fluids"
            state.msgIsErr = true
            return
          end
        end
        -- Keyed by name+nbt so same-id variants can use different machines.
        local itemProcessors = {}
        for _, item in ipairs(state.machineItems) do
          itemProcessors[item.name .. "\0" .. (item.nbt or "")] = item.processor
        end
        local ok, err = pcall(
          Recipes.updateRecipeProcessor,
          state.editTarget,
          state.type,
          nil,
          state.resultProcessor,
          itemProcessors,
          state.recipeFluids
        )
        if ok then
          state.msg = "Saved: " .. (state.editTargetName or state.editTarget)
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
          state.msg = "Saved: " .. (state.editTargetName or state.editTarget)
          state.msgIsErr = false
        else
          state.msg = tostring(err)
          state.msgIsErr = true
        end
      end
    end)
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
  local resultText
  if pr.craftedItem.isFluid then
    resultText = resolveDisplay(pr.name) .. " x" .. pr.craftedItem.count .. "mB"
  else
    resultText = displayOrResolve(pr.craftedItem.displayName, pr.name)
      .. " x"
      .. pr.craftedItem.count
  end
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
  mkBtn(L, saveY, "Save", colors.black, colors.yellow, savePendingRecipe)
  mkBtn(L + #"Save" + 3, saveY, "Cancel", colors.white, colors.gray, function()
    state.pendingRecipe = nil
    state.editTarget = nil
    state.msg = nil
  end)
end

-- ── Craft helpers ───────────────────────────────────────────

local function prepareCraftState(name, count)
  state.craftItem = name
  state.craftCount = count
  state.craftMsg = nil
  state.craftMsgIsErr = false
  state.craftMsgIsDone = false
  state.craftProgress = 0
  state.craftEta = nil
  state.craftStartAt = nil
  state.craftPlanning = true
  state.craftPlan = nil
end

-- Live remaining-time update from actual craft speed: once runs complete,
-- elapsed/done extrapolates the rest (self-correcting, converges fast on
-- big homogeneous crafts). Before the first run the plan estimate stands.
local function updateEta(doneRuns, totalRuns)
  if not state.craftStartAt or doneRuns <= 0 then
    return
  end
  if doneRuns >= totalRuns then
    state.craftEta = 0
    return
  end
  local elapsed = (os.epoch("utc") - state.craftStartAt) / 1000
  state.craftEta = elapsed / doneRuns * (totalRuns - doneRuns)
end

-- Builds the on-screen copy of a craft plan. Each entry tracks `remaining`
-- (items still to craft) so the tree counts down as crafts complete; `perCraft`
-- is the recipe yield used to convert completed crafts into items.
local function makePlanView(plan)
  local copy = {}
  for i, step in ipairs(plan) do
    copy[i] = {
      name = step.name,
      -- Variant outputs show the recipe's own displayName, not the shared
      -- by-id name.
      displayName = step.recipe.displayName,
      isFluid = step.recipe.resultType == "fluid",
      perCraft = step.recipe.count,
      remaining = step.craftsCount * step.recipe.count,
    }
  end
  return copy
end

-- Decrements the remaining-items counter of a plan step after a craft run.
local function updatePlanStepProgress(stepName, craftsDone)
  if not state.craftPlan then
    return
  end
  for _, s in ipairs(state.craftPlan) do
    if s.name == stepName then
      s.remaining = math.max(0, s.remaining - craftsDone * s.perCraft)
      return
    end
  end
end

-- Marks a plan step as actively crafting (shown at the top of the tree).
local function setPlanStepActive(stepName, isActive)
  if not state.craftPlan then
    return
  end
  for _, s in ipairs(state.craftPlan) do
    if s.name == stepName then
      s.active = isActive or nil
      return
    end
  end
end

-- Removes a completed step from the on-screen plan. Plan execution is
-- pipelined, so steps can finish out of order -- remove by name, not the head.
local function removePlanStep(stepName)
  if not state.craftPlan then
    return
  end
  if stepName then
    for i, s in ipairs(state.craftPlan) do
      if s.name == stepName then
        table.remove(state.craftPlan, i)
        return
      end
    end
  elseif #state.craftPlan > 0 then
    table.remove(state.craftPlan, 1)
  end
end

-- key: optional storage key of the exact recipe variant to craft. When several
-- recipes share `name`, this pins the craft to the selected one; nil crafts the
-- first variant found for that name.
-- isFluid: the recipe produces a fluid; `count` is mB (display only).
local function makeCraftTask(name, count, key, isFluid)
  local rootRecipe = key and Recipes.getRecipeByKey(key) or nil
  return function(redraw)
    state.craftStartAt = os.epoch("utc")
    local lastDrawAt = 0
    local ok, err = pcall(
      Crafting.craftItem,
      name,
      count,
      function(i, total, stepName, craftsDone)
        state.craftProgress = math.floor(i / total * 100)
        updateEta(i, total)
        updatePlanStepProgress(stepName, craftsDone)
        -- Full monitor redraws are not free: cap them at ~4/s (the final
        -- run always draws so the bar ends at 100%).
        local now = os.epoch("utc")
        if redraw and (now - lastDrawAt >= 250 or i >= total) then
          lastDrawAt = now
          redraw()
        end
      end,
      function(plan)
        state.craftPlan = makePlanView(plan)
        state.craftPlanning = false
        -- Initial estimate only when Count Time is on; the live
        -- actual-rate ETA below works either way (it is free).
        if Config.COUNT_CRAFT_TIME then
          local okEst, est = pcall(Planner.estimateTime, plan)
          if okEst then
            state.craftEta = est
          end
        end
        if redraw then
          redraw()
        end
      end,
      function(stepName)
        removePlanStep(stepName)
        if redraw then
          redraw()
        end
      end,
      rootRecipe,
      function(stepName, isActive)
        setPlanStepActive(stepName, isActive)
        if redraw then
          redraw()
        end
      end
    )
    if ok then
      state.craftPlan = nil
      state.craftMsgIsDone = true
      state.craftMsg = "Done! "
        .. resolveDisplay(name)
        .. " x"
        .. count
        .. (isFluid and "mB" or "")
      state.craftProgress = 100
      state.craftEta = 0
    else
      state.craftMsg = tostring(err)
      state.craftMsgIsErr = true
      state.craftMsgIsDone = false
      state.craftPlanning = false
      state.craftPlan = nil
      state.craftProgress = 0
      state.craftEta = nil
    end
    reloadRecipes()
  end
end

local function makeCraftQueueTask(queue)
  return function(redraw)
    for i, item in ipairs(queue) do
      state.craftQueueIdx = i
      prepareCraftState(item.name, item.count)
      state.craftStartAt = os.epoch("utc")
      local lastDrawAt = 0
      if redraw then
        redraw()
      end
      local ok, err = pcall(
        Crafting.craftItem,
        item.name,
        item.count,
        function(step, total, stepName, craftsDone)
          state.craftProgress = math.floor(step / total * 100)
          updateEta(step, total)
          updatePlanStepProgress(stepName, craftsDone)
          local now = os.epoch("utc")
          if redraw and (now - lastDrawAt >= 250 or step >= total) then
            lastDrawAt = now
            redraw()
          end
        end,
        function(plan)
          state.craftPlan = makePlanView(plan)
          state.craftPlanning = false
          if Config.COUNT_CRAFT_TIME then
            local okEst, est = pcall(Planner.estimateTime, plan)
            if okEst then
              state.craftEta = est
            end
          end
          if redraw then
            redraw()
          end
        end,
        function(stepName)
          removePlanStep(stepName)
          if redraw then
            redraw()
          end
        end,
        nil,
        function(stepName, isActive)
          setPlanStepActive(stepName, isActive)
          if redraw then
            redraw()
          end
        end
      )
      if not ok then
        state.craftMsg = tostring(err)
        state.craftMsgIsErr = true
        state.craftPlanning = false
        state.craftPlan = nil
        state.craftEta = nil
        reloadRecipes()
        return
      end
    end
    state.craftPlan = nil
    state.craftMsgIsDone = true
    state.craftMsg = "Done! " .. #queue .. " items crafted"
    state.craftProgress = 100
    state.craftEta = 0
    reloadRecipes()
  end
end

-- ── Craft screen ────────────────────────────────────────────

local function drawCraftScreen()
  for y = BODY_ROW, H do
    fill(y, colors.black)
  end

  -- Header: show queue progress when crafting from checklist queue
  fill(BODY_ROW, colors.gray)
  local headerLabel
  if state.craftQueue then
    headerLabel = string.format(
      "[%d/%d] %s",
      state.craftQueueIdx or 1,
      #state.craftQueue,
      state.craftItem and resolveDisplay(state.craftItem) or ""
    )
  else
    headerLabel = state.craftItem and resolveDisplay(state.craftItem) or ""
  end
  at(L, BODY_ROW, truncate(headerLabel, W - L), colors.white, colors.gray)

  local cur = BODY_ROW + 2

  -- Amount selector: only shown in single-item mode (not queue).
  -- Fluid recipes are ordered in mB, so they get x10 larger increments.
  if not state.craftQueue then
    local isFluid = state.craftIsFluid
    at(
      L,
      cur,
      isFluid and "Amount (mB):" or "Amount:",
      colors.lightGray,
      colors.black
    )
    local xb = L + (isFluid and 14 or 9)
    local cnt = state.craftCount

    local function addCount(delta)
      if delta > 1 and state.craftCount == 1 then
        state.craftCount = delta
      else
        state.craftCount = math.max(1, state.craftCount + delta)
      end
    end

    if isFluid then
      mkBtnTight(xb, cur, "-1000", colors.lightGray, colors.gray, function()
        addCount(-1000)
      end)
      mkBtnTight(xb + 6, cur, "-100", colors.lightGray, colors.gray, function()
        addCount(-100)
      end)
      mkBtnTight(xb + 11, cur, "-10", colors.lightGray, colors.gray, function()
        addCount(-10)
      end)
      mkBtnTight(xb + 15, cur, "-1", colors.lightGray, colors.gray, function()
        addCount(-1)
      end)
      at(xb + 18, cur, string.format("%6d", cnt), colors.black, colors.yellow)
      mkBtnTight(xb + 25, cur, "+1", colors.lightGray, colors.gray, function()
        addCount(1)
      end)
      mkBtnTight(xb + 28, cur, "+10", colors.lightGray, colors.gray, function()
        addCount(10)
      end)
      mkBtnTight(xb + 32, cur, "+100", colors.lightGray, colors.gray, function()
        addCount(100)
      end)
      mkBtnTight(
        xb + 37,
        cur,
        "+1000",
        colors.lightGray,
        colors.gray,
        function()
          addCount(1000)
        end
      )
    else
      mkBtnTight(xb, cur, "-100", colors.lightGray, colors.gray, function()
        addCount(-100)
      end)
      mkBtnTight(xb + 5, cur, "-10", colors.lightGray, colors.gray, function()
        addCount(-10)
      end)
      mkBtnTight(xb + 9, cur, "-1", colors.lightGray, colors.gray, function()
        addCount(-1)
      end)
      at(xb + 12, cur, string.format("%4d", cnt), colors.black, colors.yellow)
      mkBtnTight(xb + 17, cur, "+1", colors.lightGray, colors.gray, function()
        addCount(1)
      end)
      mkBtnTight(xb + 20, cur, "+10", colors.lightGray, colors.gray, function()
        addCount(10)
      end)
      mkBtnTight(xb + 24, cur, "+100", colors.lightGray, colors.gray, function()
        addCount(100)
      end)
    end

    cur = cur + 2
  end

  local notStarted = not state.craftPlanning and state.craftPlan == nil

  if notStarted then
    -- Craft button only in single-item mode (queue auto-starts and clears itself)
    if not state.craftQueue then
      -- Craft is blocked (rendered inert) while a Plan dry run works, so a
      -- stray tap can't start crafting mid-planning.
      if state.craftPreviewing then
        at(L, cur, " Craft ", colors.lightGray, colors.gray)
      else
        mkBtn(L, cur, "Craft", colors.black, colors.cyan, function()
          local name = state.craftItem
          local count = state.craftCount
          local key = state.craftKey
          local isFluid = state.craftIsFluid
          prepareCraftState(name, count)
          pendingTask = makeCraftTask(name, count, key, isFluid)
        end)
      end

      -- Dry run: plan + validate + time estimate, no crafting. The label
      -- switches to "Planning" while the run is in flight.
      mkBtn(
        L + #" Craft " + 1,
        cur,
        state.craftPreviewing and "Planning" or "Plan",
        colors.black,
        state.craftPreviewing and colors.green or colors.lightGray,
        function()
          if state.craftPreviewing then
            return
          end
          local name = state.craftItem
          local count = state.craftCount
          local key = state.craftKey
          state.craftPreviewing = true
          state.craftMsg = nil
          state.craftMsgIsErr = false
          state.craftMsgIsDone = false
          state.craftEta = nil
          pendingTask = function()
            local rootRecipe = key and Recipes.getRecipeByKey(key) or nil
            local ok, plan, missing, est =
              pcall(Crafting.previewCraft, name, count, rootRecipe)
            state.craftPreviewing = false
            if not ok then
              state.craftMsg = tostring(plan)
              state.craftMsgIsErr = true
              return
            end
            state.craftEta = est
            if #missing > 0 then
              state.craftMsg = Crafting.formatMissing(missing)
              state.craftMsgIsErr = true
              state.craftMsgIsDone = false
            else
              state.craftMsg = "Everything exists! Ready to craft!"
              state.craftMsgIsErr = false
              state.craftMsgIsDone = true
            end
          end
        end
      )
    end

    if state.craftMsgIsDone and state.craftMsg then
      at(
        L,
        cur + 2,
        truncate(state.craftMsg, W - L),
        colors.green,
        colors.black
      )
    elseif state.craftMsgIsErr and state.craftMsg then
      local lines = {}
      for line in (state.craftMsg .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
      end
      for i, line in ipairs(lines) do
        local row = cur + 1 + i
        if row > H - 3 then
          break
        end
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
        if row > planEnd then
          break
        end
        at(L, row, truncate(line, W - L), colors.red, colors.black)
      end
    elseif state.craftPlanning then
      at(L, planStart, "Planning...", colors.yellow, colors.black)
    elseif state.craftPlan then
      -- Actively crafting steps first (highlighted), waiting ones below --
      -- so what the system is doing RIGHT NOW sits at the top of the tree.
      local ordered = {}
      for _, step in ipairs(state.craftPlan) do
        if step.active then
          table.insert(ordered, step)
        end
      end
      for _, step in ipairs(state.craftPlan) do
        if not step.active then
          table.insert(ordered, step)
        end
      end

      for i, step in ipairs(ordered) do
        local row = planStart + i - 1
        if row > planEnd then
          break
        end
        local label = (step.active and "> " or "- ")
          .. displayOrResolve(step.displayName, step.name)
          .. " x"
          .. step.remaining
          .. (step.isFluid and "mB" or "")
        at(
          L,
          row,
          truncate(label, W - L),
          step.active and colors.lime or colors.lightGray,
          colors.black
        )
      end
    end
  end

  -- Progress header
  at(L, H - 2, "Progress", colors.gray, colors.black)

  -- Progress bar: pct%[====----]
  local barRow = H - 1
  local pct = string.format("%3d%%", state.craftProgress)
  local barX = L + #pct -- [ sits right after percent text
  local inner = W - barX - 2 -- bar width; ] lands at W-1 (1 char right margin)
  local filled = math.floor(state.craftProgress / 100 * inner)
  at(L, barRow, pct, colors.orange, colors.black)
  at(barX, barRow, "[", colors.gray, colors.black)
  at(barX + 1, barRow, string.rep("=", filled), colors.lime, colors.black)
  at(
    barX + 1 + filled,
    barRow,
    string.rep("-", inner - filled),
    colors.gray,
    colors.black
  )
  at(barX + 1 + inner, barRow, "]", colors.gray, colors.black)

  -- Remaining time under the bar -- only when Count Time is enabled (with
  -- it off the user asked for NO time display at all). A Plan dry run
  -- (craft not started yet) shows "Estimated time"; a running craft shows
  -- "Time left" -- the plan estimate at first, live actual-rate
  -- extrapolation after.
  if state.craftEta and Config.COUNT_CRAFT_TIME then
    local label = state.craftStartAt and "Time left: " or "Estimated time: "
    at(L, H, label .. fmtTime(state.craftEta), colors.lightGray, colors.black)
  end
end

-- ── Stock tab ───────────────────────────────────────────────

-- Walks the storage slots (via size + list, so empty slots are counted too)
-- and stores totals in state.stockScanResult.
local function startStockScan()
  state.stockScanning = true
  state.stockScanResult = nil
  pendingTask = function()
    local ok, total, used, free = pcall(Stock.getSlotUsage)
    state.stockScanning = false
    if not ok then
      state.stockScanResult = { error = tostring(total) }
      return
    end
    state.stockScanResult = { total = total, used = used, free = free }
  end
end

-- Analyzes stack fragmentation (items spread across more slots than needed)
-- and shows the result on a dedicated screen.
local function startStockAnalysis()
  state.stockAnalyzing = true
  state.stockAnalysis = nil
  pendingTask = function()
    local ok, wasted, rows = pcall(Stock.analyzeSlotFragmentation)
    state.stockAnalyzing = false
    if not ok then
      state.stockAnalysis = { error = tostring(wasted) }
      return
    end
    state.stockAnalysis = { wasted = wasted, rows = rows }
    state.stockAnalysisPage = 1
  end
end

-- Merges partial stacks, then re-analyzes and refreshes the usage numbers.
local function startStockFix()
  state.stockFixing = true
  pendingTask = function()
    local okFix, freed = pcall(Stock.fixSlotFragmentation)
    local okAn, wasted, rows = pcall(Stock.analyzeSlotFragmentation)
    state.stockFixing = false
    if not okFix then
      state.stockAnalysis = { error = tostring(freed) }
      return
    end
    if okAn then
      state.stockAnalysis = { wasted = wasted, rows = rows, freed = freed }
      state.stockAnalysisPage = 1
    else
      state.stockAnalysis = { error = tostring(wasted) }
    end
    -- Keep the usage panel behind this screen up to date.
    local okUsage, total, used, free = pcall(Stock.getSlotUsage)
    if okUsage then
      state.stockScanResult = { total = total, used = used, free = free }
    end
  end
end

-- Fragmentation analysis screen: lost-slot summary + paginated table of the
-- offending items (SLOTS column shows actual > ideal).
local function drawStockAnalysis(a)
  if a.error then
    at(L, BODY_ROW + 1, truncate(a.error, W - L), colors.red, colors.black)
    fill(H, colors.yellow)
    mkBtn(W - #" Back " + 1, H, "Back", colors.black, colors.orange, function()
      state.stockAnalysis = nil
    end)
    return
  end

  fill(BODY_ROW, colors.gray)
  local summary = string.format("Lost slots: %d", a.wasted)
  if a.freed then
    summary = summary .. string.format(" (freed %d)", a.freed)
  end
  at(L, BODY_ROW, truncate(summary, W - L), colors.white, colors.gray)

  drawTable({
    topY = BODY_ROW + 1,
    items = a.rows,
    page = state.stockAnalysisPage,
    setPage = function(p)
      state.stockAnalysisPage = p
    end,
    displayName = function(name, item)
      return displayOrResolve(item and item.displayName, name)
    end,
    rightW = 12,
    emptyMsg = "No lost slots - storage is packed tight",
    headerCount = "SLOTS",
    alwaysShowPage = true,
    countText = function(item)
      return string.format("%d > %d", item.slots, item.ideal)
    end,
    countColor = function()
      return colors.orange
    end,
    bottomBarRight = function()
      local xBack = W - #" Back " + 1
      mkBtn(xBack, H, "Back", colors.black, colors.orange, function()
        state.stockAnalysis = nil
      end)
      if a.wasted > 0 then
        mkBtn(
          xBack - #" Fix slots " - 1,
          H,
          "Fix slots",
          colors.black,
          colors.cyan,
          startStockFix
        )
      end
    end,
  })
end

-- Storage-usage panel: slot totals, fill percentage and a fill bar.
local function drawStockScanResult(res)
  local function backButton()
    fill(H, colors.yellow)
    mkBtn(W - #" Back " + 1, H, "Back", colors.black, colors.orange, function()
      state.stockScanResult = nil
    end)
  end

  if res.error then
    at(L, BODY_ROW + 1, truncate(res.error, W - L), colors.red, colors.black)
    backButton()
    return
  end

  fill(BODY_ROW, colors.gray)
  at(L, BODY_ROW, "Stock Usage", colors.white, colors.gray)

  local percent = res.total > 0 and (res.used / res.total * 100) or 0
  local pctColor = percent >= 90 and colors.red
    or percent >= 70 and colors.orange
    or colors.lime

  -- Right-align the numbers in one column after the longest label.
  local xValue = L + #"Slots total: " + 1
  local numW = #tostring(res.total)
  local function line(y, label, value, fg)
    at(L, y, label, colors.lightGray, colors.black)
    at(xValue, y, string.format("%" .. numW .. "s", value), fg, colors.black)
  end

  local cur = BODY_ROW + 2
  line(cur, "Slots total:", tostring(res.total), colors.white)
  line(cur + 1, "Slots used:", tostring(res.used), colors.yellow)
  line(cur + 2, "Slots free:", tostring(res.free), colors.lime)
  line(cur + 4, "Fill level:", string.format("%.1f%%", percent), pctColor)

  -- Fill bar right under the fill level, across the screen width.
  local barY = cur + 5
  local barW = W - L
  local filledW = math.floor(barW * percent / 100 + 0.5)
  if filledW > 0 then
    at(L, barY, string.rep(" ", filledW), colors.white, pctColor)
  end
  if filledW < barW then
    at(
      L + filledW,
      barY,
      string.rep(" ", barW - filledW),
      colors.white,
      colors.gray
    )
  end

  mkBtn(L, barY + 2, "Analyze", colors.black, colors.cyan, startStockAnalysis)

  backButton()
end

local function drawStockList()
  for y = BODY_ROW, H do
    fill(y, colors.black)
  end

  if state.stockScanning or state.stockAnalyzing or state.stockFixing then
    local msg = state.stockFixing and "Fixing slots..."
      or state.stockAnalyzing and "Analyzing slots..."
      or "Scanning storage slots..."
    at(L, BODY_ROW + 1, msg, colors.yellow, colors.black)
    return
  end

  if state.stockAnalysis then
    drawStockAnalysis(state.stockAnalysis)
    return
  end

  if state.stockScanResult then
    drawStockScanResult(state.stockScanResult)
    return
  end

  -- Fluids view: same table, fed from labeled tanks instead of item storage.
  if state.stockView == "fluids" then
    local modFiltered = drawModTabs(BODY_ROW, state.stockFluids, {
      getTab = function()
        return state.stockFluidModTab
      end,
      setTab = function(t)
        state.stockFluidModTab = t
      end,
      getOffset = function()
        return state.stockFluidModTabOffset
      end,
      setOffset = function(o)
        state.stockFluidModTabOffset = o
      end,
      resetPage = function()
        state.stockFluidPage = 1
      end,
    })

    local items = modFiltered
    if state.searchQuery ~= "" then
      local sq = state.searchQuery
      local filtered = {}
      for _, item in ipairs(modFiltered) do
        if
          matchesQuery(stripMod(item.name), sq)
          or matchesQuery(resolveDisplay(item.name), sq)
        then
          table.insert(filtered, item)
        end
      end
      items = filtered
    end

    drawTable({
      topY = BODY_ROW + 1,
      items = items,
      page = state.stockFluidPage,
      setPage = function(p)
        state.stockFluidPage = p
      end,
      displayName = resolveDisplay,
      rightW = 11,
      emptyMsg = "No fluids in Fluid Stock",
      headerCount = "AMOUNT",
      countText = function(item)
        return fmtMb(item.count)
      end,
      onRefresh = reloadStockFluids,
      beforeRefresh = {
        label = "Items",
        fn = function()
          state.stockView = "items"
          reloadStock()
        end,
      },
    })
    return
  end

  local modFiltered = drawModTabs(BODY_ROW, state.stockItems, {
    getTab = function()
      return state.stockModTab
    end,
    setTab = function(t)
      state.stockModTab = t
    end,
    getOffset = function()
      return state.stockModTabOffset
    end,
    setOffset = function(o)
      state.stockModTabOffset = o
    end,
    resetPage = function()
      state.stockPage = 1
    end,
  })

  local items = modFiltered
  if state.searchQuery ~= "" then
    local sq = state.searchQuery
    local filtered = {}
    for _, item in ipairs(modFiltered) do
      if
        matchesQuery(stripMod(item.name), sq)
        or matchesQuery(resolveDisplay(item.name), sq)
      then
        table.insert(filtered, item)
      end
    end
    items = filtered
  end

  drawTable({
    topY = BODY_ROW + 1,
    items = items,
    page = state.stockPage,
    setPage = function(p)
      state.stockPage = p
    end,
    displayName = resolveDisplay,
    rightW = 9,
    emptyMsg = "Stock is empty",
    onRefresh = reloadStock,
    onScan = startStockScan,
    beforeRefresh = {
      label = "Fluids",
      fn = function()
        state.stockView = "fluids"
        state.stockFluidPage = 1
        reloadStockFluids()
      end,
    },
  })
end

-- ── Labels tab ──────────────────────────────────────────────

-- Scans the Stock View for item display names (same job as the scan_names
-- script, but in-process: the DisplayNames cache updates immediately, no
-- reboot needed). Results land in state.labelsScanResult: rows with the
-- newly added names first, then every recipe item that still has no
-- display name at all.
local function startLabelsScan()
  state.labelsScanning = true
  state.labelsScanResult = nil
  state.labelInputMode = false
  state.labelEditTarget = nil
  pendingTask = function()
    -- Ids we want named: crafted outputs + ingredients of every recipe.
    local wanted = {}
    for _, recipe in pairs(Recipes.getAllRecipes()) do
      wanted[recipe.name] = true
      if recipe.items then
        for _, item in ipairs(recipe.items) do
          wanted[item.name] = true
        end
      end
    end

    -- Copy, not reference: getAll returns the live cache that the scan
    -- mutates, and we need the before-state to know what was added.
    local before = {}
    for id, dn in pairs(DisplayNames.getAll()) do
      before[id] = dn
    end

    local ok, err = pcall(Stock.scanDisplayNames)
    state.labelsScanning = false
    if not ok then
      state.labelsScanResult = { error = tostring(err) }
      return
    end

    local after = DisplayNames.getAll()

    local rows = {}
    local addedCount = 0
    for id, dn in pairs(after) do
      if before[id] == nil then
        addedCount = addedCount + 1
        table.insert(rows, { name = id, displayName = dn, missing = false })
      end
    end
    table.sort(rows, function(a, b)
      return stripMod(a.name) < stripMod(b.name)
    end)

    local missingRows = {}
    for id in pairs(wanted) do
      if after[id] == nil then
        table.insert(missingRows, { name = id, missing = true })
      end
    end
    table.sort(missingRows, function(a, b)
      return stripMod(a.name) < stripMod(b.name)
    end)
    for _, row in ipairs(missingRows) do
      table.insert(rows, row)
    end

    state.labelsScanResult = {
      rows = rows,
      addedCount = addedCount,
      missingCount = #missingRows,
    }
    state.labelsScanPage = 1
  end
end

-- Scan results view: summary header + paginated ITEM/NAME table (added names
-- first, unnamed recipe items in red), Back returns to the peripherals list.
local function drawLabelsScanResult(res)
  if res.error then
    at(L, BODY_ROW + 1, truncate(res.error, W - L), colors.red, colors.black)
    fill(H, colors.yellow)
    mkBtn(W - #" Back " + 1, H, "Back", colors.black, colors.orange, function()
      state.labelsScanResult = nil
    end)
    return
  end

  fill(BODY_ROW, colors.gray)
  at(
    L,
    BODY_ROW,
    truncate(
      string.format(
        "Added %d name(s), %d still unnamed",
        res.addedCount,
        res.missingCount
      ),
      W - L
    ),
    colors.white,
    colors.gray
  )

  drawTable({
    topY = BODY_ROW + 1,
    items = res.rows,
    page = state.labelsScanPage,
    setPage = function(p)
      state.labelsScanPage = p
    end,
    displayName = stripMod,
    rightW = 30,
    emptyMsg = "No new names; nothing unnamed",
    headerName = "ITEM",
    headerCount = "NAME",
    alwaysShowPage = true,
    countText = function(item)
      return item.missing and "?" or (item.displayName or "")
    end,
    countColor = function(item)
      return item.missing and colors.red or colors.lime
    end,
    rowFg = function(item)
      return item.missing and colors.red or colors.white
    end,
    bottomBarRight = function()
      mkBtn(
        W - #" Back " + 1,
        H,
        "Back",
        colors.black,
        colors.orange,
        function()
          state.labelsScanResult = nil
        end
      )
    end,
  })
end

local function drawLabels()
  for y = BODY_ROW, H do
    fill(y, colors.black)
  end

  if state.labelsScanning then
    at(
      L,
      BODY_ROW + 1,
      "Scanning stock for names...",
      colors.yellow,
      colors.black
    )
    return
  end

  if state.labelsScanResult then
    drawLabelsScanResult(state.labelsScanResult)
    return
  end

  -- rightW=31 layout from xCount:
  --   normal (no label):  [Edit](6) gap(1) -(1)                     = 8  (rest empty)
  --   normal (has label): [Edit](6) gap(1) [Del](5) gap(1) label    = 13 + label
  --   editing:            [v](3) gap(1) [x](3) gap(1) input         = 8  + input
  drawTable({
    topY = BODY_ROW,
    items = state.labelItems,
    page = state.labelsPage,
    setPage = function(p)
      state.labelsPage = p
    end,
    displayName = stripMod,
    rightW = 31,
    emptyMsg = "No peripherals found",
    headerName = "Peripheral",
    headerCount = "Label",
    alwaysShowPage = true,
    -- No Search here (the list isn't filtered by it); [Scan] harvests item
    -- display names from the Stock View, [Refresh] re-reads peripherals.
    bottomBarRight = function()
      local xRefresh = W - #" Refresh " + 1
      mkBtn(xRefresh, H, "Refresh", colors.black, colors.orange, reloadLabels)
      mkBtn(
        xRefresh - #" Scan " - 1,
        H,
        "Scan",
        colors.black,
        colors.orange,
        startLabelsScan
      )
    end,
    countText = function(_)
      return ""
    end,
    countColor = function(_)
      return colors.black
    end,
    -- Stale entries (port not connected) shown in red
    rowFg = function(item)
      return (item.connected == false) and colors.red or colors.white
    end,
    drawActions = function(item, row, rowBg, xCount)
      local editing = state.labelInputMode
        and state.labelEditTarget == item.name
      local captName = item.name
      local captLabel = item.label
      if editing then
        mkBtn(xCount, row, "v", colors.black, colors.green, function()
          if state.labelInput ~= "" then
            pcall(Labels.set, state.labelEditTarget, state.labelInput)
          else
            pcall(Labels.delete, state.labelEditTarget)
          end
          state.labelInputMode = false
          state.labelEditTarget = nil
          reloadLabels()
        end)
        mkBtn(xCount + 4, row, "x", colors.black, colors.red, function()
          state.labelInputMode = false
          state.labelEditTarget = nil
        end)
        local inputX = xCount + 8
        at(
          inputX,
          row,
          truncate(state.labelInput .. "_", W - inputX),
          colors.yellow,
          rowBg
        )
      else
        mkBtn(xCount, row, "Edit", colors.lightGray, colors.gray, function()
          state.labelEditTarget = captName
          state.labelInput = captLabel
          state.labelInputMode = true
        end)
        local xAfterEdit = xCount + 7
        if item.label ~= "" then
          mkBtn(xAfterEdit, row, "Del", colors.white, colors.red, function()
            pcall(Labels.delete, captName)
            reloadLabels()
          end)
          local labelX = xAfterEdit + #" Del " + 1
          at(
            labelX,
            row,
            truncate(item.label, W - labelX - 1),
            colors.yellow,
            rowBg
          )
        else
          at(xAfterEdit, row, "-", colors.lightGray, rowBg)
        end
      end
    end,
  })
end

-- ── Setup tab ───────────────────────────────────────────────

-- Roles whose picker offers only item inventories. Stock View is exempt:
-- it may be a custom non-inventory peripheral (stock()/getStockItemDetail).
local ROLE_NEEDS_INVENTORY = {
  stock_in = true,
  stock_out = true,
}

-- Roles whose picker offers only fluid-capable peripherals.
local ROLE_NEEDS_FLUID = {
  fluid_stock = true,
}

-- Applies a setting value: persists it via Config.set and re-applies side
-- effects that normally only happen at startup (monitor text scale).
local function applySetting(key, value)
  if key == "MONITOR_TEXT_SCALE" then
    value = math.max(0.5, math.min(5, value))
  end
  local ok = pcall(Config.set, key, value)
  if ok and key == "MONITOR_TEXT_SCALE" then
    pcall(mon.setTextScale, value)
    W, H = mon.getSize()
  end
end

-- Commits the keyboard input of the setting being edited. An input that is
-- not a number keeps the editor open (Escape cancels).
local function commitSettingInput()
  local key = state.settingEditKey
  if not key then
    return
  end
  local value = tonumber(state.settingInput)
  if not value then
    return
  end
  applySetting(key, value)
  state.settingEditKey = nil
end

-- Builds the System Roles blocks. Every block is { height, expanded,
-- draw = function(y) } so drawSetup can pack whole blocks onto pages.
local function buildRoleBlocks()
  -- Layout: role name (right-aligned) | [Set] | value
  -- Longest role name = "Recipe Iface" = 12 chars → xSet = L + 14
  local xSet = L + 14
  local xValue = xSet + #" Set " + 1 -- value starts after [Set] button + gap

  -- Ports offered by the picker: every labeled peripheral (incl. stale ones,
  -- so a temporarily disconnected port can still be assigned).
  -- invPickerPorts keeps only inventories (for ROLE_NEEDS_INVENTORY roles);
  -- stale ports can't be type-checked while absent, so they stay listed.
  local pickerPorts = {}
  local invPickerPorts = {}
  local fluidPickerPorts = {}
  for _, item in ipairs(state.labelItems) do
    if item.label ~= "" then
      table.insert(pickerPorts, item.name)
      if
        item.connected == false
        or peripheral.hasType(item.name, "inventory")
      then
        table.insert(invPickerPorts, item.name)
      end
      if item.connected == false or Fluids.hasFluidApi(item.name) then
        table.insert(fluidPickerPorts, item.name)
      end
    end
  end
  -- The pager renders labels, so sort by label (port as tiebreaker), same
  -- as the +RECIPE machine picker.
  local function byLabel(a, b)
    local la, lb = machineLabel(a), machineLabel(b)
    if la ~= lb then
      return la < lb
    end
    return a < b
  end
  table.sort(pickerPorts, byLabel)
  table.sort(invPickerPorts, byLabel)
  table.sort(fluidPickerPorts, byLabel)

  -- Draws one assigned value as "label (port)" at xValue on row y.
  local function drawValue(y, value)
    local port = Labels.findPort(value)
      or (peripheral.isPresent(value) and value)
    local maxW = W - xValue - 1
    if port and port ~= value then
      local portStr = "(" .. stripMod(port) .. ")"
      local lblTrunc = truncate(value, maxW - #portStr - 1)
      at(xValue, y, lblTrunc, colors.yellow, colors.black)
      local xPort = xValue + #lblTrunc + 1
      if xPort <= W - 1 then
        at(
          xPort,
          y,
          truncate(portStr, W - xPort),
          colors.lightGray,
          colors.black
        )
      end
    else
      at(xValue, y, truncate(value, maxW), colors.yellow, colors.black)
    end
  end

  local blocks = {}
  for _, role in ipairs(Roles.LIST) do
    local values = Roles.getList(role)
    local isMulti = Roles.MULTI[role] == true
    local pickerOpen = state.setupPickerRole == role
    local rolePorts = ROLE_NEEDS_INVENTORY[role] and invPickerPorts
      or ROLE_NEEDS_FLUID[role] and fluidPickerPorts
      or pickerPorts
    local captRole = role

    local height = 1 + math.max(0, #values - 1)
    if pickerOpen then
      height = height + (state.setupCustomMode and 1 or 2)
    end

    table.insert(blocks, {
      height = height,
      expanded = pickerOpen,
      draw = function(y)
        local cur = y
        if cur > H - 1 then
          return
        end
        fill(cur, colors.black)

        -- Role display name (right-aligned before [Set])
        local disp = Roles.DISPLAY[captRole]
        at(
          math.max(L, xSet - #disp - 1),
          cur,
          disp,
          colors.lightGray,
          colors.black
        )

        -- First assigned value sits on the role row; the rest stack below
        -- in the same column.
        if #values > 0 then
          drawValue(cur, values[1])
        else
          at(xValue, cur, "-", colors.lightGray, colors.black)
        end

        -- [Set] toggles the picker; green while open as a "tap to finish"
        -- hint.
        mkBtn(
          xSet,
          cur,
          "Set",
          colors.black,
          pickerOpen and colors.green or colors.yellow,
          function()
            if state.setupPickerRole == captRole then
              state.setupPickerRole = nil
            else
              state.setupPickerRole = captRole
              state.setupPickerOffset = 0
            end
            state.setupCustomMode = false
            state.setupCustomInput = ""
          end
        )

        cur = cur + 1

        for i = 2, #values do
          if cur > H - 1 then
            break
          end
          fill(cur, colors.black)
          drawValue(cur, values[i])
          cur = cur + 1
        end

        -- Inline picker
        if pickerOpen then
          if state.setupCustomMode then
            if cur <= H - 1 then
              fill(cur, colors.black)
              at(
                L + 2,
                cur,
                truncate(state.setupCustomInput .. "_", W - L - 4),
                colors.yellow,
                colors.black
              )
            end
          else
            -- Single paginated row of labeled peripherals (same pager as
            -- the +RECIPE machine picker). Tapping toggles for multi roles
            -- and selects-and-closes for single ones.
            if cur <= H - 1 then
              fill(cur, colors.black)

              local selectedSet = {}
              for _, port in ipairs(rolePorts) do
                local key = Labels.get(port) or port
                for _, v in ipairs(values) do
                  if v == key or v == port then
                    selectedSet[port] = true
                    break
                  end
                end
              end

              drawMachinePager(cur, rolePorts, selectedSet, function()
                return state.setupPickerOffset
              end, function(o)
                state.setupPickerOffset = o
              end, function(port)
                local label = Labels.get(port)
                -- A stored entry may reference this peripheral by label OR
                -- by raw port (legacy configs). Toggle whichever form is
                -- stored, otherwise a tap would add the same peripheral
                -- twice.
                local value = nil
                for _, v in ipairs(values) do
                  if v == port or (label and v == label) then
                    value = v
                    break
                  end
                end
                value = value or label or port
                if isMulti then
                  pcall(Roles.toggle, captRole, value)
                else
                  pcall(Roles.set, captRole, value)
                  state.setupPickerRole = nil
                end
              end, "No labeled peripherals")
              cur = cur + 1
            end

            -- Custom / Clear row
            if cur <= H - 1 then
              fill(cur, colors.black)
              local x = L + 2
              mkBtn(x, cur, "Custom", colors.black, colors.gray, function()
                state.setupCustomMode = true
                state.setupCustomInput = ""
              end)
              x = x + #" Custom " + 1
              if #values > 0 then
                mkBtn(x, cur, "Clear", colors.black, colors.red, function()
                  pcall(Roles.clear, captRole)
                  if not isMulti then
                    state.setupPickerRole = nil
                  end
                end)
              end
            end
          end
        end
      end,
    })
  end
  return blocks
end

-- Builds the Settings blocks: one row per editable Config value, styled
-- like the System Roles rows. Numbers are typed on the keyboard, booleans
-- open a true/false picker row below.
local function buildSettingBlocks()
  -- Longest label = "Machine Timeout" = 15 chars → xSet = L + 16
  local xSet = L + 16
  local xValue = xSet + #" Set " + 1

  local blocks = {}
  for _, setting in ipairs(Config.EDITABLE) do
    local captKey = setting.key
    local captType = setting.type
    local boolOpen = state.settingBoolKey == captKey
    local editing = state.settingEditKey == captKey

    table.insert(blocks, {
      height = boolOpen and 2 or 1,
      expanded = boolOpen or editing,
      draw = function(y)
        if y > H - 1 then
          return
        end
        fill(y, colors.black)
        at(
          math.max(L, xSet - #setting.label - 1),
          y,
          setting.label,
          colors.lightGray,
          colors.black
        )

        -- [Set]: booleans toggle the picker row; numbers open keyboard
        -- input (green Set or Enter commits, Escape cancels).
        mkBtn(
          xSet,
          y,
          "Set",
          colors.black,
          (boolOpen or editing) and colors.green or colors.yellow,
          function()
            if captType == "boolean" then
              state.settingBoolKey = (state.settingBoolKey == captKey) and nil
                or captKey
              state.settingEditKey = nil
            else
              if state.settingEditKey == captKey then
                commitSettingInput()
              else
                state.settingEditKey = captKey
                state.settingInput = tostring(Config[captKey])
              end
              state.settingBoolKey = nil
            end
          end
        )

        if editing then
          at(
            xValue,
            y,
            truncate(state.settingInput .. "_", W - xValue),
            colors.yellow,
            colors.black
          )
        else
          local value = Config[captKey]
          local fg = colors.yellow
          if captType == "boolean" then
            fg = value and colors.lime or colors.red
          end
          at(xValue, y, truncate(tostring(value), W - xValue), fg, colors.black)
        end

        -- true / false picker row
        if boolOpen and y + 1 <= H - 1 then
          local yOpt = y + 1
          fill(yOpt, colors.black)
          local x = L + 2
          for _, option in ipairs({ true, false }) do
            local captOption = option
            mkBtn(
              x,
              yOpt,
              tostring(option),
              colors.black,
              Config[captKey] == option and colors.cyan or colors.gray,
              function()
                applySetting(captKey, captOption)
                state.settingBoolKey = nil
              end
            )
            x = x + #tostring(option) + 3
          end
        end
      end,
    })
  end
  return blocks
end

local function drawSetup()
  for y = BODY_ROW, H do
    fill(y, colors.black)
  end

  fill(BODY_ROW, colors.gray)
  at(
    L,
    BODY_ROW,
    state.setupTab == "settings" and "Settings" or "System Roles",
    colors.white,
    colors.gray
  )

  local blocks = state.setupTab == "settings" and buildSettingBlocks()
    or buildRoleBlocks()

  -- Pack whole blocks onto pages of the available content height. A block
  -- taller than one page is clamped (its draw fn guards every row).
  local contentTop = BODY_ROW + 1
  local avail = (H - 1) - contentTop + 1
  local pages = {}
  local pageBlocks, used = {}, 0
  for _, block in ipairs(blocks) do
    local h = math.min(block.height, avail)
    if used + h > avail and #pageBlocks > 0 then
      table.insert(pages, pageBlocks)
      pageBlocks, used = {}, 0
    end
    table.insert(pageBlocks, block)
    used = used + h
  end
  if #pageBlocks > 0 then
    table.insert(pages, pageBlocks)
  end

  local totalPages = math.max(1, #pages)
  local page = math.min(state.setupPage, totalPages)
  -- An open picker/editor must stay visible: opening it can grow its block
  -- past the page break, so snap to whichever page it landed on.
  for pi, blocksOnPage in ipairs(pages) do
    for _, block in ipairs(blocksOnPage) do
      if block.expanded then
        page = pi
      end
    end
  end
  state.setupPage = page

  local y = contentTop
  for _, block in ipairs(pages[page] or {}) do
    block.draw(y)
    y = y + block.height
  end

  -- Bottom bar: pagination (left) + sub-tabs (right)
  fill(H, colors.yellow)
  local pageText = page .. " / " .. totalPages
  at(L, H, pageText, colors.black, colors.yellow)
  if totalPages > 1 then
    local btnX = L + #pageText + 1
    mkBtn(btnX, H, "^", colors.black, colors.orange, function()
      if page > 1 then
        state.setupPage = page - 1
      end
    end)
    mkBtn(btnX + 5, H, "v", colors.black, colors.orange, function()
      if page < totalPages then
        state.setupPage = page + 1
      end
    end)
  end

  -- Sub-tab switcher, styled like the STOCK Fluids/Items toggle: only the
  -- OTHER sub-tab is shown (on System Roles you see "Settings" and vice
  -- versa) and tapping it switches over.
  local otherLabel = state.setupTab == "settings" and "System Roles"
    or "Settings"
  mkBtn(
    W - (#otherLabel + 2) + 1,
    H,
    otherLabel,
    colors.black,
    colors.cyan,
    function()
      state.setupTab = state.setupTab == "settings" and "roles" or "settings"
      state.setupPage = 1
      state.setupPickerRole = nil
      state.setupCustomMode = false
      state.setupCustomInput = ""
      state.settingEditKey = nil
      state.settingBoolKey = nil
    end
  )
end

-- ── Checklist tab ──────────────────────────────────────────

local CHECKLIST_STATUS_COLOR = {
  done = colors.lime,
  in_stock = colors.white,
  to_craft = colors.yellow,
  missing = colors.red,
}

local CHECKLIST_STATUS_ORDER =
  { missing = 1, to_craft = 2, in_stock = 3, done = 4 }

local function drawChecklist()
  for y = BODY_ROW, H do
    fill(y, colors.black)
  end

  -- Sub-tabs row
  local subTabs = {
    { id = "all", label = "All" },
    { id = "in_stock", label = "In Stock" },
    { id = "to_craft", label = "To Craft" },
    { id = "done", label = "Done" },
  }
  local stx = L
  for _, tab in ipairs(subTabs) do
    local active = state.checklistSubTab == tab.id
    at(
      stx,
      BODY_ROW,
      tab.label,
      active and colors.black or colors.gray,
      active and colors.yellow or colors.black
    )
    local captId = tab.id
    table.insert(buttons, {
      x1 = stx,
      x2 = stx + #tab.label - 1,
      y = BODY_ROW,
      fn = function()
        state.checklistSubTab = captId
        state.checklistPage = 1
      end,
    })
    stx = stx + #tab.label + 1
  end

  local subTab = state.checklistSubTab
  local outName = Roles.getPort("materials_out")
  local hasOut = outName ~= nil

  -- Read materials_out every draw so status is always current without explicit Refresh.
  -- Items whose needed amount is already in materials_out are treated as "done".
  local outTotals = {}
  if outName then
    local outP = peripheral.wrap(outName)
    if outP then
      for _, item in pairs(outP.list()) do
        outTotals[item.name] = (outTotals[item.name] or 0) + item.count
      end
    end
  end

  local function effectiveStatus(item)
    if item.status ~= "done" and (outTotals[item.name] or 0) >= item.needed then
      return "done"
    end
    return item.status
  end

  local hasInStock, hasToCraft = false, false
  if state.checklistItems then
    for _, item in ipairs(state.checklistItems) do
      local s = effectiveStatus(item)
      if s == "in_stock" then
        hasInStock = true
      end
      if s == "to_craft" then
        hasToCraft = true
      end
    end
  end

  local showMoveOut = hasOut
    and hasInStock
    and (subTab == "all" or subTab == "in_stock")
  local showCraftAll = hasToCraft and (subTab == "all" or subTab == "to_craft")

  -- Shared bottom bar builder (also used in early-out paths)
  local function drawBottomBar(x)
    mkBtn(x, H, "Refresh", colors.black, colors.orange, function()
      state.checklistMsg = nil
      reloadChecklist()
    end)
    x = x + #" Refresh " + 1

    if showMoveOut then
      if state.checklistMoving then
        local movingText = state.checklistMsg or "Moving..."
        local fg = (state.checklistMsg and state.checklistMsgIsErr)
            and colors.red
          or colors.black
        at(x, H, movingText, fg, colors.yellow)
        x = x + #movingText + 1
      else
        mkBtn(x, H, "Move out", colors.black, colors.green, function()
          state.checklistMoving = true
          state.checklistMsg = nil
          pendingTask = function(redraw)
            local ok, transferred, notFound =
              pcall(Stock.transferChecklistItems)
            reloadChecklist()
            local n = ok and transferred and #transferred or 0
            local m = ok and notFound and #notFound or 0
            state.checklistMsg = ok
                and (n .. " moved" .. (m > 0 and (", " .. m .. " not found") or ""))
              or tostring(transferred)
            state.checklistMsgIsErr = not ok or m > 0
            if redraw then
              redraw()
            end
            os.sleep(2)
            state.checklistMoving = false
            state.checklistMsg = nil
            state.checklistMsgIsErr = false
          end
        end)
        x = x + #" Move out " + 1
      end
    end

    if showCraftAll then
      mkBtn(x, H, "Craft all", colors.black, colors.cyan, function()
        if not state.checklistItems then
          return
        end
        local queue = {}
        for _, item in ipairs(state.checklistItems) do
          if item.status == "to_craft" then
            table.insert(queue, { name = item.name, count = item.needed })
          end
        end
        if #queue == 0 then
          return
        end
        state.craftQueue = queue
        state.craftQueueIdx = 1
        state.craftKey = nil
        state.craftIsFluid = false
        state.tab = "craft"
        prepareCraftState(queue[1].name, queue[1].count)
        pendingTask = makeCraftQueueTask(queue)
      end)
      x = x + #" Craft All " + 1
    end

    if state.checklistMsg then
      local fg = state.checklistMsgIsErr and colors.red or colors.lime
      if x <= W then
        at(x, H, truncate(state.checklistMsg, W - x + 1), fg, colors.yellow)
      end
    end
  end

  if state.checklistNoClipboard then
    at(
      L,
      BODY_ROW + 1,
      "No clipboard (create:clipboard)",
      colors.red,
      colors.black
    )
    fill(H, colors.yellow)
    drawBottomBar(L)
    return
  end

  if state.checklistItems == nil then
    at(L, BODY_ROW + 1, "Press Refresh to load", colors.gray, colors.black)
    fill(H, colors.yellow)
    drawBottomBar(L)
    return
  end

  -- Filter + sort (using effective status so materials_out items show as done)
  local filtered = {}
  for _, item in ipairs(state.checklistItems) do
    local es = effectiveStatus(item)
    if subTab == "all" or es == subTab then
      table.insert(
        filtered,
        { name = item.name, needed = item.needed, status = es }
      )
    end
  end
  table.sort(filtered, function(a, b)
    local oa = CHECKLIST_STATUS_ORDER[a.status] or 5
    local ob = CHECKLIST_STATUS_ORDER[b.status] or 5
    if oa ~= ob then
      return oa < ob
    end
    return a.name < b.name
  end)

  -- rightW = 1 gap + 6 (NEEDED) + 1 gap + 7 (Craft btn) = 15
  local rightW = 1 + #"NEEDED" + 1 + #" Craft "

  drawTable({
    topY = BODY_ROW + 1,
    items = filtered,
    allItems = state.checklistItems,
    page = state.checklistPage,
    setPage = function(p)
      state.checklistPage = p
    end,
    displayName = resolveDisplay,
    rightW = rightW,
    headerCount = "NEEDED",
    emptyMsg = subTab == "done" and "Nothing done yet"
      or subTab == "in_stock" and "Nothing in stock"
      or subTab == "to_craft" and "Nothing to craft"
      or "Checklist is empty",
    rowFg = function(item)
      return CHECKLIST_STATUS_COLOR[item.status] or colors.white
    end,
    countText = function(item)
      return item.status ~= "done" and ("x" .. item.needed) or ""
    end,
    countColor = function(item)
      return CHECKLIST_STATUS_COLOR[item.status] or colors.white
    end,
    drawActions = function(item, row, rowBg, xCount)
      if item.status == "to_craft" then
        local xCraft = xCount + #"NEEDED" + 2
        local captItem = item
        mkBtn(xCraft, row, "Craft", colors.black, colors.yellow, function()
          state.craftQueue = nil
          state.craftQueueIdx = 0
          state.craftKey = nil
          state.craftIsFluid = false
          state.tab = "craft"
          prepareCraftState(captItem.name, captItem.needed)
          pendingTask = makeCraftTask(captItem.name, captItem.needed)
        end)
      end
    end,
    bottomBarRight = drawBottomBar,
  })
end

-- ── Full redraw ─────────────────────────────────────────────

local function drawScreen()
  buttons = {}
  mon.setBackgroundColor(colors.black)
  -- No mon.clear() here: every tab drawer fills all its rows itself, and
  -- clearing first blanks the whole screen for the duration of the redraw
  -- (visible as flicker on slower draws).
  drawTabs()
  if state.tab == "recipes" then
    drawRecipesList()
  elseif state.tab == "craft" then
    drawCraftScreen()
  elseif state.tab == "stock" then
    drawStockList()
  elseif state.tab == "checklist" then
    drawChecklist()
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
  for key, recipe in pairs(all) do
    table.insert(list, {
      key = key,
      name = recipe.name,
      displayName = recipe.displayName,
      count = recipe.count,
      resultType = recipe.resultType,
    })
  end
  table.sort(list, function(a, b)
    return stripMod(a.name) < stripMod(b.name)
  end)
  state.recipes = list
end

reloadStock = function()
  -- Top up display names for items that appeared since the last look, so
  -- the STOCK table shows friendly names without a manual LABELS > Scan.
  pcall(Stock.fillMissingDisplayNames)
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

reloadStockFluids = function()
  local ok, totals = pcall(Fluids.getTotals)
  local list = {}
  if ok then
    for name, mb in pairs(totals) do
      table.insert(list, { name = name, count = mb })
    end
  end
  table.sort(list, function(a, b)
    return stripMod(a.name) < stripMod(b.name)
  end)
  state.stockFluids = list
end

-- Fluid ids present in Fluid Stock tanks, alphabetical (+Fluids picker).
reloadFluids = function()
  local ok, totals = pcall(Fluids.getTotals)
  local list = {}
  if ok then
    for name in pairs(totals) do
      table.insert(list, name)
    end
  end
  table.sort(list, function(a, b)
    return stripMod(a) < stripMod(b)
  end)
  state.availableFluids = list
end

reloadMachines = function()
  local known = {}
  for _, role in ipairs(Roles.LIST) do
    for _, p in ipairs(Roles.getPorts(role)) do
      known[p] = true
    end
  end
  -- Only offer machines the user has actually named on the Labels tab; an
  -- unlabelled inventory is just noise in the picker (can't be identified).
  -- Fluid-only peripherals (tanks() but no item slots) count too, so purely
  -- fluid machines can be picked as processors or "Result from". Fluid
  -- Stock tanks don't show up: like every role port they land in `known`.
  local labels = Labels.getAll()
  local machines = {}
  for _, name in ipairs(peripheral.getNames()) do
    if
      not known[name]
      and labels[name]
      and name:find(":", 1, true)
      and (peripheral.hasType(name, "inventory") or Fluids.hasFluidApi(name))
    then
      table.insert(machines, name)
    end
  end
  table.sort(machines, function(a, b)
    local la, lb = machineLabel(a), machineLabel(b)
    if la ~= lb then
      return la < lb
    end
    return a < b
  end)
  state.availableMachines = machines
end

reloadMachineItems = function()
  -- Preserve existing processor assignments across rescans (per variant:
  -- same-id items with different nbt may go to different machines)
  local function variantKey(item)
    return item.name .. "\0" .. (item.nbt or "")
  end
  local existing = {}
  for _, item in ipairs(state.machineItems) do
    if item.processor then
      existing[variantKey(item)] = item.processor
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
      displayName = item.displayName,
      nbt = item.nbt,
      count = item.count,
      slot = item.slot,
      processor = existing[variantKey(item)] or existing[item.name .. "\0"],
    })
  end
end

reloadChecklist = function()
  local ok, items = pcall(Stock.getChecklistStatus)
  if not ok or items == nil then
    state.checklistNoClipboard = true
    state.checklistItems = {}
  else
    state.checklistNoClipboard = false
    state.checklistItems = items
  end
end

reloadLabels = function()
  local data = Labels.getAll()
  local connectedSet = {}
  for _, name in ipairs(peripheral.getNames()) do
    connectedSet[name] = true
  end

  -- Connected peripherals (with or without label)
  local connected = {}
  for name in pairs(connectedSet) do
    table.insert(
      connected,
      { name = name, label = data[name] or "", connected = true }
    )
  end
  table.sort(connected, function(a, b)
    return stripMod(a.name) < stripMod(b.name)
  end)

  -- Stale labels whose port is no longer connected
  local stale = {}
  for port, label in pairs(data) do
    if not connectedSet[port] then
      table.insert(stale, { name = port, label = label, connected = false })
    end
  end
  table.sort(stale, function(a, b)
    return a.label < b.label
  end)

  local items = {}
  for _, item in ipairs(connected) do
    table.insert(items, item)
  end
  for _, item in ipairs(stale) do
    table.insert(items, item)
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

  -- Seed the display-name store from any displayNames already saved in recipes.
  local dnSeed = {}
  for _, recipe in pairs(Recipes.getAllRecipes()) do
    if recipe.displayName then
      dnSeed[recipe.name] = recipe.displayName
    end
  end
  DisplayNames.setMany(dnSeed)

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
            if Roles.MULTI[state.setupPickerRole] then
              -- Multi role: append and keep the picker open for more.
              pcall(Roles.toggle, state.setupPickerRole, state.setupCustomInput)
            else
              pcall(Roles.set, state.setupPickerRole, state.setupCustomInput)
              state.setupPickerRole = nil
            end
          end
          state.setupCustomMode = false
          drawScreen()
        elseif key == keys.escape then
          state.setupCustomMode = false
          drawScreen()
        end
      end
    elseif state.settingEditKey then
      if evType == "char" then
        state.settingInput = state.settingInput .. ev[2]
        drawScreen()
      elseif evType == "key" then
        local key = ev[2]
        if key == keys.backspace then
          if #state.settingInput > 0 then
            state.settingInput = state.settingInput:sub(1, -2)
          end
          drawScreen()
        elseif key == keys.enter then
          commitSettingInput()
          drawScreen()
        elseif key == keys.escape then
          state.settingEditKey = nil
          drawScreen()
        end
      end
    end
  end
end

return UI

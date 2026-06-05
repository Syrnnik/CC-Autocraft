-- migrate_recipes.lua
-- Interactive tool to replace port names with labels in all saved recipes.
-- Run on the monitor computer. Shows all unique processor values found in
-- recipes, lets you assign a label to each, then replaces them on Replace All.

local Labels  = require("lib.labels")
local Recipes = require("lib.recipes")
local Roles   = require("lib.roles")

-- ── Drawing helpers ──────────────────────────────────────────

local mon, W, H
local buttons = {}

local function at(x, y, text, fg, bg)
  mon.setCursorPos(x, y)
  mon.setBackgroundColor(bg)
  mon.setTextColor(fg)
  mon.write(text)
end

local function fill(y, bg)
  mon.setCursorPos(1, y)
  mon.setBackgroundColor(bg)
  mon.clearLine()
end

local function mkBtn(x, y, label, fg, bg, fn)
  local text = " " .. label .. " "
  at(x, y, text, fg, bg)
  table.insert(buttons, { x1 = x, x2 = x + #text - 1, y = y, fn = fn })
end

local function truncate(s, maxLen)
  if #s <= maxLen then return s end
  return s:sub(1, maxLen - 3) .. "..."
end

-- ── State ────────────────────────────────────────────────────

local L    = 2
local xSet = 22       -- [Set] button column

local state = {
  -- { value = "...", newLabel = nil }  one entry per unique processor value
  ports       = {},
  pickerIdx   = nil,  -- index in ports whose picker is open
  customMode  = false,
  customInput = "",
  labelItems  = {},   -- { name = port, label = string } sorted by label
  msg         = nil,
}

-- Collect unique processor values from all recipes, tracking the first recipe
-- name that references each value so the user can identify what it belongs to.
local function collectPorts()
  local recipes = Recipes.getAllRecipes()
  local seen, ports = {}, {}
  for _, recipe in pairs(recipes) do
    local function add(v)
      if v and not seen[v] then
        seen[v] = true
        table.insert(ports, { value = v, newLabel = nil, firstRecipe = recipe.name })
      end
    end
    add(recipe.processor)
    add(recipe.resultProcessor)
    if recipe.items then
      for _, item in ipairs(recipe.items) do add(item.processor) end
    end
  end
  table.sort(ports, function(a, b) return a.value < b.value end)
  return ports
end

-- ── Draw ─────────────────────────────────────────────────────

local function drawScreen()
  buttons = {}
  mon.setBackgroundColor(colors.black)
  mon.clear()

  -- Header
  fill(1, colors.gray)
  at(L, 1, "Migrate Recipe Processors", colors.white, colors.gray)

  local xLabel   = xSet + #" Set " + 1  -- label column starts here
  local labelW   = 10                    -- chars reserved for label
  local xRecipe  = xLabel + labelW + 1   -- recipe hint column
  local cur      = 2

  if #state.ports == 0 then
    at(L, cur, "No processor ports found in recipes.", colors.gray, colors.black)
  else
    for i, entry in ipairs(state.ports) do
      if cur > H - 1 then break end
      fill(cur, colors.black)

      -- Value (right-aligned before [Set], truncated)
      local disp = truncate(entry.value, xSet - L - 1)
      at(math.max(L, xSet - #disp - 1), cur, disp, colors.lightGray, colors.black)

      -- [Set] button
      local captI = i
      mkBtn(xSet, cur, "Set", colors.black, colors.yellow, function()
        state.pickerIdx   = state.pickerIdx == captI and nil or captI
        state.customMode  = false
        state.customInput = ""
      end)

      -- Selected label (or "-")
      local labelVal   = entry.newLabel or "-"
      local labelColor = entry.newLabel and colors.cyan or colors.gray
      at(xLabel, cur, truncate(labelVal, labelW), labelColor, colors.black)

      -- First recipe that uses this processor (hint in gray)
      if entry.firstRecipe and xRecipe <= W then
        at(xRecipe, cur,
           truncate(stripMod(entry.firstRecipe), W - xRecipe + 1),
           colors.gray, colors.black)
      end

      cur = cur + 1

      -- Inline label picker
      if state.pickerIdx == i and cur <= H - 1 then
        fill(cur, colors.black)
        if state.customMode then
          at(L + 2, cur,
             truncate(state.customInput .. "_", W - L - 3),
             colors.yellow, colors.black)
        else
          local x = L + 2
          local RIGHT = W - 2
          for _, litem in ipairs(state.labelItems) do
            if litem.label ~= "" then
              local bw = #litem.label + 2
              if x + bw - 1 > RIGHT then break end
              local captLabel = litem.label
              mkBtn(x, cur, litem.label, colors.black, colors.cyan, function()
                state.ports[captI].newLabel = captLabel
                state.pickerIdx = nil
              end)
              x = x + bw + 1
            end
          end
          -- Custom button
          if x + #" Custom " - 1 <= RIGHT then
            mkBtn(x, cur, "Custom", colors.black, colors.gray, function()
              state.customMode  = true
              state.customInput = ""
            end)
            x = x + #" Custom " + 1
          end
          -- Clear button (only when a label is selected)
          if entry.newLabel and x + #" Clear " - 1 <= RIGHT then
            mkBtn(x, cur, "Clear", colors.black, colors.red, function()
              state.ports[captI].newLabel = nil
              state.pickerIdx = nil
            end)
          end
        end
        cur = cur + 1
      end
    end
  end

  -- Bottom bar
  fill(H, colors.yellow)
  mkBtn(L, H, "Replace All", colors.black, colors.orange, function()
    local portToLabel = {}
    for _, entry in ipairs(state.ports) do
      if entry.newLabel then portToLabel[entry.value] = entry.newLabel end
    end
    if not next(portToLabel) then
      state.msg = "Nothing selected"
      return
    end
    local recipes = Recipes.getAllRecipes()
    local count = 0
    for _, recipe in pairs(recipes) do
      local function rep(v)
        if v and portToLabel[v] then count = count + 1; return portToLabel[v] end
        return v
      end
      recipe.processor       = rep(recipe.processor)
      recipe.resultProcessor = rep(recipe.resultProcessor)
      if recipe.items then
        for _, item in ipairs(recipe.items) do
          item.processor = rep(item.processor)
        end
      end
    end
    Recipes.saveAllRecipes(recipes)
    state.msg     = "Done: " .. count .. " replaced"
    state.ports   = collectPorts()
    state.pickerIdx = nil
  end)

  if state.msg then
    local msgX = L + #" Replace All " + 1
    if msgX <= W then
      at(msgX, H, truncate(state.msg, W - msgX + 1), colors.black, colors.yellow)
    end
  end
end

-- ── Init ─────────────────────────────────────────────────────

local monName = Roles.getPort("monitor")
if not monName or not peripheral.isPresent(monName) then
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "monitor") then monName = name; break end
  end
end
if not monName then error("No monitor found") end

mon = peripheral.wrap(monName)
mon.setTextScale(1.0)
W, H = mon.getSize()

-- Build label items list (only labeled peripherals)
local labelsData = Labels.getAll()
local perifs = peripheral.getNames()
table.sort(perifs, function(a, b)
  return (labelsData[a] or a) < (labelsData[b] or b)
end)
for _, name in ipairs(perifs) do
  table.insert(state.labelItems, { name = name, label = labelsData[name] or "" })
end

state.ports = collectPorts()
drawScreen()

-- ── Event loop ───────────────────────────────────────────────

while true do
  local ev = { os.pullEvent() }
  local evType = ev[1]

  if evType == "monitor_touch" and ev[2] == monName then
    local x, y = ev[3], ev[4]
    for _, btn in ipairs(buttons) do
      if y == btn.y and x >= btn.x1 and x <= btn.x2 then
        btn.fn()
        drawScreen()
        break
      end
    end
  elseif state.customMode and state.pickerIdx then
    if evType == "char" then
      state.customInput = state.customInput .. ev[2]
      drawScreen()
    elseif evType == "key" then
      local key = ev[2]
      if key == keys.backspace and #state.customInput > 0 then
        state.customInput = state.customInput:sub(1, -2)
        drawScreen()
      elseif key == keys.enter and state.customInput ~= "" then
        state.ports[state.pickerIdx].newLabel = state.customInput
        state.pickerIdx   = nil
        state.customMode  = false
        state.customInput = ""
        drawScreen()
      elseif key == keys.escape then
        state.customMode = false
        drawScreen()
      end
    end
  end
end

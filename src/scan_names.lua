-- scan_names.lua
-- Uses the Stock View peripheral to look up the displayName of every item in
-- storage and saves them to data/display_names.json, so the UI can show
-- friendly names instead of raw ids. Any recipe item that is not present in
-- stock (so no displayName could be read) is reported.
--
-- Output goes to the configured Monitor peripheral if one is set, otherwise to
-- the computer terminal.

local Network = require("lib.network")
local Recipes = require("lib.recipes")
local Roles = require("lib.roles")
local Stock = require("lib.stock")

Network.prepareModem("bottom", false)

-- Redirect output to the physical monitor when available.
local prevTerm = nil
local monName = Roles.getPort("monitor")
if monName and peripheral.isPresent(monName) then
  local mon = peripheral.wrap(monName)
  mon.setTextScale(1.0)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  mon.clear()
  mon.setCursorPos(1, 1)
  prevTerm = term.redirect(mon)
end

local function restore()
  if prevTerm then
    term.redirect(prevTerm)
  end
end

print("Scanning Stock View for display names...")

-- Item ids we expect to have (crafted outputs + ingredients from all recipes).
local wanted = {}
for _, recipe in pairs(Recipes.getAllRecipes()) do
  wanted[recipe.name] = true
  if recipe.items then
    for _, item in ipairs(recipe.items) do
      wanted[item.name] = true
    end
  end
end

local ok, found, count, notFound = pcall(Stock.scanDisplayNames, wanted)
if not ok then
  print("Error: " .. tostring(found))
  restore()
  return
end

print(string.format("Saved %d display name(s).", count))

if #notFound > 0 then
  print(string.format("%d recipe item(s) not in stock:", #notFound))
  for _, id in ipairs(notFound) do
    print("  " .. id)
  end
else
  print("All recipe items found in stock.")
end

restore()

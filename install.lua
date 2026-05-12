-- CC:Autocraft Installer
-- Usage:
--   wget run https://raw.githubusercontent.com/Syrnnik/Computer-Craft-Autocraft/dev/install.lua computer
--   wget run https://raw.githubusercontent.com/Syrnnik/Computer-Craft-Autocraft/dev/install.lua crafter

local args   = { ... }
local TARGET = args[1]
local BRANCH = "dev"
local BASE   = "https://raw.githubusercontent.com/Syrnnik/Computer-Craft-Autocraft/"
  .. BRANCH .. "/src/"
local DEST   = "autocraft"

local COMPUTER_FILES = {
  "lib/config.lua",
  "lib/crafting.lua",
  "lib/logger.lua",
  "lib/network.lua",
  "lib/planner.lua",
  "lib/recipes.lua",
  "lib/screen.lua",
  "lib/stock.lua",
  "lib/ui.lua",
  "lib/utils.lua",
  "all_recipes.lua",
  "craft.lua",
  "delete_recipe.lua",
  "device_id.lua",
  "get_recipe.lua",
  "main.lua",
  "monitor.lua",
  "new_craft.lua",
}

local CRAFTER_FILES = {
  "lib/config.lua",
  "lib/logger.lua",
  "lib/network.lua",
  "lib/screen.lua",
  "lib/utils.lua",
  "crafter.lua",
  "device_id.lua",
}

local FILES_BY_TARGET = {
  computer = COMPUTER_FILES,
  crafter  = CRAFTER_FILES,
}

if not TARGET or not FILES_BY_TARGET[TARGET] then
  print("Usage: install.lua <computer|crafter>")
  return
end

local function download(path)
  local res = http.get(BASE .. path)
  if not res then
    return false, "request failed"
  end
  local content = res.readAll()
  res.close()

  local dest = DEST .. "/" .. path
  local dir  = fs.getDir(dest)
  if not fs.exists(dir) then
    fs.makeDir(dir)
  end

  local f = fs.open(dest, "w")
  if not f then
    return false, "cannot write file"
  end
  f.write(content)
  f.close()
  return true
end

print("CC:Autocraft installer (" .. TARGET .. ")")
print(string.rep("-", 40))

local failed = {}
for _, file in ipairs(FILES_BY_TARGET[TARGET]) do
  io.write("  " .. file .. "... ")
  local ok, err = download(file)
  if ok then
    print("ok")
  else
    print("FAILED (" .. (err or "?") .. ")")
    table.insert(failed, file)
  end
end

if TARGET == "computer" and not fs.exists(DEST .. "/data") then
  fs.makeDir(DEST .. "/data")
  print("  data/ ... ok")
end

print(string.rep("-", 40))
if #failed == 0 then
  print("Done! Edit lib/config.lua to configure.")
else
  print("Finished with errors:")
  for _, f in ipairs(failed) do
    print("  - " .. f)
  end
end

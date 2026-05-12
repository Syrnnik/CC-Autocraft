-- CC:Autocraft Installer
-- Usage:
--   wget run https://raw.githubusercontent.com/Syrnnik/Computer-Craft-Autocraft/main/install.lua
--   wget run https://raw.githubusercontent.com/Syrnnik/Computer-Craft-Autocraft/main/install.lua dev

local args   = { ... }
local BRANCH = args[1] or "main"
local BASE   = "https://raw.githubusercontent.com/Syrnnik/Computer-Craft-Autocraft/"
  .. BRANCH .. "/src/"

local FILES = {
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
  "crafter.lua",
  "delete_recipe.lua",
  "device_id.lua",
  "get_recipe.lua",
  "main.lua",
  "monitor.lua",
  "new_craft.lua",
}

local function download(path)
  local url = BASE .. path
  local res = http.get(url)
  if not res then
    return false, "request failed"
  end
  local content = res.readAll()
  res.close()

  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end

  local f = fs.open(path, "w")
  if not f then
    return false, "cannot write file"
  end
  f.write(content)
  f.close()
  return true
end

print("CC:Autocraft installer (branch: " .. BRANCH .. ")")
print(string.rep("-", 40))

local failed = {}
for _, file in ipairs(FILES) do
  io.write("  " .. file .. "... ")
  local ok, err = download(file)
  if ok then
    print("ok")
  else
    print("FAILED (" .. (err or "?") .. ")")
    table.insert(failed, file)
  end
end

if not fs.exists("data") then
  fs.makeDir("data")
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
